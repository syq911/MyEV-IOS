//
//  LocalComicTests.swift
//  ehviewer appleTests
//
//  本地漫画的纯逻辑：自然排序、导入筛选、书库与落盘。
//
//  这些用例存在的理由很直接：本地漫画最容易出错的两处
//  ——「页序错」和「页数虚高」——都发生在纯逻辑层，
//  能在这里钉住就不必到真机上一页页翻。
//

#if os(iOS)
import Testing
import Foundation
@testable import ehviewer_apple

// MARK: - 自然排序

struct NaturalSortTests {

    @Test func sortsNumbersByValue() {
        let input = ["10.jpg", "2.jpg", "1.jpg", "100.jpg"]
        #expect(NaturalSort.sorted(input) == ["1.jpg", "2.jpg", "10.jpg", "100.jpg"])
    }

    @Test func sortsChineseChapterNames() {
        // 最常见的漫画命名：「第2话」必须排在「第10话」前面
        let input = ["第10话", "第2话", "第1话"]
        #expect(NaturalSort.sorted(input) == ["第1话", "第2话", "第10话"])
    }

    @Test func numberInsidePathStillSorts() {
        let input = ["ch1/10.jpg", "ch1/2.jpg", "ch1/1.jpg"]
        #expect(NaturalSort.sorted(input) == ["ch1/1.jpg", "ch1/2.jpg", "ch1/10.jpg"])
    }

    @Test func shorterZeroPaddingComesFirstWhenValueEqual() {
        // 数值相同：位数少的在前，保证顺序确定（否则 "1" 与 "01" 谁先谁后看运气）
        #expect(NaturalSort.isOrderedBefore("1.jpg", "01.jpg"))
        #expect(!NaturalSort.isOrderedBefore("01.jpg", "1.jpg"))
    }

    @Test func comparisonIsCaseInsensitive() {
        // 大小写不敏感：a 在 B 之前
        #expect(NaturalSort.isOrderedBefore("a.jpg", "B.jpg"))
    }

    @Test func veryLongDigitsDoNotOverflow() {
        // 不能把数字段转 Int：这里超过 Int64 范围
        #expect(NaturalSort.isOrderedBefore(
            "99999999999999999999.jpg",
            "100000000000000000000.jpg"
        ))
    }

    @Test func identicalStringsAreEqual() {
        #expect(NaturalSort.compare("same.jpg", "same.jpg") == .orderedSame)
    }

    @Test func mixedLettersAndNumbers() {
        let input = ["IMG_0010.png", "IMG_0002.png", "IMG_0001.png"]
        #expect(NaturalSort.sorted(input) == ["IMG_0001.png", "IMG_0002.png", "IMG_0010.png"])
    }
}

// MARK: - 导入筛选

struct LocalComicImportPlanTests {

    @Test func recognizesImageExtensions() {
        #expect(LocalComicImportPlan.isImageFileName("a.jpg"))
        #expect(LocalComicImportPlan.isImageFileName("a.JPG"))
        #expect(LocalComicImportPlan.isImageFileName("a.jpeg"))
        #expect(LocalComicImportPlan.isImageFileName("a.webp"))
        #expect(!LocalComicImportPlan.isImageFileName("a.txt"))
        #expect(!LocalComicImportPlan.isImageFileName("README"))
    }

    @Test func rejectsJunkEntries() {
        #expect(LocalComicImportPlan.isJunkPath("__MACOSX/._page1.jpg"))
        #expect(LocalComicImportPlan.isJunkPath(".DS_Store"))
        #expect(LocalComicImportPlan.isJunkPath("folder/"))
        #expect(!LocalComicImportPlan.isJunkPath("normal/1.jpg"))
    }

    @Test func filtersThenSortsNaturally() {
        let names = [
            "10.jpg", "2.jpg", "1.jpg",
            "__MACOSX/._10.jpg", ".DS_Store", "readme.txt", "folder/"
        ]
        #expect(LocalComicImportPlan.pageFileNames(from: names) == ["1.jpg", "2.jpg", "10.jpg"])
    }

    @Test func derivesTitleFromSourceName() {
        #expect(LocalComicImportPlan.title(fromSourceName: "某某作品 [作者].cbz") == "某某作品 [作者]")
        #expect(LocalComicImportPlan.title(fromSourceName: "  padded  .zip") == "padded")
        #expect(LocalComicImportPlan.title(fromSourceName: "无扩展名") == "无扩展名")
    }

    @Test func pageFileNameIsFixedWidth() {
        #expect(LocalComicImportPlan.pageFileName(index: 0, extension: "jpg") == "00000001.jpg")
        #expect(LocalComicImportPlan.pageFileName(index: 9, extension: "PNG") == "00000010.png")
        // jpeg 与 jpg 要统一，否则阅读器的扩展名白名单会漏掉一半页
        #expect(LocalComicImportPlan.pageFileName(index: 0, extension: "jpeg") == "00000001.jpg")
    }
}

// MARK: - 书库

struct LocalComicLibraryTests {

    private func makeComic(
        title: String = "A",
        pages: Int = 10,
        addedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        kind: LocalComic.SourceKind = .zip
    ) -> LocalComic {
        LocalComic(title: title, pageCount: pages, addedAt: addedAt, sourceKind: kind, sourceName: title + ".cbz")
    }

    @Test func upsertReplacesExisting() {
        var library = LocalComicLibrary()
        var comic = makeComic(title: "One")
        library.upsert(comic)
        comic.title = "Renamed"
        library.upsert(comic)

        #expect(library.comics.count == 1)
        #expect(library.comics.first?.title == "Renamed")
    }

