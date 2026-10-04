//
//  MangaTranslationController.swift
//  ehviewer apple
//
//  漫画翻译编排器 —— 识别 → 翻译 → 排版，按 (gid,page) 缓存译文图
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

    /// 当前阶段（驱动阅读器 HUD）
    private(set) var stage: MangaTranslationStage = .idle
    /// 是否显示译文（false 显示原图）
    private(set) var visible: Bool = false

    /// Apple 端上翻译桥（视图侧用 `.translationTask` 消费）
    @ObservationIgnored let appleBridge = AppleTranslationBridge()

    @ObservationIgnored private var images: [String: PlatformImage] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?

    private func key(gid: Int64, page: Int) -> String { "\(gid):\(page)" }

    func hasTranslation(gid: Int64, page: Int) -> Bool { images[key(gid: gid, page: page)] != nil }

    /// 展示用图片：显示译文且该页已有译文时返回译文图，否则返回原图
    func displayImage(gid: Int64, page: Int, original: PlatformImage?) -> PlatformImage? {
        if visible, let translated = images[key(gid: gid, page: page)] { return translated }
        return original
    }

    func toggleVisible() { visible.toggle() }

    /// 用户确认了失败提示 → 回到 idle
    func acknowledge() {
        if case .failed = stage { stage = .idle }
    }

    /// 清掉某画廊的全部译文缓存
    func clear(gid: Int64) {
        let prefix = "\(gid):"
        images = images.filter { !$0.key.hasPrefix(prefix) }
    }

    /// 翻译某一页
    func translatePage(gid: Int64, page: Int, image: PlatformImage) {
        task?.cancel()
        task = Task { [weak self] in
            await self?.run(gid: gid, page: page, image: image)
        }
    }

    // MARK: - 主流程

    private func run(gid: Int64, page: Int, image: PlatformImage) async {
        let settings = MangaTranslationSettings.shared
        diag("MangaTr: 开始翻译 gid=\(gid) page=\(page) provider=\(settings.provider.label) source=\(settings.sourceLanguage.label) target=\(settings.targetLanguage.label)")
        do {
            await setStage(.recognizing)

            guard let cgImage = MangaTypesetter.cgImage(of: image) else {
                diag("MangaTr: 取 CGImage 失败 imageSize=\(image.size)")
                throw MangaTranslationError.imageUnavailable
            }
            let languages = settings.sourceLanguage.visionLanguages
            let lines: [MangaTextLine] = try await Task.detached(priority: .userInitiated) {
                try await VisionTextRecognizer(languages: languages).recognize(in: cgImage)
            }.value

            try Task.checkCancellation()
            guard !lines.isEmpty else {
                diag("MangaTr: OCR 未识别到任何文字 → noTextRecognized")
                throw MangaTranslationError.noTextRecognized
            }
            diag("MangaTr: OCR 完成 行数=\(lines.count)")

            await setStage(.translating)
            let texts = lines.map(\.text)
            diag("MangaTr: 开始翻译 \(texts.count) 条，后端=\(settings.provider.label)")
            let translations = try await translate(
                texts,
                source: settings.sourceLanguage,
                target: settings.targetLanguage,
                provider: settings.provider
            )
            guard translations.count == lines.count else {
                diag("MangaTr: 译文条数不匹配 expected=\(lines.count) got=\(translations.count)")
                throw MangaTranslationError.countMismatch(expected: lines.count, got: translations.count)
            }
            diag("MangaTr: 翻译完成 \(translations.count) 条")

            try Task.checkCancellation()
            await setStage(.rendering)

            let translatedLines = zip(lines, translations).map { line, text in
                MangaTranslatedLine(
                    source: line.text,
                    translated: text,
                    boundingBox: line.boundingBox,
                    isVertical: line.isVertical
                )
            }
            let options = MangaTypesetter.Options(
                useSampledBackground: settings.useSampledBackground,
                showOriginalText: settings.showOriginalText,
                fontScale: CGFloat(settings.fontScale)
            )
            let rendered = MangaTypesetter.render(original: image, lines: translatedLines, options: options)

            images[key(gid: gid, page: page)] = rendered
            visible = true
            diag("MangaTr: 排版完成，页面已更新 gid=\(gid) page=\(page)")
            await setStage(.done)
        } catch is CancellationError {
            diag("MangaTr: 已取消 gid=\(gid) page=\(page)")
            await setStage(.idle)
        } catch {
            diag("MangaTr: 失败 gid=\(gid) page=\(page) —— \(error.localizedDescription)")
            await setStage(.failed(error.localizedDescription))
        }
    }

    private func translate(
        _ texts: [String],
        source: MangaTranslationSource,
        target: MangaTranslationTarget,
        provider: MangaTranslationProvider
    ) async throws -> [String] {
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

    private func setStage(_ newStage: MangaTranslationStage) async {
        stage = newStage
    }
}
