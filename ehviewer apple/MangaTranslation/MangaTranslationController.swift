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

    /// 译文渲染版本号：每渲染完一页 +1。
    ///
    /// 存在的唯一原因：`images` 里装的是整页大图，刻意标了 `@ObservationIgnored`
    /// （否则每次写入都会让阅读器整页重算），但这样 SwiftUI 就**不知道**「某页的译文
    /// 刚渲染好」。结果就是：译文在你停在该页之后才算完时，画面不会刷新，看到的一直是原图，
    /// 直到别的东西（点一下唤出工具栏、翻页）触发重绘 —— 用户看到的现象是
    /// 「看几十页后只剩原文，点一下才出现译文」。
    ///
    /// 所以单独暴露一个轻量计数，由 `displayImage` 读一下，自然进入 body 的依赖集。
    private(set) var renderVersion: Int = 0

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
        // 读一下版本号：建立「译文渲染完成 → 页面重绘」的观察依赖。
        // 不能只靠 `visible`（它只在开关翻译时变化）。
        _ = renderVersion
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
        renderVersion &+= 1
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
        // 丢掉已经翻过去的页：既清队列，也**取消**还在跑的，
        // 否则 2 个并行槽位会被你已经翻过的页占着，当前页只能干等。
        dropBehind(before: currentPage - 3)
        enqueuePreloaded(gid: gid, currentPage: currentPage, preloaded: preloaded)
        // 当前页优先：这一步是「明明翻好了却不显示」的关键
        prioritizeVisible(gid: gid, currentPage: currentPage, preloaded: preloaded)
        // 常驻译文图只保留当前页附近：一本 1500 页的长条漫全程累积是 GB 级，
        // 不修剪迟早被系统杀掉（重排一次只要几百毫秒，比 OOM 划算）
        trimRendered(gid: gid, around: currentPage)
    }

    /// 清掉离当前页太远的**已渲染整页图**（磁盘缓存与文本行缓存不动）
    private func trimRendered(gid: Int64, around page: Int) {
        let prefix = "\(gid):"
        let keep = (page - 8)...(page + 40)

        func pageIndex(_ key: String) -> Int? {
            guard key.hasPrefix(prefix) else { return nil }
            return Int(key.dropFirst(prefix.count))
        }

        let stale = images.keys.filter { key in
            guard let p = pageIndex(key) else { return false }
            return !keep.contains(p)
        }
        guard !stale.isEmpty else { return }
        for key in stale {
            images.removeValue(forKey: key)
            renderedSignature.removeValue(forKey: key)
        }
    }

    /// 丢掉某页之前的排队项，并取消还在处理中的（留一点余量：current-3）。
    private func dropBehind(before limit: Int) {
        guard limit > 0 else { return }
        let staleQueued = queue.filter { (jobs[$0]?.page ?? 0) < limit }
        queue.removeAll { staleQueued.contains($0) }
        for k in staleQueued { jobs[k] = nil }

        for (k, task) in tasks {
            guard let job = jobs[k], job.page < limit else { continue }
            task.cancel()
        }
    }

    /// 把当前页插到队首 —— 这是「译文已经翻好、但这页一直显示原图」的主因。
    ///
    /// 翻译是串行的（`maxConcurrent` 只有 1～2），一页要 2～5 秒。队列里躺着二十几页时，
    /// 你翻到的新页只能排到它们**后面**，等它算完你早就翻过去了。
    /// 而点一下开关之所以「立刻就好」：`stop()` 清空队列、`start()` 重新按距离入队，
    /// 当前页恰好排到了队首 —— 同一个页面，位置不同，结果就不同。
    ///
    /// 幂等：已有译文 / 正在处理 / 图还没解码，都直接返回。
    func prioritizeVisible(gid: Int64, currentPage: Int, preloaded: [Int: PlatformImage]) {
        guard autoTranslate, visible else { return }
        let k = key(gid: gid, page: currentPage)
        guard images[k] == nil, !running.contains(k) else { return }
        guard let image = preloaded[currentPage] else { return }

        jobs[k] = Job(gid: gid, page: currentPage, image: image)
        queue.removeAll { $0 == k }
        queue.insert(k, at: 0)
        pump()
        diag("MangaTr: 当前页插队 page=\(currentPage) 队列=\(queue.count) 并行=\(running.count)")
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
            var cacheHit = false
            if let cached = lineCache[k], lineCacheSignature[k] == transSig {
                translated = cached
                cacheHit = true
            } else if let onDisk = MangaTranslationCache.shared.load(
                gid: job.gid, page: job.page, signature: transSig) {
                translated = onDisk
                lineCache[k] = onDisk
                lineCacheSignature[k] = transSig
                cacheHit = true
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
            // 通知 SwiftUI「这页有译文了」（大图本身不参与观察，见 renderVersion 注释）
            renderVersion &+= 1
            if autoTranslate { visible = true }
            diag("MangaTr: 页完成 gid=\(job.gid) page=\(job.page) 行=\(translated.count) 命中缓存=\(cacheHit ? 1 : 0)")
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
