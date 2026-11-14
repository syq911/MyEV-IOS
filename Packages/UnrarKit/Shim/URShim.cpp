//
//  URShim.cpp
//  UnrarKit（vendored）
//
//  C 接口的实现，直接调 unrar 的 DLL API（dll.hpp）。
//
//  两次遍历的设计：枚举与解压用各自独立的 archive 句柄。
//  unrar 的句柄是有状态的游标，抽第 N 页必须从头跳过去；
//  复用同一个句柄会让「按需抽取任意页」变成「只能顺序抽」，
//  而导入时我们按自然序排好页、可以顺序抽 —— 但单独抽某页的能力
//  留着更安全（比如以后做「预览某一页」）。
//

#include "URShim.h"

#include <string>
#include <vector>
#include <cstring>

#include "dll.hpp"

namespace {

struct Entry {
    std::string name;
    int64_t size;
    bool isDirectory;
};

struct ArchiveHandle {
    std::string path;
    std::vector<Entry> entries;
    int32_t lastError;
};

ArchiveHandle *handleOf(URShimArchive *archive) {
    return reinterpret_cast<ArchiveHandle *>(archive);
}

const ArchiveHandle *handleOf(const URShimArchive *archive) {
    return reinterpret_cast<const ArchiveHandle *>(archive);
}

HANDLE openArchive(const std::string &path, unsigned int openMode, unsigned int *openResult) {
    RAROpenArchiveDataEx data;
    memset(&data, 0, sizeof(data));
    data.ArcName = const_cast<char *>(path.c_str());
    data.OpenMode = openMode;

    HANDLE handle = RAROpenArchiveEx(&data);
    if (openResult != nullptr) {
        *openResult = data.OpenResult;
    }
    return handle;
}

std::string entryName(const RARHeaderDataEx &header) {
    // FileName 在 RAR5 下是 UTF-8，RAR4 下可能是 OEM 编码。
    // 我们只用它来判断扩展名与排序（数字段是 ASCII），
    // 所以即使中文名乱码也不影响页序；不为此引入编码转换。
    if (header.FileName[0] != '\0') {
        return std::string(header.FileName);
    }
    return std::string();
}

} // namespace

extern "C" {

URShimArchive *URShimOpen(const char *path) {
    if (path == nullptr) { return nullptr; }

    ArchiveHandle *archive = new ArchiveHandle();
    archive->path = std::string(path);
    archive->lastError = 0;

    unsigned int openResult = 0;
    HANDLE handle = openArchive(archive->path, RAR_OM_LIST, &openResult);
    if (handle == nullptr) {
        archive->lastError = static_cast<int32_t>(openResult);
        return reinterpret_cast<URShimArchive *>(archive);
    }

    RARHeaderDataEx header;
    memset(&header, 0, sizeof(header));

    while (RARReadHeaderEx(handle, &header) == 0) {
        Entry entry;
        entry.name = entryName(header);
        entry.size = (static_cast<int64_t>(header.UnpSizeHigh) << 32) | static_cast<int64_t>(header.UnpSize);
        entry.isDirectory = (header.Flags & RHDF_DIRECTORY) != 0;
        archive->entries.push_back(entry);
        RARProcessFile(handle, RAR_SKIP, nullptr, nullptr);
    }

    RARCloseArchive(handle);
    return reinterpret_cast<URShimArchive *>(archive);
}

int32_t URShimEntryCount(const URShimArchive *archive) {
    if (archive == nullptr) { return 0; }
    return static_cast<int32_t>(handleOf(archive)->entries.size());
}

const char *URShimEntryName(const URShimArchive *archive, int32_t index) {
    if (archive == nullptr) { return nullptr; }
    const ArchiveHandle *handle = handleOf(archive);
    if (index < 0 || index >= static_cast<int32_t>(handle->entries.size())) { return nullptr; }
    return handle->entries[static_cast<size_t>(index)].name.c_str();
}

bool URShimExtractTo(URShimArchive *archive,
                     int32_t index,
                     const char *destinationDirectory,
                     const char *destinationName) {
    if (archive == nullptr || destinationDirectory == nullptr || destinationName == nullptr) {
        return false;
    }

    ArchiveHandle *handle = handleOf(archive);
    if (index < 0 || index >= static_cast<int32_t>(handle->entries.size())) {
        handle->lastError = -1;
        return false;
    }

    unsigned int openResult = 0;
    HANDLE unrar = openArchive(handle->path, RAR_OM_EXTRACT, &openResult);
    if (unrar == nullptr) {
        handle->lastError = static_cast<int32_t>(openResult);
        return false;
    }

    RARHeaderDataEx header;
    memset(&header, 0, sizeof(header));

    int32_t cursor = 0;
    bool succeeded = false;
    while (RARReadHeaderEx(unrar, &header) == 0) {
        if (cursor == index) {
            int result = RARProcessFile(
                unrar,
                RAR_EXTRACT,
                const_cast<char *>(destinationDirectory),
                const_cast<char *>(destinationName)
            );
            handle->lastError = result;
            succeeded = (result == 0);
            break;
        }
        RARProcessFile(unrar, RAR_SKIP, nullptr, nullptr);
        cursor += 1;
    }

    RARCloseArchive(unrar);
    return succeeded;
}

int32_t URShimLastError(const URShimArchive *archive) {
    if (archive == nullptr) { return -1; }
    return handleOf(archive)->lastError;
}

void URShimClose(URShimArchive *archive) {
    if (archive == nullptr) { return; }
    delete handleOf(archive);
}

} // extern "C"
