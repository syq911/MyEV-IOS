//
//  LocalComic.swift
//  ehviewer apple
//
//  本地漫画：数据模型 + 书库（纯逻辑）+ 文件存储。
//
//  设计要点：
//  - 一本本地漫画 = 沙盒里的一个目录，里面是**已按页序重命名**的图片
//    （`00000001.jpg`、`00000002.jpg`…）。重命名发生在导入时，
//    好处是即使压缩包里的原始文件名乱七八糟（`10.jpg` / `a.jpg`），
//    落到磁盘上之后顺序也是确定的，阅读器不必再理解命名规则。
//  - 书库索引是一份 JSON，不写数据库：字段少、要能整体迁移、
//    而且本地漫画数量通常在几百本以内，用不上 SQL。
//  - 删除时先删索引再删文件：反过来的话，删文件成功但索引写失败，
//    会留下一本「点开报错」的幽灵条目。
//

import Foundation

// MARK: - 模型

struct LocalComic: Codable, Identifiable, Equatable, Hashable {

    enum SourceKind: String, Codable {
        case folder
        case zip
        case rar
    }

    var id: UUID
    var title: String
    var pageCount: Int
    var addedAt: Date
    var lastReadPage: Int
    var lastReadAt: Date?
    var sourceKind: SourceKind
    /// 导入时的原始名字（压缩包文件名 / 文件夹名），用于展示来源
    var sourceName: String

    init(
        id: UUID = UUID(),
        title: String,
        pageCount: Int,
        addedAt: Date = Date(),
        lastReadPage: Int = 0,
        lastReadAt: Date? = nil,
        sourceKind: SourceKind,
        sourceName: String
    ) {
        self.id = id
        self.title = title
        self.pageCount = pageCount
        self.addedAt = addedAt
        self.lastReadPage = lastReadPage
        self.lastReadAt = lastReadAt
        self.sourceKind = sourceKind
        self.sourceName = sourceName
    }

    /// 沙盒里的目录名（用 id，避免标题里的特殊字符影响路径）
    var directoryName: String { id.uuidString }

    /// 阅读器需要的「伪 gid」：翻译缓存以 gid 为键，本地漫画必须有自己的身份，
    /// 否则所有本地漫画会共用同一个缓存槽位、互相串译文。
    /// 取负值 —— e-hentai 的 gid 全为正数，这样永远不会和在线画廊撞号。
    var readerIdentity: Int64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in id.uuidString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return -Int64(hash % 9_000_000_000_000) - 1
    }

    var hasProgress: Bool { lastReadPage > 0 }

    /// 「读至 12 / 48」
    var progressText: String {
        LocalComicText.progress(current: lastReadPage + 1, total: pageCount)
    }
}

// MARK: - 文案（集中一处，便于以后本地化）

enum LocalComicText {
    static func progress(current: Int, total: Int) -> String {
        "读至 \(min(current, total)) / \(total)"
    }
    static let pagesSuffix = "页"
    static let importButton = "导入"
    static let emptyTitle = "还没有本地漫画"
    static let emptyHint = "从「文件」里选择压缩包（zip / cbz / rar / cbr）或整个文件夹"
    static let importing = "正在导入…"
    static let deleteTitle = "删除本地漫画？"
    static let deleteMessage = "会同时删除 App 内的副本文件，原始文件不受影响。"
}

// MARK: - 排序

enum LocalComicSort: String, CaseIterable, Identifiable {
    case recentlyAdded
    case title
    case recentlyRead

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recentlyAdded: return "按添加时间"
        case .title: return "按标题"
        case .recentlyRead: return "按最近阅读"
        }
    }
}

// MARK: - 书库（纯逻辑，可单测）

struct LocalComicLibrary: Codable, Equatable {

    /// 索引格式版本：将来加减字段时用来决定要不要迁移
    var version: Int
    var comics: [LocalComic]

    init(version: Int = LocalComicLibrary.currentVersion, comics: [LocalComic] = []) {
        self.version = version
        self.comics = comics
    }

