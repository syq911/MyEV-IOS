//
//  LocalComicImporter.swift
//  ehviewer apple
//
//  把「用户从文件 App 选中的东西」变成「沙盒里一本可以读的漫画」。
//
//  支持的输入（对齐常见漫画软件，如 Tachiyomi 的 Local source、
//  Perfect Viewer 的目录导入）：
//  - 压缩包：zip / cbz（自己解），rar / cbr（UnrarKit）
//  - 文件夹：里面直接是图片 → 一本；里面是若干子文件夹 → 每个子文件夹一本
//
//  两个容易踩的点，单独说明：
//  1. **页序不靠文件名**。用户手里的包可能是 `1.jpg/2.jpg/10.jpg`，
//     甚至 `a.jpg/b.jpg`。导入时统一重命名成 `00000001.jpg`，
//     顺序在导入那一刻就定死，之后磁盘上怎么排都不会错。
//  2. **垃圾条目**。macOS 打的包会带 `__MACOSX/` 和 `._xxx.jpg`，
//     还有 `.DS_Store`。这些必须在「算页数」之前就剔掉，
//     否则页数会虚高、翻页会翻到空白页。
//

import Foundation
import EhModels
#if canImport(UnrarKit)
import UnrarKit
#endif

// MARK: - 错误

enum LocalComicImportError: LocalizedError {
    case noImages(String)
    case unsupportedArchive(String)
    case archiveFailed(String)
    case emptyFolder(String)

    var errorDescription: String? {
        switch self {
        case .noImages(let name): return "「\(name)」里没有可读取的图片（支持 jpg / png / gif / webp）"
        case .unsupportedArchive(let name): return "「\(name)」不是受支持的压缩包格式"
        case .archiveFailed(let message): return message
        case .emptyFolder(let name): return "「\(name)」里没有找到图片"
        }
    }
}

// MARK: - 纯逻辑（可单测）

enum LocalComicImportPlan {

    /// 阅读器能解码的图片扩展名。
    /// 与 `ReaderViewModel.scanLocalImageURLs` 保持一致 —— 那边决定「能读到哪几页」，
    /// 这边决定「导入哪些文件」，两处必须同源，否则会出现「导入了但读不出」。
    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]

    /// 落盘时统一用的扩展名（jpeg → jpg）
    static func normalizedExtension(_ ext: String) -> String {
        let lower = ext.lowercased()
        return lower == "jpeg" ? "jpg" : lower
    }

    static func isImageFileName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return false }
        return supportedExtensions.contains(ext.lowercased())
    }

    /// 是否是应该忽略的垃圾条目
    static func isJunkPath(_ name: String) -> Bool {
        if name.hasSuffix("/") { return true }              // 目录
        let components = name.split(separator: "/").map(String.init)
        for component in components {
            if component == "__MACOSX" { return true }
            // "._xxx.jpg" 是 macOS 的资源分叉文件，长得像图片但不是
            if component.hasPrefix(".") { return true }
        }
        return false
    }

    /// 从任意文件名列表里挑出「页」，并按自然序排好
    static func pageFileNames(from names: [String]) -> [String] {
        let pages = names.filter { !isJunkPath($0) && isImageFileName($0) }
        return NaturalSort.sorted(pages)
    }

    /// 从压缩包条目里挑出「页条目」，并按自然序排好
    static func pageEntries(from entries: [ZipEntry]) -> [ZipEntry] {
        let pages = entries.filter { !isJunkPath($0.name) && isImageFileName($0.name) }
        return pages.sorted { NaturalSort.isOrderedBefore($0.name, $1.name) }
    }

    /// 从文件名/文件夹名推导标题：去扩展名、去掉首尾空白
    static func title(fromSourceName name: String) -> String {
        var title = (name as NSString).deletingPathExtension
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = name }
        return title
    }

    /// 落盘文件名：`00000001.jpg`。
    /// 8 位定宽与下载目录的命名保持一致，`scanLocalImageURLs` 可以原样复用。
    static func pageFileName(index: Int, extension ext: String) -> String {
        String(format: "%08d.%@", index + 1, normalizedExtension(ext))
    }
}

