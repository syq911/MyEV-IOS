//
//  MangaTranslationBatch.swift
//  ehviewer apple
//
//  下载页「一键翻译」—— 后台批量翻译整本已下载的漫画。
//
//  与阅读器里的连续翻译共用 `MangaTranslationPipeline` 和 `MangaTranslationCache`
//  （持久化落盘），所以：
//    - 这里翻过的页，进阅读器点翻译直接命中缓存、秒出；
//    - 阅读器翻过的页，这里也会跳过，不重复调用接口。
//
//  只翻「已经下载到本地的页」（不联网抓图），以当前翻译设置为准。
//  由 `shared` 单例持有任务，因此用户离开下载页 / 切到别的标签页也会继续翻。
//
//  单页失败（网络抖动等）会重试一次；仍失败则计入失败并**继续下一页**，
//  绝不会因为某一页出问题而中断整本。
//

import Foundation
import Observation
import EhModels
import EhDownload
#if os(iOS)
import UIKit
#endif

@MainActor
@Observable
final class MangaTranslationBatch {

    static let shared = MangaTranslationBatch()
    private init() {}

    // MARK: - 状态

    enum Phase: Equatable {
        case running
        case finished
        case cancelled
    }

    struct Job: Equatable {
        var total: Int
        var done: Int
        var failed: Int
        var phase: Phase
    }

    /// gid → 批量翻译进度
    private(set) var jobs: [Int64: Job] = [:]

    /// Apple 端上翻译桥（由 RootView 的 `.translationTask` 消费）
    @ObservationIgnored let appleBridge = AppleTranslationBridge()

    @ObservationIgnored private var tasks: [Int64: Task<Void, Never>] = [:]
    #if os(iOS)
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    // MARK: - 查询

    func isRunning(gid: Int64) -> Bool { tasks[gid] != nil }

    func job(gid: Int64) -> Job? { jobs[gid] }

    /// 从磁盘统计：已下载的页里，有多少页已经翻过（含无文字的页）
    func diskSummary(gid: Int64) async -> (done: Int, total: Int) {
        guard let dir = await DownloadManager.shared.localGalleryDirectory(gid: gid) else { return (0, 0) }
        return diskSummary(gid: gid, pageURLs: ReaderViewModel.scanLocalImageURLs(in: dir))
    }

    /// 本地漫画：目录不归 DownloadManager 管，页由调用方给
    func diskSummary(gid: Int64, pageURLs: [Int: URL]) -> (done: Int, total: Int) {
        guard !pageURLs.isEmpty else { return (0, 0) }
        let signature = MangaTranslationPipeline.translationSignature(MangaTranslationSettings.shared)
        let doneSet = MangaTranslationCache.shared.translatedPages(gid: gid, signature: signature)
        let done = pageURLs.keys.filter { doneSet.contains($0) }.count
        return (done, pageURLs.count)
    }

    // MARK: - 开始 / 取消

    /// 下载画廊：页从下载目录取
    func start(gid: Int64) {
        start(gid: gid, pageURLs: nil)
    }

    /// 本地漫画：没有 DownloadManager 里的 gid 目录，页必须由调用方直接给。
    ///
    /// 之所以做成显式传入而不是再加一个「去某处找目录」的分支：
    /// 本地漫画的身份是**负数伪 gid**（由 UUID 派生），DownloadManager 里查不到它，
    /// 而猜路径（例如复用下载目录命名规则）会在将来改动存储布局时静默失效。
    /// 传进来的页本来就是调用方从自己的存储里读出来的唯一真相。
    func start(gid: Int64, pageURLs: [Int: URL]?) {
        guard tasks[gid] == nil else { return }
        jobs[gid] = Job(total: 0, done: 0, failed: 0, phase: .running)
        beginBackgroundAssertion()
        let signature = MangaTranslationPipeline.translationSignature(MangaTranslationSettings.shared)
        tasks[gid] = Task { [weak self] in
            await self?.run(gid: gid, signature: signature, pageURLs: pageURLs)
        }
    }

    func cancel(gid: Int64) {
        tasks[gid]?.cancel()
        if jobs[gid]?.phase == .running { mutateJob(gid) { $0.phase = .cancelled } }
    }

    private func mutateJob(_ gid: Int64, _ body: (inout Job) -> Void) {
        guard var job = jobs[gid] else { return }
        body(&job)
        jobs[gid] = job
    }

    private func cancelAll() {
        for task in tasks.values { task.cancel() }
    }

    // MARK: - 执行