    static let currentVersion = 1

    func comic(id: UUID) -> LocalComic? {
        comics.first { $0.id == id }
    }

    mutating func upsert(_ comic: LocalComic) {
        if let index = comics.firstIndex(where: { $0.id == comic.id }) {
            comics[index] = comic
        } else {
            comics.append(comic)
        }
    }

    @discardableResult
    mutating func remove(id: UUID) -> LocalComic? {
        guard let index = comics.firstIndex(where: { $0.id == id }) else { return nil }
        return comics.remove(at: index)
    }

    /// 记录阅读进度（页码 0-based；越界会被夹到有效范围）
    mutating func updateProgress(id: UUID, page: Int, at date: Date = Date()) {
        guard let index = comics.firstIndex(where: { $0.id == id }) else { return }
        let total = comics[index].pageCount
        comics[index].lastReadPage = min(max(0, page), max(0, total - 1))
        comics[index].lastReadAt = date
    }

    func sorted(by order: LocalComicSort) -> [LocalComic] {
        switch order {
        case .recentlyAdded:
            return comics.sorted {
                $0.addedAt == $1.addedAt
                    ? NaturalSort.isOrderedBefore($0.title, $1.title)
                    : $0.addedAt > $1.addedAt
            }
        case .title:
            return comics.sorted { NaturalSort.isOrderedBefore($0.title, $1.title) }
        case .recentlyRead:
            return comics.sorted {
                // 没读过的排在读过之后，但仍按添加时间排列
                let l = $0.lastReadAt ?? .distantPast
                let r = $1.lastReadAt ?? .distantPast
                if l == r {
                    return $0.addedAt > $1.addedAt
                }
                return l > r
            }
        }
    }

    // MARK: 持久化

    static func decode(_ data: Data) -> LocalComicLibrary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // 索引损坏时退回空书库：宁可「看不到书」，也不要让 App 起不来
        return (try? decoder.decode(LocalComicLibrary.self, from: data)) ?? LocalComicLibrary()
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // 排序键 + 缩进：索引是纯文本，出问题时能直接打开看
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

// MARK: - 文件存储

/// 负责本地漫画在沙盒里的落盘位置与读写。
///
/// 根目录放在 Application Support 而不是 Documents：
/// App 开了 `UIFileSharingEnabled`，Documents 会被「文件」App 直接暴露，
/// 把动辄几百 MB 的漫画副本堆进去会很难看，也容易被用户误删。
final class LocalComicStorage {

    let root: URL

    private let libraryFileName = "library.json"

    init(root: URL) {
        self.root = root
    }

    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("LocalComics", isDirectory: true)
    }

    var libraryURL: URL { root.appendingPathComponent(libraryFileName, isDirectory: false) }

    func ensureRootExists() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func loadLibrary() -> LocalComicLibrary {
        guard let data = try? Data(contentsOf: libraryURL) else { return LocalComicLibrary() }
        return LocalComicLibrary.decode(data)
    }

    func saveLibrary(_ library: LocalComicLibrary) throws {
        try ensureRootExists()
        let data = try library.encoded()
        // 原子写：写到一半被杀进程不会留下半截 JSON
        try data.write(to: libraryURL, options: .atomic)
    }

    func directory(for comic: LocalComic) -> URL {
        root.appendingPathComponent(comic.directoryName, isDirectory: true)
    }

    func makeDirectory(for comicID: UUID) throws -> URL {
        let dir = root.appendingPathComponent(comicID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 页文件列表（已按自然序）
    func pageURLs(for comic: LocalComic) -> [URL] {
        pageURLs(in: directory(for: comic))
    }

    func pageURLs(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let images = names.filter { LocalComicImporter.isImageFileName($0) }
        return NaturalSort.sorted(images).map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    func removeFiles(for comic: LocalComic) {
        try? FileManager.default.removeItem(at: directory(for: comic))
    }
}
