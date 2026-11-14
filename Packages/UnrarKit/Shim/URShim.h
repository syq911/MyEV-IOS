//
//  URShim.h
//  UnrarKit（vendored）
//
//  极小的 C 接口 —— App 只需要「列条目 / 按序抽取一页」这两件事。
//
//  为什么不直接暴露 UnrarKit 的 ObjC 类：它的公开头文件里 `#import "raros.hpp"`、
//  `"dll.hpp"`，也就是把 unrar 的内部头文件暴露到了模块边界上。SwiftPM 生成
//  Clang module 时不会带上目标内部的 header search path，于是模块构建阶段直接
//  报 `'raros.hpp' file not found`。
//  这里改成只暴露纯 C 接口，unrar 的头文件留在实现文件里，模块边界保持干净。
//

#ifndef UR_SHIM_H
#define UR_SHIM_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct URShimArchive URShimArchive;

/// 打开压缩包并枚举条目。失败返回 NULL。
URShimArchive *URShimOpen(const char *path);

/// 条目数量
int32_t URShimEntryCount(const URShimArchive *archive);

/// 条目名（UTF-8 / ASCII，指针归 archive 所有，关闭前有效）
const char *URShimEntryName(const URShimArchive *archive, int32_t index);

/// 解压第 index 个条目到 destinationDirectory/destinationName。
bool URShimExtractTo(URShimArchive *archive,
                     int32_t index,
                     const char *destinationDirectory,
                     const char *destinationName);

/// 最近一次错误的 unrar 错误码（0 表示成功）
int32_t URShimLastError(const URShimArchive *archive);

/// 释放
void URShimClose(URShimArchive *archive);

#ifdef __cplusplus
}
#endif

#endif /* UR_SHIM_H */