    @Test func removeReturnsRemovedComic() {
        var library = LocalComicLibrary()
        let comic = makeComic()
        library.upsert(comic)

        let removed = library.remove(id: comic.id)
        #expect(removed?.id == comic.id)
        #expect(library.comics.isEmpty)
        #expect(library.remove(id: UUID()) == nil)
    }

    @Test func progressIsClampedIntoRange() {
        var library = LocalComicLibrary()
        let comic = makeComic(pages: 5)
        library.upsert(comic)

        library.updateProgress(id: comic.id, page: 99)
        #expect(library.comic(id: comic.id)?.lastReadPage == 4)

        library.updateProgress(id: comic.id, page: -3)
        #expect(library.comic(id: comic.id)?.lastReadPage == 0)
    }

    @Test func sortsByRecentlyAdded() {
        var library = LocalComicLibrary()
        let older = makeComic(title: "Old", addedAt: Date(timeIntervalSince1970: 100))
        let newer = makeComic(title: "New", addedAt: Date(timeIntervalSince1970: 200))
        library.upsert(older)
        library.upsert(newer)

        #expect(library.sorted(by: .recentlyAdded).map(\.title) == ["New", "Old"])
    }

    @Test func sortsByTitleNaturally() {
        var library = LocalComicLibrary()
        for title in ["第10话", "第2话"] {
            library.upsert(makeComic(title: title))
        }
        #expect(library.sorted(by: .title).map(\.title) == ["第2话", "第10话"])
    }

    @Test func unreadComicsSinkInRecentlyReadOrder() {
        var library = LocalComicLibrary()
        var read = makeComic(title: "Read")
        library.upsert(read)
        let unread = makeComic(title: "Unread")
        library.upsert(unread)

        library.updateProgress(id: read.id, page: 1, at: Date(timeIntervalSince1970: 500))
        read = library.comic(id: read.id)!

        #expect(library.sorted(by: .recentlyRead).first?.title == "Read")
    }

    @Test func encodeDecodeRoundTrip() throws {
        var library = LocalComicLibrary()
        let comic = makeComic(title: "Round", pages: 7)
        library.upsert(comic)

        let decoded = LocalComicLibrary.decode(try library.encoded())
        #expect(decoded.comics.count == 1)
        #expect(decoded.comics.first?.title == "Round")
        #expect(decoded.comics.first?.pageCount == 7)
        // 时间只精确到秒，测试数据也用整秒，避免亚秒误差
        #expect(decoded.comics.first?.addedAt == comic.addedAt)
    }

    @Test func corruptedIndexFallsBackToEmpty() {
        let broken = Data("{ not json at all".utf8)
        #expect(LocalComicLibrary.decode(broken).comics.isEmpty)
    }

    @Test func readerIdentityIsNegativeAndStable() {
        let comic = makeComic()
        #expect(comic.readerIdentity < 0, "负数才不会和 e-hentai 的正 gid 撞车")
        #expect(comic.readerIdentity == comic.readerIdentity)
        #expect(comic.readerIdentity != makeComic().readerIdentity)
    }
}

// MARK: - 落盘

struct LocalComicStorageTests {

    private func makeStorage() throws -> LocalComicStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("localcomics-\(UUID().uuidString)", isDirectory: true)
        let storage = LocalComicStorage(root: root)
        try storage.ensureRootExists()
        return storage
    }

    @Test func savesAndLoadsLibrary() throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage.root) }

        var library = LocalComicLibrary()
        let comic = LocalComic(title: "保存", pageCount: 3, sourceKind: .folder, sourceName: "保存")
        library.upsert(comic)
        try storage.saveLibrary(library)

        let loaded = storage.loadLibrary()
        #expect(loaded.comics.first?.title == "保存")
        #expect(loaded.comics.first?.pageCount == 3)
    }

    @Test func pageURLsAreNaturallySorted() throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage.root) }

        let comic = LocalComic(title: "页序", pageCount: 3, sourceKind: .zip, sourceName: "页序")
        let dir = try storage.makeDirectory(for: comic.id)
        // 故意乱序写入，模拟用户塞进来的原始文件
        for name in ["00000010.jpg", "00000002.jpg", "00000001.jpg"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        // 非图片文件不该出现在页列表里
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let urls = storage.pageURLs(for: comic)
        #expect(urls.map(\.lastPathComponent) == ["00000001.jpg", "00000002.jpg", "00000010.jpg"])
    }

    @Test func pageMapIsZeroBasedInFileOrder() throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage.root) }

        let comic = LocalComic(title: "映射", pageCount: 3, sourceKind: .zip, sourceName: "映射")
        let dir = try storage.makeDirectory(for: comic.id)
        for name in ["00000010.jpg", "00000002.jpg", "00000001.jpg"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }

        let map = storage.pageMap(for: comic)
        // 页码必须从 0 开始、连续、且与文件自然序一一对应
        #expect(map.keys.sorted() == [0, 1, 2])
        #expect(map[0]?.lastPathComponent == "00000001.jpg")
        #expect(map[1]?.lastPathComponent == "00000002.jpg")
        #expect(map[2]?.lastPathComponent == "00000010.jpg")
    }

    @Test func removesComicDirectory() throws {
        let storage = try makeStorage()
        defer { try? FileManager.default.removeItem(at: storage.root) }

        let comic = LocalComic(title: "删除", pageCount: 1, sourceKind: .zip, sourceName: "删除")
        let dir = try storage.makeDirectory(for: comic.id)
        try Data("x".utf8).write(to: dir.appendingPathComponent("00000001.jpg"))

        storage.removeFiles(for: comic)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}

#endif
