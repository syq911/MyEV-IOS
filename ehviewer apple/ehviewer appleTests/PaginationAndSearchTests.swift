//
//  PaginationAndSearchTests.swift
//  ehviewer appleTests
//
//  覆盖 issue #8 的两个回归点:
//    - 问题一: 列表分页游标解析 (searchnav / ptt 两种模式) —— hasMore 判定依赖 pages 的正负
//    - 问题三: 高级搜索最低评分 (f_sr / f_srdd) 必须出现在 URL 里
//
//  HTML 片段取自 Android EhViewer 的解析器测试资源
//  (app/src/test/resources/.../GalleryListParserNew.html)，保证与安卓版行为一致。
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
import EhModels
import EhParser
@testable import ehviewer_apple

// PlatformImage = UIImage(iOS) / NSImage(macOS)，其 size / images 定义在各自 UI 框架里，
// 必须按平台显式 import，否则断言里访问这些属性会报 "missing import of defining module"。
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct PaginationAndSearchTests {

    // MARK: - 分页解析 (issue #8 问题一)

    /// 现行 E-Hentai 版式: 无 .ptt，用 .searchnav 里的 #uprev / #unext 游标翻页
    /// 解析器必须把 pages 置为 -1 —— GalleryListView 靠 `pages < 0` 区分两种分页模式
    @Test func searchNavPaginationUsesNextHref() throws {
        let html = """
        <html><body>
        <div class="searchnav">
            <div><span id="ufirst">&lt;&lt; First</span></div>
            <div><span id="uprev">&lt; Prev</span></div>
            <div><a id="unext" href="https://e-hentai.org/?next=2370115">Next &gt;</a></div>
            <div><a id="ulast" href="https://e-hentai.org/?prev=1">Last &gt;&gt;</a></div>
        </div>
        </body></html>
        """

        let result = try GalleryListParser.parse(html)

        #expect(result.pages == -1, "searchnav 模式必须置 pages = -1")
        #expect(result.nextHref == "https://e-hentai.org/?next=2370115")
        // 首页的 #uprev 是 <span> 没有 href，不能当成"有上一页"
        #expect(result.prevHref == nil)
    }

    /// 末页: #unext 退化成 <span>，没有 href → nextHref 必须是 nil，否则会一直"加载更多"
    @Test func searchNavLastPageHasNoNextHref() throws {
        let html = """
        <html><body>
        <div class="searchnav">
            <div><a id="uprev" href="https://e-hentai.org/?prev=100">&lt; Prev</a></div>
            <div><span id="unext">Next &gt;</span></div>
        </div>
        </body></html>
        """

        let result = try GalleryListParser.parse(html)

        #expect(result.pages == -1)
        #expect(result.nextHref == nil)
        #expect(result.prevHref == "https://e-hentai.org/?prev=100")
    }

    /// 旧版式: .ptt 分页表格。pages 是正数，nextPage 从 ">" 链接里取
    @Test func pttPaginationReportsPageCount() throws {
        let html = """
        <html><body>
        <table class="ptt"><tbody><tr>
            <td><a href="https://e-hentai.org/?page=0">&lt;</a></td>
            <td class="ptds"><a href="https://e-hentai.org/?page=0">1</a></td>
            <td><a href="https://e-hentai.org/?page=1">2</a></td>
            <td><a href="https://e-hentai.org/?page=2">3</a></td>
            <td><a href="https://e-hentai.org/?page=1">&gt;</a></td>
        </tr></tbody></table>
        </body></html>
        """

        let result = try GalleryListParser.parse(html)

        // 倒数第二个 td 是最大页码
        #expect(result.pages == 3)
        #expect(result.nextPage == 1)
        #expect(result.nextHref == "https://e-hentai.org/?page=1")
    }

    /// ptt 末页: ">" 链接回绕到 page=0。
    /// nextHref 仍然非 nil，所以 hasMore 绝不能只看 nextHref —— 否则列表会翻回第一页循环
    @Test func pttLastPageWrapsBackToZero() throws {
        let html = """
        <html><body>
        <table class="ptt"><tbody><tr>
            <td><a href="https://e-hentai.org/?page=1">&lt;</a></td>
            <td><a href="https://e-hentai.org/?page=0">1</a></td>
            <td class="ptds"><a href="https://e-hentai.org/?page=1">2</a></td>
            <td><a href="https://e-hentai.org/?page=0">&gt;</a></td>
        </tr></tbody></table>
        </body></html>
        """

        let result = try GalleryListParser.parse(html)

        #expect(result.pages >= 0, "ptt 模式 pages 必须是非负数")
        #expect(result.nextPage == 0, "末页的下一页链接回绕到 page=0")
        #expect(result.nextHref != nil, "href 仍然存在, 正因如此才必须用 nextPage 判定末页")
    }

    // MARK: - 高级搜索 URL (issue #8 问题三)

    /// 最低评分必须落到 f_sr=on & f_srdd=N (对齐 Android ListUrlBuilder.build)
    @Test func minRatingAppearsInUrl() {
        var builder = ListUrlBuilder()
        builder.mode = .normal
        builder.advanceSearch = ListUrlBuilder.AdvanceSearch.default.rawValue
        builder.minRating = 4

        let url = builder.build(site: .eHentai)

        #expect(url.contains("advsearch=1"))
        #expect(url.contains("f_sr=on"))
        #expect(url.contains("f_srdd=4"))
    }

    /// 页数范围过滤
    @Test func pageRangeAppearsInUrl() {
        var builder = ListUrlBuilder()
        builder.mode = .normal
        builder.advanceSearch = 0
        builder.pageFrom = 10
        builder.pageTo = 50

        let url = builder.build(site: .eHentai)

        #expect(url.contains("f_sp=on"))
        #expect(url.contains("f_spf=10"))
        #expect(url.contains("f_spt=50"))
    }

    /// 未启用高级搜索时不能污染 URL
    @Test func noAdvanceSearchMeansCleanUrl() {
        var builder = ListUrlBuilder()
        builder.mode = .normal
        builder.keyword = "artist:foo"

        let url = builder.build(site: .eHentai)

        #expect(!url.contains("advsearch"))
        #expect(!url.contains("f_sr"))
        #expect(url.contains("f_search="))
    }

    // MARK: - 语言过滤 (Phase 6 搜索面板, 对齐 Android ListUrlBuilder.build)

    private static func searchValue(of url: String) -> String? {
        URLComponents(string: url)?.queryItems?.first { $0.name == "f_search" }?.value
    }

    /// 语言不是独立 URL 参数，而是以 language:xxx 前缀并入 f_search
    @Test func languageFilterPrefixesKeyword() {
        var builder = ListUrlBuilder()
        builder.mode = .normal
        builder.keyword = "test"
        builder.language = 1  // ListUrlBuilder.languageTags[1] == language:chinese

        let url = builder.build(site: .eHentai)

        #expect(Self.searchValue(of: url) == "language:chinese test")
        #expect(!url.contains("advsearch"))
    }

    /// 关键词已含 language:/l:/gid: 限定时不重复注入，避免双重过滤
    @Test func languageFilterSkipsWhenKeywordAlreadyQualified() {
        var builder = ListUrlBuilder()
        builder.mode = .normal
        builder.keyword = "language:english test"
        builder.language = 1

        let url = builder.build(site: .eHentai)

        #expect(Self.searchValue(of: url) == "language:english test")
    }

    /// 未选语言时不注入前缀
    @Test func noLanguageMeansPlainKeyword() {
        var builder = ListUrlBuilder()
        builder.mode = .normal
        builder.keyword = "test"

        let url = builder.build(site: .eHentai)

        #expect(Self.searchValue(of: url) == "test")
    }

    /// 订阅模式指向 /watched (issue #9: 只看订阅标签)
    @Test func subscriptionModeUsesWatchedUrl() {
        var builder = ListUrlBuilder()
        builder.mode = .subscription
        builder.minRating = 3
        builder.advanceSearch = 0

        let url = builder.build(site: .eHentai)

        #expect(url.contains("watched"))
        #expect(url.contains("f_srdd=3"))
    }

    // MARK: - 触底加载去重 (上游 issue #15 的防复发回归)
    //  1.3.2 把 galleries 改成带 didSet 的属性并在其中回写自身，导致滚到底追加时闪退。
    //  1.3.1 基线的去重逻辑本身是好的，这里把它抽成纯函数锁住行为，防止未来复刻出问题。

    private static func gids(_ values: [Int64]) -> [GalleryInfo] {
        values.map { GalleryInfo(gid: $0) }
    }

    /// 新一页全部是已有 gid → 判定分页回绕，返回 nil（调用方置 hasMore = false）
    @Test func allDuplicatePageSignalsExhausted() {
        let existing = Self.gids([1, 2, 3])
        let incoming = Self.gids([3, 2, 1])

        let result = GalleryListViewModel.freshGalleries(existing: existing, incoming: incoming)

        #expect(result == nil, "全重复必须返回 nil，让列表停止加载而不是无限追加")
    }

    /// 新一页部分重复 → 只追加没见过的那几条
    @Test func partiallyDuplicatePageAppendsOnlyFresh() {
        let existing = Self.gids([1, 2, 3])
        let incoming = Self.gids([3, 4, 5])

        let result = GalleryListViewModel.freshGalleries(existing: existing, incoming: incoming)

        #expect(result?.map(\.gid) == [4, 5])
    }

    /// 空的一页不算回绕（保持 1.3.1 原行为：继续按 pages/nextHref 判定 hasMore）
    @Test func emptyPageIsNotExhausted() {
        let existing = Self.gids([1, 2])

        let result = GalleryListViewModel.freshGalleries(existing: existing, incoming: [])

        #expect(result?.isEmpty == true, "空页返回空数组而非 nil")
    }

    /// 连续 3 次触底追加（模拟快速滚动连发）不异常、不重复、列表单调增长
    @Test func threeConsecutiveAppendsGrowWithoutDuplicates() {
        var list = Self.gids([1, 2, 3])

        for page in 0..<3 {
            let incoming = Self.gids([3, 4 + Int64(page) * 2, 5 + Int64(page) * 2])
            guard let fresh = GalleryListViewModel.freshGalleries(existing: list, incoming: incoming) else {
                Issue.record("第 \(page) 次追加不应被判定为回绕")
                return
            }
            list.append(contentsOf: fresh)
        }

        #expect(list.count == 9, "3,4,5,6,7,8 各追加一次 → 3 + 6")
        #expect(Set(list.map(\.gid)).count == list.count, "列表内不得出现重复 gid")
    }

    // MARK: - 阅读器本地加载 (1.4.1 Phase C)
    //  已下载的漫画慢在两点: 本地文件也走 URLSession 逐字节迭代 + 预取窗口只有 6 页。

    private static func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ehviewer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeCGImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// 用 ImageIO 落一张单帧真实图片到磁盘（PNG 解码分支用）
    private static func writeImage(_ image: CGImage, to url: URL, type: CFString) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw NSError(domain: "PaginationAndSearchTests", code: 1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "PaginationAndSearchTests", code: 2)
        }
    }

    /// 一段真实的两帧 GIF89a（8×8，帧延时 100ms，loop=0）。
    ///
    /// 不现场用 ImageIO 合成动图：合成结果虽然 `CGImageSourceGetCount == 2`，
    /// 但缺少 UIKit 判定动图所需的 GCE 元数据，`UIImage(data:)` 会退化成静图
    /// （`images == nil`），从而把「实现是否保留动画」的断言引向错误方向
    /// （1.4.1 Phase D 曾因此在 CI 连挂两轮）。
    private static let twoFrameGIFBase64 =
        "R0lGODlhCAAIAIEAANwoKAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQICgAAACwAAAAACAAIAAAIDwABCBxIsKDBgwgTKkwYEAAh+QQICgAAACwAAAAACAAIAIEoUNwAAAAAAAAAAAAIDwABCBxIsKDBgwgTKkwYEAA7"

    /// 本地图片走 ImageIO 直接解码（不再经过 URLSession 的伪下载管线）
    @Test func decodeLocalImageReadsFileDirectly() throws {
        let dir = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("00000001.png")
        let cgImage = try #require(Self.makeCGImage(width: 40, height: 30))
        try Self.writeImage(cgImage, to: url, type: "public.png" as CFString)

        let image = try #require(ReaderViewModel.decodeLocalImage(at: url))

        #expect(image.size.width > 0 && image.size.height > 0)
        #expect(Int(image.size.width.rounded()) == 40, "安全尺寸内应按原尺寸解码")
    }

    /// 不存在的文件必须返回 nil 而不是崩溃
    @Test func decodeLocalImageReturnsNilForMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ehviewer-tests-missing-\(UUID().uuidString).png")

        #expect(ReaderViewModel.decodeLocalImage(at: missing) == nil)
    }

    /// GIF 动画必须保留全部帧 —— 缩略图解码只取第一帧，会丢动画
    #if os(iOS)
    @Test func decodeLocalImageKeepsGIFAnimation() throws {
        let dir = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("00000001.gif")
        try #require(Data(base64Encoded: Self.twoFrameGIFBase64)).write(to: url)

        // 先确认 fixture 真的是两帧动图，否则失败原因会被误读成解码丢帧
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 2, "fixture 必须是两帧 GIF")

        let image = try #require(ReaderViewModel.decodeLocalImage(at: url))

        #expect(image.images?.count == 2, "两帧 GIF 解码后必须仍是两帧")
    }
    #endif

    /// 目录枚举一次性建立页码映射，省掉每页 4 次 fileExists（P2-D）
    @Test func scanLocalImageURLsMapsDownloadNaming() throws {
        let dir = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 下载目录里混有非图片文件与 .ehviewer 记录，不能被误认成页面
        for name in ["00000001.jpg", "00000002.png", "00000003.webp", ".ehviewer", "thumb.jpg"] {
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent(name).path,
                contents: Data()
            )
        }

        let map = ReaderViewModel.scanLocalImageURLs(in: dir)

        #expect(map.count == 3, "只认 8 位页码命名的图片")
        #expect(map[0]?.lastPathComponent == "00000001.jpg")
        #expect(map[1]?.lastPathComponent == "00000002.png")
        #expect(map[2]?.lastPathComponent == "00000003.webp")
    }

    /// 本地画廊必须一次铺 20 页（P2-B）
    @Test func localGalleryPreloadWindowIsTwentyPages() {
        let window = ReaderViewModel.preloadWindow(isDownloaded: true, budget: 6, forward: true)

        #expect(ReaderViewModel.localPreloadPages == 20)
        #expect(window.ahead == 20)
        #expect(window.behind == 3)
    }

    /// 在线画廊仍受设备预算约束，不能拿 20 个并发去锤 EH
    @Test func onlineGalleryPreloadWindowFollowsBudget() {
        let forward = ReaderViewModel.preloadWindow(isDownloaded: false, budget: 6, forward: true)
        #expect(forward.ahead == 6)
        #expect(forward.behind == 1)

        let backward = ReaderViewModel.preloadWindow(isDownloaded: false, budget: 6, forward: false)
        #expect(backward.ahead == 2, "逆向时前向窗口压缩到 budget/3")
        #expect(backward.behind == 6)
    }

    /// 常驻窗口必须覆盖预取窗口，否则刚预取的页会被立刻淘汰（来回空转）
    @Test @MainActor func localRetentionRadiusCoversPreloadWindow() {
        let viewModel = ReaderViewModel()
        viewModel.isDownloaded = true

        #expect(viewModel.retentionRadius >= ReaderViewModel.localPreloadPages + 3)
    }
}
