//
//  ZipArchive.swift
//  ehviewer apple
//
//  只读 ZIP 解析（支持 store / deflate），零第三方依赖。
//
//  为什么自己写：工程里没有任何解压库，而 ZIP 的读取部分其实很小——
//  找中央目录 → 读条目表 → 按需解压单个条目。用系统 `Compression` 框架
//  做 DEFLATE，不需要引外部依赖，包体和许可都干净。
//
//  支持范围（够漫画包用）：
//  - 压缩方法 0（store）与 8（deflate）
//  - 非 ZIP64（超过 4GB 或条目数 > 65535 会明确报错，不会静默读出半个文件）
//  - 逐条解压：解一条写一条，不会把整个压缩包展开进内存
//  - CRC32 校验：解压结果与条目声明不一致时报错，避免「看起来成功、
//    实际图片是坏的」
//

import Foundation
import Compression

struct ZipEntry: Equatable {
    let name: String
    let method: UInt16
    let crc32: UInt32
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int

    var isDirectory: Bool { name.hasSuffix("/") }
}

enum ZipError: LocalizedError {
    case notZipArchive
    case truncated
    case zip64Unsupported
    case unsupportedMethod(UInt16)
    case encryptedEntry
    case inflateFailed(String)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .notZipArchive: return "不是有效的 ZIP / CBZ 压缩包"
        case .truncated: return "压缩包不完整（可能没下载完）"
        case .zip64Unsupported: return "暂不支持 ZIP64（超过 4GB 或条目过多）"
        case .unsupportedMethod(let m): return "不支持的压缩方式（method = \(m)）"
        case .encryptedEntry: return "压缩包已加密，无法读取"
        case .inflateFailed(let name): return "解压失败：\(name)"
        case .checksumMismatch(let name): return "文件校验失败：\(name)"
        }
    }
}

struct ZipArchive {

    let entries: [ZipEntry]
    private let fileURL: URL

    /// 只解析目录，不解压 —— 导入时先用它判断包里有没有图片、页数多少
    init(url: URL) throws {
        self.fileURL = url
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        self.entries = try Self.parseEntries(in: data)
    }

    // MARK: 解析

    private static func parseEntries(in data: Data) throws -> [ZipEntry] {
        guard data.count > 22 else { throw ZipError.truncated }

        // ① 从尾部找「中央目录结束记录」(EOCD)。它前面可能还跟着最长 64KB 的注释，
        //    所以从尾部往前扫，而不是假设它就在最后 22 字节。
        let maxCommentLength = 65_535
        let searchStart = max(0, data.count - maxCommentLength - 22)
        var eocdOffset: Int?
        var cursor = data.count - 22
        while cursor >= searchStart {
            if data.u32(at: cursor) == 0x0605_4B50 {
                eocdOffset = cursor
                break
            }
            cursor -= 1
        }
        guard let eocd = eocdOffset else { throw ZipError.notZipArchive }

        let entryCount = Int(data.u16(at: eocd + 10) ?? 0)
        let centralDirectoryOffsetRaw = data.u32(at: eocd + 16) ?? 0
        let centralDirectorySizeRaw = data.u32(at: eocd + 12) ?? 0

        // ZIP64 标记：字段写满 0xFFFFFFFF / 0xFFFF 表示真实值在 ZIP64 扩展里
        if entryCount == 0xFFFF
            || centralDirectoryOffsetRaw == 0xFFFF_FFFF
            || centralDirectorySizeRaw == 0xFFFF_FFFF {
            throw ZipError.zip64Unsupported
        }

        let centralDirectoryOffset = Int(centralDirectoryOffsetRaw)
        guard centralDirectoryOffset >= 0, centralDirectoryOffset < data.count else {
            throw ZipError.truncated
        }

        // ② 遍历中央目录
        var result: [ZipEntry] = []
        result.reserveCapacity(entryCount)
        var offset = centralDirectoryOffset

        for _ in 0..<entryCount {
            guard data.u32(at: offset) == 0x0201_4B50 else { throw ZipError.truncated }

            let flags = data.u16(at: offset + 8) ?? 0
            let method = data.u16(at: offset + 10) ?? 0
            let crc = data.u32(at: offset + 16) ?? 0
            let compressedSize = Int(data.u32(at: offset + 20) ?? 0)
            let uncompressedSize = Int(data.u32(at: offset + 24) ?? 0)
            let nameLength = Int(data.u16(at: offset + 28) ?? 0)
            let extraLength = Int(data.u16(at: offset + 30) ?? 0)
            let commentLength = Int(data.u16(at: offset + 32) ?? 0)
            let localOffset = Int(data.u32(at: offset + 42) ?? 0)

            guard let nameData = data.slice(from: offset + 46, length: nameLength),
                  let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) else {
                throw ZipError.truncated
            }

            // 加密标志位（bit 0）——漫画包偶尔会带密码
            if flags & 0x0001 != 0 {
                throw ZipError.encryptedEntry
            }

            result.append(ZipEntry(
                name: name,
                method: method,
                crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset
            ))

            offset += 46 + nameLength + extraLength + commentLength
        }

        return result
    }

    // MARK: 解压

    /// 解出单个条目的内容
    func data(for entry: ZipEntry) throws -> Data {
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])

        // 本地文件头里的文件名/扩展字段长度决定了真正的数据起点，
        // 不能直接用中央目录里的偏移 + 固定长度。
        guard data.u32(at: entry.localHeaderOffset) == 0x0403_4B50 else { throw ZipError.truncated }
        let nameLength = Int(data.u16(at: entry.localHeaderOffset + 26) ?? 0)
        let extraLength = Int(data.u16(at: entry.localHeaderOffset + 28) ?? 0)
        let dataStart = entry.localHeaderOffset + 30 + nameLength + extraLength

        guard let payload = data.slice(from: dataStart, length: entry.compressedSize) else {
            throw ZipError.truncated
        }

        let output: Data
        switch entry.method {
        case 0:
            output = payload
        case 8:
            output = try Self.inflate(payload, expectedSize: entry.uncompressedSize, name: entry.name)
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }

        // CRC32 校验：解压「成功」但内容是坏的，是最难查的一类问题，
        // 在这里直接拦掉比事后排查图片打不开便宜得多
        if entry.crc32 != 0, Self.crc32(output) != entry.crc32 {
            throw ZipError.checksumMismatch(entry.name)
        }
        return output
    }

    /// raw DEFLATE 解压
    private static func inflate(_ payload: Data, expectedSize: Int, name: String) throws -> Data {
        // 有些写入器不填 uncompressedSize，这里从压缩后大小估一个起点，失败再翻倍
        var capacity = max(expectedSize, payload.count * 4, 64 * 1024)
        let hardLimit = 512 * 1024 * 1024

        while capacity <= hardLimit {
            var output = Data(count: capacity)
            let written: Int = output.withUnsafeMutableBytes { dst in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return payload.withUnsafeBytes { src -> Int in
                    guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(
                        dstBase, capacity,
                        srcBase, payload.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            if written > 0 {
                output.removeSubrange(written..<output.count)
                return output
            }
            capacity *= 2
        }
        throw ZipError.inflateFailed(name)
    }

    // MARK: CRC32

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Data 读取辅助

private extension Data {
    func u16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func u32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1]) << 8
        let b2 = UInt32(self[offset + 2]) << 16
        let b3 = UInt32(self[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    func slice(from offset: Int, length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset + length <= count else { return nil }
        return subdata(in: offset..<(offset + length))
    }
}