    private func run(gid: Int64, signature: String, pageURLs: [Int: URL]?) async {
        defer {
            tasks[gid] = nil
            endBackgroundAssertionIfIdle()
        }

        let cache = MangaTranslationCache.shared
        let settings = MangaTranslationSettings.shared

        guard settings.enabled else {
            jobs[gid] = Job(total: 0, done: 0, failed: 0, phase: .finished)
            return
        }

        // 1) 页来源：下载画廊查下载目录；本地漫画由调用方直接给
        let urls: [Int: URL]
        if let pageURLs {
            urls = pageURLs
        } else {
            guard let dir = await DownloadManager.shared.localGalleryDirectory(gid: gid) else {
                jobs[gid] = Job(total: 0, done: 0, failed: 0, phase: .finished)
                return
            }
            urls = ReaderViewModel.scanLocalImageURLs(in: dir)
        }
        let pages = urls.keys.sorted()
        guard !pages.isEmpty else {
            jobs[gid] = Job(total: 0, done: 0, failed: 0, phase: .finished)
            return
        }

        // 2) 跳过已经翻过的页（含空标记）
        let doneSet = cache.translatedPages(gid: gid, signature: signature)
        var done = pages.filter { doneSet.contains($0) }.count
        var failed = 0
        jobs[gid] = Job(total: pages.count, done: done, failed: 0, phase: .running)

        let todo: [(page: Int, url: URL)] = pages.compactMap { page in
            guard !doneSet.contains(page), let url = urls[page] else { return nil }
            return (page, url)
        }
        // 并行宽度：一页的耗时几乎全在翻译请求往返，4 路能把整本时间压到 1/3 左右。
        // Apple 端上翻译的桥只支持单会话，只能串行。
        let width = settings.provider == .appleOnDevice ? 1 : 4

        // 原先是一页一页串行：1554 页 × 2–5 秒 = 一两个小时。
        // 改成有界并发（固定 width 个在飞，完成一个补一个），页序不影响结果。
        await withTaskGroup(of: Bool.self) { group in
            var next = 0
            while next < width, next < todo.count {
                let item = todo[next]
                next += 1
                group.addTask { [weak self] in
                    guard let self else { return false }
                    return await self.translateBatchPage(
                        page: item.page, url: item.url, gid: gid,
                        settings: settings, signature: signature
                    )
                }
            }

            for await succeeded in group {
                if succeeded { done += 1 } else { failed += 1 }
                mutateJob(gid) { $0.done = done; $0.failed = failed }
                if Task.isCancelled {
                    group.cancelAll()
                    mutateJob(gid) { $0.phase = .cancelled }
                    return
                }
                if next < todo.count {
                    let item = todo[next]
                    next += 1
                    group.addTask { [weak self] in
                        guard let self else { return false }
                        return await self.translateBatchPage(
                            page: item.page, url: item.url, gid: gid,
                            settings: settings, signature: signature
                        )
                    }
                }
            }
        }

        if Task.isCancelled {
            mutateJob(gid) { $0.phase = .cancelled }
            return
        }

        mutateJob(gid) { $0.phase = .finished }
        diag("MangaTr/Batch: 完成 gid=\(gid) 共\(pages.count)页 成功\(done) 失败\(failed)")
    }

    /// 单页：解码 → OCR+翻译 → 落盘。失败重试一次；返回是否成功。
    private func translateBatchPage(
        page: Int,
        url: URL,
        gid: Int64,
        settings: MangaTranslationSettings,
        signature: String
    ) async -> Bool {
        for attempt in 1...2 {
            do {
                let image = try await decode(url)
                let outcome = try await MangaTranslationPipeline.translatePage(
                    image: image, settings: settings, bridge: appleBridge)
                // 无文字的页也写空标记：下次不再重试，且计入「已翻译」
                MangaTranslationCache.shared.save(
                    gid: gid, page: page, signature: signature, lines: outcome.lines)
                return true
            } catch is CancellationError {
                return false
            } catch {
                if attempt == 2 {
                    diag("MangaTr/Batch: 页失败 gid=\(gid) page=\(page) —— \(error.localizedDescription)")
                    return false
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        return false
    }

    private func decode(_ url: URL) async throws -> PlatformImage {
        let image = await Task.detached(priority: .userInitiated) {
            ReaderViewModel.decodeLocalImage(at: url)
        }.value
        guard let image else { throw MangaTranslationError.imageUnavailable }
        return image
    }

    // MARK: - 后台时间断言（iOS）

    private func beginBackgroundAssertion() {
        #if os(iOS)
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MangaTranslationBatch") { [weak self] in
            // 系统给的额外时间耗尽 → 停止所有批量任务，避免被强制挂起
            self?.cancelAll()
            self?.endBackgroundAssertion()
        }
        #endif
    }

    private func endBackgroundAssertionIfIdle() {
        guard tasks.isEmpty else { return }
        endBackgroundAssertion()
    }

    private func endBackgroundAssertion() {
        #if os(iOS)
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        #endif
    }
}
