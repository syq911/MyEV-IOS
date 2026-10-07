//
//  MangaTranslationController.swift
//  ehviewer apple
//
//  漫画翻译编排器 —— 识别 → 翻译 → 排版，并做两级缓存。
//
//  交互：顶部翻译按钮**点一下开启连续翻译**（当前页 + 已预加载的后续页并行翻译），
//  **再点一下显示原文**。翻页时自动把新进入预加载窗口的页补进队列，因此可以一路往下看。
//
//  缓存（对应"翻译过就不该重翻"）：
//    - **文本级**（内存 + 落盘）：键 = (gid, page, 源/目标语言、后端、模型)，
//      命中的页直接跳过 OCR 与翻译接口，本地重排即可。
//    - **渲染级**（仅内存）：键 = (gid, page, 字号缩放/底色/原文小注)；
//      这些纯排版参数变化时只需重新渲染，不必重新翻译。
//  退出阅读器只清内存，不清磁盘 —— 重新进入点一下翻译即可秒出。
//

import Foundation
import Observation
import EhModels
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
@Observable
final class MangaTranslationController {

    /// 是否处于「连续翻译」模式（点一下开启，再点一下显示原文）
    private(set) var autoTranslate: Bool = false
    /// 是否显示译文（false 显示原图）
    private(set) var visible: Bool = false
    /// 队列中 + 进行中的页数
    private(set) var pendingCount: Int = 0
    /// 最近一次失败信息（点击后消除）
    private(set) var failureMessage: String?

    /// Apple 端上翻译桥（视图侧用 `.translationTask` 消费）
    @ObservationIgnored let appleBridge = AppleTranslationBridge()

    /// 已渲染的译文页（内存）
    @ObservationIgnored private var images: [String: PlatformImage] = [:]
    /// 每页渲染时用的排版签名（用于判断设置变化后是否需要重排）
    @ObservationIgnored private var renderedSignature: [String: String] = [:]
    /// 每页已翻译好的文本行（内存缓存，避免重复读盘）
    @ObservationIgnored private var lineCache: [String: [MangaTranslatedLine]] = [:]
    /// 每页文本行对应的翻译签名
    @ObservationIgnored private var lineCacheSignature: [String: String] = [:]
    /// 待处理队列（存 key）
    @ObservationIgnored private var queue: [String] = []
    /// 进行中的 key
    @ObservationIgnored private var running: Set<String> = []
    /// 每页的元数据（含源图）——只在主线程访问
    @ObservationIgnored private var jobs: [String: Job] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    private struct Job {
        let gid: Int64
        let page: Int
        let image: PlatformImage
    }

    private func key(gid: Int64, page: Int) -> String { "\(gid):\(page)" }

    /// 并行度。现代 Vision API 超过 2 个并行会死锁，端上翻译桥也只支持单会话。
    private var maxConcurrent: Int {
        MangaTranslationSettings.shared.provider == .appleOnDevice ? 1 : 2
    }

    // MARK: - 签名（与下载页「一键翻译」共用同一套，保证两边命中同一份持久化缓存）

    /// 影响「翻译结果」的设置
    private func translationSignature(_ s: MangaTranslationSettings) -> String {
        MangaTranslationPipeline.translationSignature(s)
    }

    /// 只影响「排版」的设置
    private func renderSignature(_ s: MangaTranslationSettings) -> String {
        MangaTranslationPipeline.renderSignature(s)
    }

    // MARK: - 查询

    func hasTranslation(gid: Int64, page: Int) -> Bool { images[key(gid: gid, page: page)] != nil }

    /// 展示用图片：显示译文且该页已有译文时返回译文图，否则返回原图
    func displayImage(gid: Int64, page: Int, original: PlatformImage?) -> PlatformImage? {
        if visible, let translated = images[key(gid: gid, page: page)] { return translated }
        return original
    }

    /// 是否有页在翻译（驱动进度浮层）
    var isBusy: Bool { pendingCount > 0 }

    func dismissFailure() { failureMessage = nil }

    /// 清掉某画廊的**内存**译文缓存并停止其翻译（磁盘缓存保留，重进可秒出）
    func clear(gid: Int64) {
        let prefix = "\(gid):"
        images = images.filter { !$0.key.hasPrefix(prefix) }
        renderedSignature = renderedSignature.filter { !$0.key.hasPrefix(prefix) }
        lineCache = lineCache.filter { !$0.key.hasPrefix(prefix) }
        lineCacheSignature = lineCacheSignature.filter { !$0.key.hasPrefix(prefix) }
        cancelAll()
    }

    // MARK: - 顶部按钮：开 / 关连续翻译

    func toggleAutoTranslate(gid: Int64, currentPage: Int, preloaded: [Int: PlatformImage]) {
        if autoTranslate {
            stop()
        } else {
            start(gid: gid, currentPage: currentPage, preloaded: preloaded)
        }
    }