// MARK: - 执行导入

final class LocalComicImporter {

    private let storage: LocalComicStorage
    private let fileManager = FileManager.default

    init(storage: LocalComicStorage) {
        self.storage = storage
    }

    /// 导入一个选中项（压缩包或文件夹），返回新增的书
    ///
    /// - Parameters:
    ///   - url: 文件 App 给的 URL（需要在调用期间持有安全作用域）
    ///   - progress: 0…1，主线程回调
    func importItem(at url: URL, progress: @escaping (Double) -> Void) throws -> [LocalComic] {
        let needsScopedAccess = url.startAccessingSecurityScopedResource()
        defer { if needsScopedAccess { url.stopAccessingSecurityScopedResource() } }

        try storage.ensureRootExists()

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw LocalComicImportError.emptyFolder(url.lastPathComponent)
        }

        if isDirectory.boolValue {
            return try importFolder(at: url, progress: progress)
        }
        return try importArchive(at: url, progress: progress)
    }

    // MARK: 压缩包

    private func importArchive(at url: URL, progress: @escaping (Double) -> Void) throws -> [LocalComic] {
        let sourceName = url.lastPathComponent
        let ext = (sourceName as NSString).pathExtension.lowercased()

        switch ext {
        case "zip", "cbz":
            return [try importZip(at: url, sourceName: sourceName, progress: progress)]
        case "rar", "cbr":
            return [try importRar(at: url, sourceName: sourceName, progress: progress)]
        default:
            throw LocalComicImportError.unsupportedArchive(sourceName)
        }
    }

    private func importZip(at url: URL, sourceName: String, progress: @escaping (Double) -> Void) throws -> LocalComic {
        let archive = try ZipArchive(url: url)
        let pages = LocalComicImportPlan.pageEntries(from: archive.entries)
        guard !pages.isEmpty else { throw LocalComicImportError.noImages(sourceName) }

        let comicID = UUID()
        let directory = try storage.makeDirectory(for: comicID)
        var written = 0

        do {
            for (index, entry) in pages.enumerated() {
                try Task.checkCancellation()
                let data = try archive.data(for: entry)
                let ext = (entry.name as NSString).pathExtension
                let target = directory.appendingPathComponent(
                    LocalComicImportPlan.pageFileName(index: index, extension: ext)
                )
                try data.write(to: target, options: .atomic)
                written += 1
                progress(Double(index + 1) / Double(pages.count))
            }
        } catch {
            // 半成品目录必须清掉：留着会让书库里多一本「点开是空」的书
            try? fileManager.removeItem(at: directory)
            throw error
        }

        guard written > 0 else {
            try? fileManager.removeItem(at: directory)
            throw LocalComicImportError.noImages(sourceName)
        }

        return LocalComic(
            id: comicID,
            title: LocalComicImportPlan.title(fromSourceName: sourceName),
            pageCount: written,
            sourceKind: .zip,
            sourceName: sourceName
        )
    }

    // MARK: RAR

    private func importRar(at url: URL, sourceName: String, progress: @escaping (Double) -> Void) throws -> LocalComic {
        #if canImport(UnrarKit)
        let comicID = UUID()
        let directory = try storage.makeDirectory(for: comicID)
        do {
            let archive = try URKArchive(url: url)
            let names = try archive.listFilenames()
            let pages = LocalComicImportPlan.pageFileNames(from: names)
            guard !pages.isEmpty else { throw LocalComicImportError.noImages(sourceName) }

            var written = 0
            for (index, name) in pages.enumerated() {
                try Task.checkCancellation()
                let data = try archive.extractData(fromFile: name)
                let ext = (name as NSString).pathExtension
                let target = directory.appendingPathComponent(
                    LocalComicImportPlan.pageFileName(index: index, extension: ext)
                )
                try data.write(to: target, options: .atomic)
                written += 1
                progress(Double(index + 1) / Double(pages.count))
            }

            guard written > 0 else { throw LocalComicImportError.noImages(sourceName) }
            return LocalComic(
                id: comicID,
                title: LocalComicImportPlan.title(fromSourceName: sourceName),
                pageCount: written,
                sourceKind: .rar,
                sourceName: sourceName
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        #else
        throw LocalComicImportError.unsupportedArchive(sourceName)
        #endif
    }

    // MARK: 文件夹

    /// 文件夹导入有两种形态，都支持：
    /// - 文件夹里直接是图片 → 一本书
    /// - 文件夹里是若干子文件夹（每个子文件夹一本书）→ 批量导入
    private func importFolder(at url: URL, progress: @escaping (Double) -> Void) throws -> [LocalComic] {
        let children = (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let directImages = children.filter { !isDirectory($0) && LocalComicImportPlan.isImageFileName($0.lastPathComponent) }
        if !directImages.isEmpty {
            let comic = try copyFolderContents(
                named: url.lastPathComponent,
                files: children.filter { !isDirectory($0) },
                sourceKind: .folder,
                progress: progress
            )
            return [comic]
        }

        // 没有直接图片 → 看看子文件夹
        let candidates = children
            .filter { isDirectory($0) }
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { $0 }
        guard !candidates.isEmpty else { throw LocalComicImportError.emptyFolder(url.lastPathComponent) }

        var comics: [LocalComic] = []
        for (index, sub) in candidates.enumerated() {
            let files = (try? fileManager.contentsOfDirectory(
                at: sub,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            guard files.contains(where: { !isDirectory($0) && LocalComicImportPlan.isImageFileName($0.lastPathComponent) }) else {
                continue
            }
            let comic = try copyFolderContents(
                named: sub.lastPathComponent,
                files: files,
                sourceKind: .folder,
                progress: { fraction in
                    progress((Double(index) + fraction) / Double(candidates.count))
                }
            )
            comics.append(comic)
        }

        guard !comics.isEmpty else { throw LocalComicImportError.emptyFolder(url.lastPathComponent) }
        return comics
    }

    /// 把一组文件按自然序复制进新目录，并重命名成定宽页名
    private func copyFolderContents(
        named name: String,
        files: [URL],
        sourceKind: LocalComic.SourceKind,
        progress: @escaping (Double) -> Void
    ) throws -> LocalComic {
        let imageFiles = files.filter { LocalComicImportPlan.isImageFileName($0.lastPathComponent) }
        let ordered = imageFiles.sorted { NaturalSort.isOrderedBefore($0.lastPathComponent, $1.lastPathComponent) }
        guard !ordered.isEmpty else { throw LocalComicImportError.noImages(name) }

        let comicID = UUID()
        let directory = try storage.makeDirectory(for: comicID)
        var written = 0

        do {
            for (index, file) in ordered.enumerated() {
                try Task.checkCancellation()
                let ext = (file.lastPathComponent as NSString).pathExtension
                let target = directory.appendingPathComponent(
                    LocalComicImportPlan.pageFileName(index: index, extension: ext)
                )
                do {
                    try fileManager.copyItem(at: file, to: target)
                    written += 1
                } catch {
                    // 单个文件复制失败（权限/损坏）不该让整本导入失败，
                    // 但必须记录下来 —— 页数会少，用户能看出来
                    diag("LocalComic: 复制失败 \(file.lastPathComponent): \(error.localizedDescription)")
                }
                progress(Double(index + 1) / Double(ordered.count))
            }
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }

        guard written > 0 else {
            try? fileManager.removeItem(at: directory)
            throw LocalComicImportError.noImages(name)
        }

        return LocalComic(
            id: comicID,
            title: LocalComicImportPlan.title(fromSourceName: name),
            pageCount: written,
            sourceKind: sourceKind,
            sourceName: name
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}
