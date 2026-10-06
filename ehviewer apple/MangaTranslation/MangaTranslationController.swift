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

    // MARK: - 签名

    /// 影响「翻译结果」的设置
    private func translationSignature(_ s: MangaTranslationSettings) -> String {
        let model = s.provider == .deepSeek ? s.deepSeekModel : ""
        return "\(s.sourceLanguage.rawValue)|\(s.targetLanguage.rawValue)|\(s.provider.rawValue)|\(model)"
    }

    /// 只影响「排版」的设置
    private func renderSignature(_ s: MangaTranslationSettings) -> String {
        "\(s.fontScale)|\(s.useSampledBackground)|\(s.showOriginalText)"
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
                translated = try await recognizeAndTranslate(job: job, settings: settings)
                guard !translated.isEmpty else { throw MangaTranslationError.emptyResponse }
                lineCache[k] = translated
                lineCacheSignature[k] = transSig
                MangaTranslationCache.shared.save(
                    gid: job.gid, page: job.page, signature: transSig, lines: translated)
            }
            try Task.checkCancellation()

            // 2) 渲染（纯布局，快）
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
            diag("MangaTr: 页失败 gid=\(job.gid) page=\(job.page) —— \(error.localizedDescription)")
            if autoTranslate { failureMessage = error.localizedDescription }
        }
    }

    /// OCR + 翻译，返回「能翻出来的那些行」（数量不齐也照常返回）
    private func recognizeAndTranslate(
        job: Job,
        settings: MangaTranslationSettings
    ) async throws -> [MangaTranslatedLine] {
        guard let cgImage = MangaTypesetter.cgImage(of: job.image) else {
            throw MangaTranslationError.imageUnavailable
        }
        let languages = settings.sourceLanguage.visionLanguages
        let useFallback = settings.usesLineDropFallback
        let lines: [MangaTextLine] = try await Task.detached(priority: .userInitiated) {
            var recognizer = VisionTextRecognizer(languages: languages)
            recognizer.usesLineDropFallback = useFallback
            return try await recognizer.recognize(in: cgImage)
        }.value
        try Task.checkCancellation()
        guard !lines.isEmpty else { throw MangaTranslationError.noTextRecognized }

        let texts = lines.map(\.text)
        var map = try await translate(
            texts,
            source: settings.sourceLanguage,
            target: settings.targetLanguage,
            provider: settings.provider
        )

        // 有条数缺失（模型漏项）→ 只针对缺失的部分补一次，尽量把能翻的都翻出来
        let missing = lines.indices.filter { map[$0] == nil || map[$0]?.isEmpty == true }
        if !missing.isEmpty, missing.count <= 16 {
            let retryTexts = missing.map { texts[$0] }
            if let retry = try? await translate(
                retryTexts,
                source: settings.sourceLanguage,
                target: settings.targetLanguage,
                provider: settings.provider) {
                for (offset, index) in missing.enumerated() {
                    if let text = retry[offset], !text.isEmpty { map[index] = text }
                }
            }
        }

        // 只渲染翻译到的行；没翻到的行保持原图（不画任何东西）
        return lines.enumerated().compactMap { index, line in
            guard let text = map[index],
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return MangaTranslatedLine(
                source: line.text,
                translated: text,
                boundingBox: line.boundingBox,
                isVertical: line.isVertical
            )
        }
    }

    private func translate(
        _ texts: [String],
        source: MangaTranslationSource,
        target: MangaTranslationTarget,
        provider: MangaTranslationProvider
    ) async throws -> [Int: String] {
        switch provider {
        case .deepSeek:
            let settings = MangaTranslationSettings.shared
            let translator = DeepSeekTranslator(
                apiKey: settings.deepSeekAPIKey,
                baseURL: settings.deepSeekBaseURL,
                model: settings.deepSeekModel
            )
            return try await translator.translate(texts, source: source, target: target)
        case .appleOnDevice:
            return try await appleBridge.translate(texts, source: source, target: target)
        }
    }
}