    private func start(gid: Int64, currentPage: Int, preloaded: [Int: PlatformImage]) {
        autoTranslate = true
        visible = true
        failureMessage = nil
        enqueuePreloaded(gid: gid, currentPage: currentPage, preloaded: preloaded)
    }

    private func stop() {
        autoTranslate = false
        visible = false
        cancelAll()
    }

    // MARK: - 翻页：补齐队列

    func onVisiblePageChanged(gid: Int64, currentPage: Int, preloaded: [Int: PlatformImage]) {
        guard autoTranslate else { return }
        // 丢掉已经翻过去的页，释放内存、避免无用功
        let stale = queue.filter { (jobs[$0]?.page ?? 0) < currentPage }
        queue.removeAll { stale.contains($0) }
        for k in stale { jobs[k] = nil }
        enqueuePreloaded(gid: gid, currentPage: currentPage, preloaded: preloaded)
    }

    /// 把预加载窗口里的页按「离当前页由近到远」入队（当前页优先）
    private func enqueuePreloaded(gid: Int64, currentPage: Int, preloaded: [Int: PlatformImage]) {
        let pages = preloaded.keys.sorted {
            abs($0 - currentPage) == abs($1 - currentPage)
                ? $0 < $1
                : abs($0 - currentPage) < abs($1 - currentPage)
        }
        for page in pages {
            guard let image = preloaded[page] else { continue }
            enqueue(gid: gid, page: page, image: image)
        }
        pump()
    }

    private func enqueue(gid: Int64, page: Int, image: PlatformImage) {
        let k = key(gid: gid, page: page)
        let settings = MangaTranslationSettings.shared
        // 已有渲染结果且排版参数没变 → 无需再处理
        if images[k] != nil, renderedSignature[k] == renderSignature(settings) { return }
        guard !running.contains(k), jobs[k] == nil else { return }
        jobs[k] = Job(gid: gid, page: page, image: image)
        queue.append(k)
    }

    // MARK: - 队列调度

    private func pump() {
        while running.count < maxConcurrent, !queue.isEmpty {
            let k = queue.removeFirst()
            running.insert(k)
            tasks[k] = Task { [weak self] in
                await self?.process(k)
                self?.finish(k)
            }
        }
        pendingCount = queue.count + running.count
    }

    private func finish(_ k: String) {
        running.remove(k)
        tasks[k] = nil
        jobs[k] = nil
        pendingCount = queue.count + running.count
        pump()
    }

    private func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        queue.removeAll()
        running.removeAll()
        jobs.removeAll()
        pendingCount = 0
    }

    // MARK: - 单页流程

    private func process(_ k: String) async {
        guard let job = jobs[k] else { return }
        let settings = MangaTranslationSettings.shared
        let transSig = translationSignature(settings)
        let renderSig = renderSignature(settings)
        do {
            try Task.checkCancellation()

            // 1) 取已翻译的文本行：内存 → 磁盘 → 才真正 OCR + 翻译
            var translated: [MangaTranslatedLine]
            if let cached = lineCache[k], lineCacheSignature[k] == transSig {
                translated = cached
            } else if let onDisk = MangaTranslationCache.shared.load(
                gid: job.gid, page: job.page, signature: transSig) {
                translated = onDisk
                lineCache[k] = onDisk
                lineCacheSignature[k] = transSig
            } else {
                let outcome = try await MangaTranslationPipeline.translatePage(
                    image: job.image, settings: settings, bridge: appleBridge)
                translated = outcome.lines
                // ★ 无文字的页也写入空标记（translated 为 []）：不再重试，且计入「已翻译」
                lineCache[k] = translated
                lineCacheSignature[k] = transSig
                MangaTranslationCache.shared.save(
                    gid: job.gid, page: job.page, signature: transSig, lines: translated)
            }
            try Task.checkCancellation()

            // 2) 渲染（纯布局，快）；无文字的页直接渲染原图
            let options = MangaTypesetter.Options(
                useSampledBackground: settings.useSampledBackground,
                showOriginalText: settings.showOriginalText,
                fontScale: CGFloat(settings.fontScale)
            )
            let rendered = MangaTypesetter.render(original: job.image, lines: translated, options: options)
            try Task.checkCancellation()
            images[k] = rendered
            renderedSignature[k] = renderSig
            if autoTranslate { visible = true }
            diag("MangaTr: 页完成 gid=\(job.gid) page=\(job.page) 行=\(translated.count)")
        } catch is CancellationError {
            // 用户关闭或翻页丢弃，静默
        } catch {
            // 真正的失败（网络 / 图片不可用 / 无 API Key…）：提示一下，但**不中断**队列，
            // 后续页继续翻译；失败的页不入缓存，下次进入会重试。
            diag("MangaTr: 页失败 gid=\(job.gid) page=\(job.page) —— \(error.localizedDescription)")
            if autoTranslate { failureMessage = error.localizedDescription }
        }
    }
}
