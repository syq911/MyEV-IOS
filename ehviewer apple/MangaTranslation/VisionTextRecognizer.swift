//
//  VisionTextRecognizer.swift
//  ehviewer apple
//
//  Apple Vision OCR —— 输出带位置与竖/横排方向的文本行
//

import Foundation
import Vision
import CoreGraphics
import ImageIO
import EhModels

/// 用系统 Vision 做 OCR。端上运行、免费、支持中/日（含竖排）。
///
/// 关键点：**CJK（中日）识别必须开启 `usesLanguageCorrection`**。
/// 关闭纠错时 Vision 会走通用拉丁模型，对日文/中文常常返回 **0 条观测** ——
/// 这正是历史「本页没有识别到文字」的根因（截图能识别、页图识别不到）。
///
/// 另外这里改成「多配置依次兜底」：首个能识别到文本的配置立即采用，
/// 并把每次尝试的结果通过 `diag()` 落到 EhViewerDiagnostics.log，出问题能一眼定位。
struct VisionTextRecognizer {

    /// 一次识别尝试的配置
    struct Attempt: Equatable {
        var recognitionLevel: VNRequestTextRecognitionLevel
        var usesLanguageCorrection: Bool
        var languages: [String]
    }

    /// 识别语言（BCP-47，如 "ja-JP" / "zh-Hans"）
    var languages: [String]
    /// 是否启用语言纠错。CJK 必须为 true，默认开启。
    var usesLanguageCorrection: Bool = true

    /// 兜底用的通用多语言集合
    static let broadLanguages = ["ja-JP", "zh-Hans", "zh-Hant", "en-US"]

    /// 依次尝试的配置：指定语言 → 通用多语言 → fast 档。首个有观测的立即采用。
    static func plannedAttempts(
        languages: [String],
        usesLanguageCorrection: Bool = true
    ) -> [Attempt] {
        var attempts: [Attempt] = [
            Attempt(
                recognitionLevel: .accurate,
                usesLanguageCorrection: usesLanguageCorrection,
                languages: languages
            )
        ]
        if languages != broadLanguages {
            attempts.append(Attempt(
                recognitionLevel: .accurate,
                usesLanguageCorrection: true,
                languages: broadLanguages
            ))
        }
        attempts.append(Attempt(
            recognitionLevel: .fast,
            usesLanguageCorrection: true,
            languages: broadLanguages
        ))
        return attempts
    }

    /// 对整页位图做 OCR（多配置兜底）
    func recognize(
        in cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) async throws -> [MangaTextLine] {
        let attempts = Self.plannedAttempts(
            languages: languages,
            usesLanguageCorrection: usesLanguageCorrection
        )
        diag("MangaTr/OCR: 位图 \(cgImage.width)x\(cgImage.height) bpc=\(cgImage.bitsPerComponent) 计划\(attempts.count)种配置")

        var lastError: Error?
        for (index, attempt) in attempts.enumerated() {
            let tag = "#\(index + 1)"
            do {
                let observations = try perform(cgImage: cgImage, orientation: orientation, attempt: attempt)
                diag("MangaTr/OCR: 配置\(tag) level=\(Self.levelName(attempt.recognitionLevel)) correction=\(attempt.usesLanguageCorrection) langs=\(attempt.languages) → 观测=\(observations.count)")
                let lines = Self.lines(from: observations)
                if !lines.isEmpty {
                    diag("MangaTr/OCR: 采用配置\(tag)，识别\(lines.count)行，示例=\(lines.prefix(3).map(\.text))")
                    return lines
                }
                diag("MangaTr/OCR: 配置\(tag) 无文本")
            } catch {
                lastError = error
                diag("MangaTr/OCR: 配置\(tag) 抛错 —— \(error)")
            }
        }
        if let lastError { throw lastError }
        diag("MangaTr/OCR: 所有配置均未识别到文本")
        return []
    }

    /// 用单个配置跑一次 Vision
    private func perform(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        attempt: Attempt
    ) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = attempt.recognitionLevel
        request.recognitionLanguages = attempt.languages
        request.usesLanguageCorrection = attempt.usesLanguageCorrection

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    /// 观测 → 文本行（过滤空串）
    static func lines(from observations: [VNRecognizedTextObservation]) -> [MangaTextLine] {
        var lines: [MangaTextLine] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = observation.boundingBox   // 归一化，原点左下
            let vertical = isVertical(box: box, text: text)
            lines.append(MangaTextLine(text: text, boundingBox: box, isVertical: vertical))
        }
        return lines
    }

    private static func levelName(_ level: VNRequestTextRecognitionLevel) -> String {
        level == .accurate ? "accurate" : "fast"
    }

    /// 判定竖排：包围盒明显「高 > 宽」即视为竖排。
    /// 单字符无法判断方向，按横排处理。
    static func isVertical(box: CGRect, text: String) -> Bool {
        guard box.width > 0, box.height > 0 else { return false }
        guard text.count > 1 else { return false }
        return box.height > box.width * 1.6
    }
}
