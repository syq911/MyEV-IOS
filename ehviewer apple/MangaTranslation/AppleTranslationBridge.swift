//
//  AppleTranslationBridge.swift
//  ehviewer apple
//
//  Apple 端上翻译（iOS 18+ / macOS 15+ 的 Translation 框架）
//
//  Translation 框架的 TranslationSession 只能由 SwiftUI 的 `.translationTask` 提供，
//  因此这里持有「待翻译文本 + 结果 continuation」，视图侧用 `.translationTask` 消费。
//

import Foundation
import Observation
import Translation

@available(iOS 18.0, macOS 15.0, *)
@MainActor
@Observable
final class AppleTranslationBridge {

    /// 供视图绑定：非 nil 时触发 `.translationTask`
    var configuration: TranslationSession.Configuration?

    @ObservationIgnored private var pendingTexts: [String] = []
    @ObservationIgnored private var continuation: CheckedContinuation<[String], Error>?

    /// 触发一次 Apple 端上翻译
    func translate(
        _ texts: [String],
        source: MangaTranslationSource,
        target: MangaTranslationTarget
    ) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        guard continuation == nil else { throw MangaTranslationError.cancelled }
        return try await withCheckedThrowingContinuation { cont in
            self.pendingTexts = texts
            self.continuation = cont
            let src = Self.localeLanguage(for: source)
            let tgt = Locale.Language(identifier: target.rawValue)
            self.configuration = TranslationSession.Configuration(source: src, target: tgt)
        }
    }

    /// 由视图的 `.translationTask` 调用
    func run(session: TranslationSession) async {
        guard let cont = continuation else { return }
        continuation = nil
        let texts = pendingTexts
        pendingTexts = []
        configuration = nil
        do {
            var results: [String] = []
            results.reserveCapacity(texts.count)
            for text in texts {
                let response = try await session.translate(text)
                results.append(response.targetText)
            }
            cont.resume(returning: results)
        } catch {
            cont.resume(throwing: error)
        }
    }

    static func localeLanguage(for source: MangaTranslationSource) -> Locale.Language? {
        switch source {
        case .auto: return nil
        case .japanese: return Locale.Language(identifier: "ja")
        case .chinese: return Locale.Language(identifier: "zh")
        case .english: return Locale.Language(identifier: "en")
        case .korean: return Locale.Language(identifier: "ko")
        }
    }
}
