//
//  MangaTranslationCache.swift
//  ehviewer apple
//
//  漫画译文缓存（落盘）—— 按 (gid, page, 翻译参数签名) 存「已翻译的文本行」。
//
//  为什么要缓存「文本级」而不是「渲染后的整页图」：
//    - 字号缩放 / 底色 / 原文小注这些只影响排版，缓存文本后改这些设置**无需重新翻译**，
//      直接本地重排即可；
//    - 切到「显示原文」再切回译文、或退出阅读器重新进入时，直接命中缓存，不再调用翻译接口。
//
//  目录结构（位于 Application Support，**持久化存储**，重启/清理缓存都不会丢）：
//    Application Support/MangaTranslation/<gid>/<page>__<signature>.json
//
//  空文件（lines 为空）表示「这一页已经处理过、但没有需要翻译的文字」，
//  用来在进度统计里算作「已完成」，并避免后续反复 OCR 同一张无字图。
//

import Foundation
import CoreGraphics

final class MangaTranslationCache: @unchecked Sendable {

    static let shared = MangaTranslationCache()

    private let root: URL
    private let fm = FileManager.default
    /// 串行队列：落盘在后台进行，避免阻塞主线程
    private let ioQueue = DispatchQueue(label: "Stellatrix.ehviewer-apple.manga-translation.cache")

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        root = base.appendingPathComponent("MangaTranslation", isDirectory: true)
        // 1.4.20：从旧的 Caches 目录搬到持久化的 Application Support，尽量保留老数据
        Self.migrateFromCachesIfNeeded(to: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// 一次性迁移：把旧版本存在 `Caches/MangaTranslation` 的译文搬到新的持久化目录。
    /// 新目录已有内容时不动（避免覆盖）；旧目录不存在时直接跳过。
    private static func migrateFromCachesIfNeeded(to root: URL) {
        let fm = FileManager.default
        guard let cachesBase = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let old = cachesBase.appendingPathComponent("MangaTranslation", isDirectory: true)
        guard fm.fileExists(atPath: old.path) else { return }
        if fm.fileExists(atPath: root.path) {
            let isEmpty = ((try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty) ?? false
            guard isEmpty else { return }
            try? fm.removeItem(at: root)
        }
        try? fm.moveItem(at: old, to: root)
    }

    /// 仅供测试：使用自定义根目录的独立实例，避免污染真实缓存。
    static func makeForTesting(root: URL) -> MangaTranslationCache {
        MangaTranslationCache(root: root)
    }

    /// 仅供测试：等待所有异步落盘完成。
    func flush() { ioQueue.sync {} }

    // MARK: - 存储结构

    private struct StoredLine: Codable {
        let source: String
        let translated: String
        let x: Double
        let y: Double
        let w: Double
        let h: Double
        let isVertical: Bool
    }

    private struct StoredPage: Codable {
        let lines: [StoredLine]
        let savedAt: Date
    }

    // MARK: - 路径

    private func dir(for gid: Int64) -> URL {
        root.appendingPathComponent(String(gid), isDirectory: true)
    }

    /// 文件名里用到的签名：只保留字母/数字，其余替换为下划线，保证是合法文件名
    static func sanitize(_ signature: String) -> String {
        String(signature.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
    }

    private func fileURL(gid: Int64, page: Int, signature: String) -> URL {
        dir(for: gid).appendingPathComponent("\(page)__\(Self.sanitize(signature)).json")
    }

    // MARK: - 读写

    /// 读取某页的译文行；命中返回非 nil（空数组代表「该页已处理、无文字」）
    func load(gid: Int64, page: Int, signature: String) -> [MangaTranslatedLine]? {
        let url = fileURL(gid: gid, page: page, signature: signature)
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(StoredPage.self, from: data) else { return nil }
        return stored.lines.map {
            MangaTranslatedLine(
                source: $0.source,
                translated: $0.translated,
                boundingBox: CGRect(x: CGFloat($0.x), y: CGFloat($0.y),
                                    width: CGFloat($0.w), height: CGFloat($0.h)),
                isVertical: $0.isVertical
            )
        }
    }

    /// 某页（给定翻译签名）是否已处理过 —— 无论有无译文都算
    func hasEntry(gid: Int64, page: Int, signature: String) -> Bool {
        fm.fileExists(atPath: fileURL(gid: gid, page: page, signature: signature).path)
    }

    /// 该画廊在给定翻译签名下「已处理」的页码集合（含无文字的页）
    func translatedPages(gid: Int64, signature: String) -> Set<Int> {
        let suffix = "__\(Self.sanitize(signature)).json"
        guard let names = try? fm.contentsOfDirectory(atPath: dir(for: gid).path) else { return [] }
        var result: Set<Int> = []
        for name in names where name.hasSuffix(suffix) {
            let stem = String(name.dropLast(suffix.count))
            if let page = Int(stem) { result.insert(page) }
        }
        return result
    }

    /// 写入某页的译文行（异步落盘）。允许空数组 —— 作为「该页无文字、已处理」的标记。
    func save(gid: Int64, page: Int, signature: String, lines: [MangaTranslatedLine]) {
        let stored = StoredPage(
            lines: lines.map {
                StoredLine(
                    source: $0.source,
                    translated: $0.translated,
                    x: Double($0.boundingBox.minX),
                    y: Double($0.boundingBox.minY),
                    w: Double($0.boundingBox.width),
                    h: Double($0.boundingBox.height),
                    isVertical: $0.isVertical
                )
            },
            savedAt: Date()
        )
        let url = fileURL(gid: gid, page: page, signature: signature)
        let folder = dir(for: gid)
        ioQueue.async { [fm] in
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(stored) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - 清理

    func clear(gid: Int64) {
        ioQueue.async { [fm] in
            try? fm.removeItem(atPath: self.dir(for: gid).path)
        }
    }

    func clearAll() {
        ioQueue.async { [fm] in
            try? fm.removeItem(atPath: self.root.path)
            try? fm.createDirectory(atPath: self.root.path, withIntermediateDirectories: true)
        }
    }

    /// 缓存占用字节数（同步遍历，供设置页展示）
    var totalBytes: Int64 {
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}
