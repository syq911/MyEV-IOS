//
//  MangaTranslationPipeline.swift
//  ehviewer apple
//
//  单页翻译流水线（OCR → 翻译 → 对齐到版面行）。
//
//  阅读器（MangaTranslationController）和下载页的「一键翻译」（MangaTranslationBatch）共用这一份逻辑，
//  避免两条路径行为不一致。
//
//  ⚠️ 关键约定（对应「某一页识别不到文字就停」的问题）：
//    **识别不到文字不是错误**，返回空数组表示「这一页没有需要翻译的内容」，
//    调用方把它当作「已处理完成」并继续下一页，而不是中断整条翻译流程。
//

import Foundation
import EhModels

/// 一次页翻译的结果分类 —— 让调用方区分「无字可翻」与「真的失败」
enum MangaTranslationOutcome: Sendable {
    /// 识别到并翻出了若干行（可能因模型漏项而少于识别行数）
    case translated([MangaTranslatedLine])
    /// 本页没有识别到任何文字 —— 正常跳过，不是失败
    case noText

    var lines: [MangaTranslatedLine] {
        switch self {
        case .translated(let lines): return lines
        case .noText: return []
        }
    }
}

// MARK: - 并发闸门

/// 通用的「最多 N 路」并发闸门。
///
/// 为什么需要它：一页的耗时大头是**翻译请求的往返**（1–4 秒），而 OCR 与排版是纯 CPU。
/// 把 CPU 环节卡在 2 路、其余页并行等网络，既避开 Vision 的并行死锁（>2 路会卡死，
/// 历史上踩过），也不会让 6 页同时排版把机器烧烫。
actor ConcurrencyGate {
    static let visionOCR = ConcurrencyGate(limit: 2)
    static let typesetRender = ConcurrencyGate(limit: 2)

    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// 名额直接转交给下一个等待者，不做「先减后加」，避免中间被插队
    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
enum MangaTranslationPipeline {
    /// 影响「翻译结果」的设置签名（换语言/后端/模型 → 需要重翻）
    static func translationSignature(_ s: MangaTranslationSettings) -> String {
        let model = s.provider == .deepSeek ? s.deepSeekModel : ""
        return "\(s.sourceLanguage.rawValue)|\(s.targetLanguage.rawValue)|\(s.provider.rawValue)|\(model)"
    }

    /// 只影响「排版」的设置签名（改字号/底色/原文小注 → 只需重排）
    static func renderSignature(_ s: MangaTranslationSettings) -> String {
        "\(s.fontScale)|\(s.useSampledBackground)|\(s.showOriginalText)"
    }

    // MARK: - 单页流水线

    /// OCR + 翻译一页。抛出的错误 = 真正需要重试/提示的失败（图片不可用、网络、无 API Key…）；
    /// 「没有识别到文字」返回 `.noText`，由调用方继续下一页。
    static func translatePage(
        image: PlatformImage,
        settings: MangaTranslationSettings,
        bridge: AppleTranslationBridge
    ) async throws -> MangaTranslationOutcome {
        guard let cgImage = MangaTypesetter.cgImage(of: image) else {
            throw MangaTranslationError.imageUnavailable
        }
        let languages = settings.sourceLanguage.visionLanguages
        let useFallback = settings.usesLineDropFallback
        // OCR 走闸门（最多 2 路），翻译请求不受限 —— 见 ConcurrencyGate 的注释
        await ConcurrencyGate.visionOCR.acquire()
        let ocrResult = await Task.detached(priority: .userInitiated) {
            var recognizer = VisionTextRecognizer(languages: languages)
            recognizer.usesLineDropFallback = useFallback
            return try await recognizer.recognize(in: cgImage)
        }.result
        await ConcurrencyGate.visionOCR.release()

        let lines: [MangaTextLine] = try ocrResult.get()
        try Task.checkCancellation()

        // ★ 无文字 → 正常的「空页」，不抛错、不中断
        guard !lines.isEmpty else { return .noText }

        let texts = lines.map(\.text)
        var map = try await translate(
            texts,
            source: settings.sourceLanguage,
            target: settings.targetLanguage,
            provider: settings.provider,
            settings: settings,
            bridge: bridge
        )

        // 有条数缺失（模型漏项）→ 只针对缺失的部分补一次，尽量把能翻的都翻出来
        let missing = lines.indices.filter { map[$0] == nil || map[$0]?.isEmpty == true }
        if !missing.isEmpty, missing.count <= 16 {
            let retryTexts = missing.map { texts[$0] }
            if let retry = try? await translate(
                retryTexts,
                source: settings.sourceLanguage,
                target: settings.targetLanguage,
                provider: settings.provider,
                settings: settings,
                bridge: bridge) {
                for (offset, index) in missing.enumerated() {
                    if let text = retry[offset], !text.isEmpty { map[index] = text }
                }
            }
        }

        // 只保留翻译到的行；没翻到的行保持原图（不画任何东西）
        let translated = lines.enumerated().compactMap { index, line -> MangaTranslatedLine? in
            guard let text = map[index],
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return MangaTranslatedLine(
                source: line.text,
                translated: text,
                boundingBox: line.boundingBox,
                isVertical: line.isVertical
            )
        }
        return .translated(translated)
    }

    // MARK: - 后端分发

    static func translate(
        _ texts: [String],
        source: MangaTranslationSource,
        target: MangaTranslationTarget,
        provider: MangaTranslationProvider,
        settings: MangaTranslationSettings,
        bridge: AppleTranslationBridge
    ) async throws -> [Int: String] {
        guard !texts.isEmpty else { return [:] }
        switch provider {
        case .deepSeek:
            let translator = DeepSeekTranslator(
                apiKey: settings.deepSeekAPIKey,
                baseURL: settings.deepSeekBaseURL,
                model: settings.deepSeekModel
            )
            return try await translator.translate(texts, source: source, target: target)
        case .appleOnDevice:
            return try await bridge.translate(texts, source: source, target: target)
        }
    }
}
