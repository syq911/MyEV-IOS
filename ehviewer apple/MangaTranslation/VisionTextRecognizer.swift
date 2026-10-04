//
//  VisionTextRecognizer.swift
//  ehviewer apple
//
//  Apple Vision OCR —— 输出带位置与竖/横排方向的文本行
//

import Foundation
import Vision
import CoreGraphics

/// 用系统 Vision 做 OCR。端上运行、免费、支持中/日（含竖排）。
struct VisionTextRecognizer {
    /// 识别语言（BCP-47，如 "ja-JP" / "zh-Hans"）
    var languages: [String]
    /// 漫画对白用词不常规，关闭语言纠错往往更准
    var usesLanguageCorrection: Bool = false

    /// 对整页位图做 OCR
    func recognize(in cgImage: CGImage) async throws -> [MangaTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = usesLanguageCorrection

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        var lines: [MangaTextLine] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = observation.boundingBox   // 归一化，原点左下
            let vertical = Self.isVertical(box: box, text: text)
            lines.append(MangaTextLine(text: text, boundingBox: box, isVertical: vertical))
        }
        return lines
    }

    /// 判定竖排：包围盒明显「高 > 宽」即视为竖排。
    /// 单字符无法判断方向，按横排处理。
    static func isVertical(box: CGRect, text: String) -> Bool {
        guard box.width > 0, box.height > 0 else { return false }
        guard text.count > 1 else { return false }
        return box.height > box.width * 1.6
    }
}
