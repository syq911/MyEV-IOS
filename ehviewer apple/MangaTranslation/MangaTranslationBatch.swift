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
        let signature = MangaTranslationPipeline.translationSignature(MangaTranslationSettings.shared)
        guard let dir = await DownloadManager.shared.localGalleryDirectory(gid: gid) else { return (0, 0) }
        let pages = ReaderViewModel.scanLocalImageURLs(in: dir).keys
        guard !pages.isEmpty else { return (0, 0) }
        let doneSet = MangaTranslationCache.shared.translatedPages(gid: gid, signature: signature)
        let done = pages.filter { doneSet.contains($0) }.count
        return (done, pages.count)
    }

    // MARK: - 开始 / 取消

    func start(gid: Int64) {
        guard tasks[gid] == nil else { return }
        jobs[gid] = Job(total: 0, done: 0, failed: 0, phase: .running)
        beginBackgroundAssertion()
        let signature = MangaTranslationPipeline.translationSignature(MangaTranslationSettings.shared)
        tasks[gid] = Task { [weak self] in
            await self?.run(gid: gid, signature: signature)
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

    private func run(gid: Int64, signature: String) async {
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

        // 1) 只翻已经下载到本地的页
        guard let dir = await DownloadManager.shared.localGalleryDirectory(gid: gid) else {
            jobs[gid] = Job(total: 0, done: 0, failed: 0, phase: .finished)
            return
        }
        let urls = ReaderViewModel.scanLocalImageURLs(in: dir)
        let pages = urls.keys.sorted()
        guard !pages.isEmpty else {
            jobs[gid] = Job(total: 0, done: 0, failed: 0, phase: .finished)
            return
        }

        // 2) 跳过已经翻过的页（含空标记）
        var doneSet = cache.translatedPages(gid: gid, signature: signature)
        var done = pages.filter { doneSet.contains($0) }.count
        var failed = 0
        jobs[gid] = Job(total: pages.count, done: done, failed: 0, phase: .running)

        for page in pages {
            if Task.isCancelled {
                mutateJob(gid) { $0.phase = .cancelled }
                return
            }
            guard !doneSet.contains(page), let url = urls[page] else { continue }

            var attempt = 0
            var succeeded = false
            while attempt < 2, !succeeded {
                attempt += 1
                do {
                    let image = try await decode(url)
                    let outcome = try await MangaTranslationPipeline.translatePage(
                        image: image, settings: settings, bridge: appleBridge)
                    cache.save(gid: gid, page: page, signature: signature, lines: outcome.lines)
                    doneSet.insert(page)
                    done += 1
                    mutateJob(gid) { $0.done = done }
                    succeeded = true
                } catch is CancellationError {
                    mutateJob(gid) { $0.phase = .cancelled }
                    return
                } catch {
                    if attempt >= 2 {
                        failed += 1
                        mutateJob(gid) { $0.failed = failed }
                        diag("MangaTr/Batch: 页失败 gid=\(gid) page=\(page) —— \(error.localizedDescription)")
                    } else {
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                }
            }
        }

        mutateJob(gid) { $0.phase = .finished }
        diag("MangaTr/Batch: 完成 gid=\(gid) 共\(pages.count)页 成功\(done) 失败\(failed)")
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
