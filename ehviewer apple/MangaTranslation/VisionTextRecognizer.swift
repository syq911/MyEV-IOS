//
//  VisionTextRecognizer.swift
//  ehviewer apple
//
//  Apple Vision OCR —— 输出带位置与竖/横排方向的文本行
//
//  设计要点（针对真机「漏行 / 精度低」）：
//  1. **放大**：识别前把页面（或裁块）放大到目标长边 —— 字号变大后小字召回显著提升，
//     这也是「截图识字」比「直接识别页图」更准的根本原因（截屏里字号更大）。
//  2. **分块**：把整页切成带重叠的小块，每块放大得更多，密集页面召回大幅提升。
//  3. **多策略合并**：整页 / 横向压扁（规避 iOS 27 已知的「漏行」回归）/ 多语言 / 分块，
//     结果按 IoU 去重合并，取长补短。
//  4. **全程 diag() 打点**：量化每个策略命中多少行，便于定位。
//

import Foundation
import Vision
import CoreGraphics
import ImageIO
import EhModels

struct VisionTextRecognizer {

    // MARK: 配置

    /// 识别语言（BCP-47，如 "ja-JP" / "zh-Hans"）
    var languages: [String]
    /// 语言纠错。CJK 必须开启，否则可能零观测。
    var usesLanguageCorrection: Bool = true
    /// 是否分块识别（密集页面提升小字召回）
    var usesTiling: Bool = true
    /// 识别前把（裁块）放大的目标长边像素
    var targetLongSide: CGFloat = 2200
    /// 分块时每块在「原图坐标」下的目标长边
    var tileLongSide: CGFloat = 1100
    /// 分块之间的重叠比例（避免把整行文字切在块边界）
    var tileOverlap: CGFloat = 0.20
    /// 整页策略命中行数达到该值即认为「识别充分」，跳过其余策略
    var satisfiedLineCount: Int = 12

    /// 兜底用的通用多语言集合
    static let broadLanguages = ["ja-JP", "zh-Hans", "zh-Hant", "en-US"]

    /// 渲染输出的长边上限（内存保护）
    private static let renderLongSideCap: CGFloat = 4096
    /// 合并去重的 IoU 阈值
    static let mergeIoU: CGFloat = 0.4

    // MARK: 策略

    struct Strategy: Equatable {
        var label: String
        var level: VNRequestTextRecognitionLevel
        var usesLanguageCorrection: Bool
        var languages: [String]
        /// 横向压扁系数：1.0 = 不变，<1 = 压扁（iOS 27 漏行回归的规避手段）
        var squashWidth: CGFloat
    }

    // MARK: 主入口

    func recognize(
        in cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) async throws -> [MangaTextLine] {
        let pageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let pageAspect = pageSize.width / max(1, pageSize.height)
        diag("MangaTr/OCR: 原图 \(cgImage.width)x\(cgImage.height) 语言=\(languages) 分块=\(usesTiling)")

        var groups: [[MangaTextLine]] = []
        var firstError: Error?
        var sawSuccess = false

        func record(_ result: Result<[MangaTextLine], Error>, label: String) -> [MangaTextLine] {
            switch result {
            case .success(let lines):
                sawSuccess = true
                diag("MangaTr/OCR[\(label)] → 行=\(lines.count)")
                return lines
            case .failure(let error):
                if firstError == nil { firstError = error }
                diag("MangaTr/OCR[\(label)] 抛错 —— \(error)")
                return []
            }
        }

        let fullRegion = CGRect(x: 0, y: 0, width: 1, height: 1)

        // 1) 整页（含放大）
        let fullStrategy = Strategy(label: "整页", level: .accurate,
                                    usesLanguageCorrection: usesLanguageCorrection,
                                    languages: languages, squashWidth: 1.0)
        let fullLines = record(Result { try runPass(page: cgImage, region: fullRegion, strategy: fullStrategy,
                                                    pageAspect: pageAspect, orientation: orientation) },
                               label: "整页")
        groups.append(fullLines)

        if fullLines.count >= satisfiedLineCount {
            let merged = Self.merge(groups)
            diag("MangaTr/OCR: 整页已充分(\(merged.count)行)，跳过其余策略")
            return merged
        }

        // 2) 横向压扁：规避 iOS 27「整页漏行」回归
        let squashStrategy = Strategy(label: "压扁0.8", level: .accurate,
                                      usesLanguageCorrection: usesLanguageCorrection,
                                      languages: languages, squashWidth: 0.8)
        let squashed = record(Result { try runPass(page: cgImage, region: fullRegion, strategy: squashStrategy,
                                                   pageAspect: pageAspect, orientation: orientation) },
                              label: "压扁0.8")
        if !squashed.isEmpty { groups.append(squashed) }

        // 3) 指定语言识别为空时，补一次通用多语言
        if fullLines.isEmpty, languages != Self.broadLanguages {
            let multiStrategy = Strategy(label: "多语言", level: .accurate,
                                         usesLanguageCorrection: true,
                                         languages: Self.broadLanguages, squashWidth: 1.0)
            groups.append(record(Result { try runPass(page: cgImage, region: fullRegion, strategy: multiStrategy,
                                                      pageAspect: pageAspect, orientation: orientation) },
                                 label: "多语言"))
        }

        // 4) 分块
        if usesTiling {
            let tiles = Self.tileRects(pageSize: pageSize, tileLongSide: tileLongSide, overlap: tileOverlap)
            if tiles.count > 1 {
                let tileStrategy = Strategy(label: "分块", level: .accurate,
                                            usesLanguageCorrection: usesLanguageCorrection,
                                            languages: languages, squashWidth: 1.0)
                var tileLines: [MangaTextLine] = []
                for tile in tiles {
                    let region = Self.normalizedRect(tile, pageSize: pageSize)
                    tileLines.append(contentsOf: record(
                        Result { try runPass(page: cgImage, region: region, strategy: tileStrategy,
                                             pageAspect: pageAspect, orientation: orientation) },
                        label: "分块块"))
                }
                diag("MangaTr/OCR[分块] \(tiles.count)块 → 行=\(tileLines.count)")
                groups.append(tileLines)
            }
        }

        var merged = Self.merge(groups)
        diag("MangaTr/OCR: 合并去重 → 行=\(merged.count)")

        // 5) 兜底：fast
        if merged.isEmpty {
            let fastStrategy = Strategy(label: "fast兜底", level: .fast,
                                        usesLanguageCorrection: true,
                                        languages: Self.broadLanguages, squashWidth: 1.0)
            merged = record(Result { try runPass(page: cgImage, region: fullRegion, strategy: fastStrategy,
                                                 pageAspect: pageAspect, orientation: orientation) },
                            label: "fast兜底")
        }

        if merged.isEmpty, !sawSuccess, let firstError { throw firstError }
        diag("MangaTr/OCR: 最终 \(merged.count) 行 示例=\(merged.prefix(4).map(\.text))")
        return merged
    }

    // MARK: - 单次识别

    private func runPass(
        page: CGImage,
        region: CGRect,
        strategy: Strategy,
        pageAspect: CGFloat,
        orientation: CGImagePropertyOrientation
    ) throws -> [MangaTextLine] {
        guard let rendering = Self.render(page: page, region: region, targetLongSide: targetLongSide,
                                          squashWidth: strategy.squashWidth) else {
            return []
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = strategy.level
        request.recognitionLanguages = strategy.languages
        request.usesLanguageCorrection = strategy.usesLanguageCorrection

        let handler = VNImageRequestHandler(cgImage: rendering.image, orientation: orientation, options: [:])
        try handler.perform([request])
        return Self.lines(from: request.results ?? [], toPage: rendering.toPage, pageAspect: pageAspect)
    }

    // MARK: - 渲染（放大 / 压扁 / 裁块）

    private struct Rendering {
        let image: CGImage
        /// 归一化(图内, 原点左下) → 归一化(整页, 原点左下)
        let toPage: (CGRect) -> CGRect
    }

    /// 从整页里按归一化区域裁一块，放大到目标长边，可选横向压扁。
    ///
    /// 关键不变式：**归一化坐标在纯缩放/压扁下保持不变**，所以整页策略无需重映射；
    /// 只有「裁块」才需要用区域反推回整页坐标。
    private static func render(
        page: CGImage,
        region: CGRect,
        targetLongSide: CGFloat,
        squashWidth: CGFloat
    ) -> Rendering? {
        let width = CGFloat(page.width)
        let height = CGFloat(page.height)
        let regionPixelW = region.width * width
        let regionPixelH = region.height * height
        guard regionPixelW >= 1, regionPixelH >= 1 else { return nil }

        let maxSide = max(regionPixelW, regionPixelH)
        var scale = targetLongSide / maxSide
        scale = min(scale, renderLongSideCap / maxSide)
        scale = max(scale, 0.2)

        let outW = max(1, Int((regionPixelW * scale * squashWidth).rounded()))
        let outH = max(1, Int((regionPixelH * scale).rounded()))

        guard let context = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high

        let drawW = width * scale * squashWidth
        let drawH = height * scale
        context.draw(page, in: CGRect(x: -region.minX * drawW, y: -region.minY * drawH,
                                      width: drawW, height: drawH))
        guard let out = context.makeImage() else { return nil }

        let toPage: (CGRect) -> CGRect = { box in
            CGRect(x: region.minX + box.minX * region.width,
                   y: region.minY + box.minY * region.height,
                   width: box.width * region.width,
                   height: box.height * region.height)
        }
        return Rendering(image: out, toPage: toPage)
    }

    // MARK: - 观测 → 文本行

    static func lines(
        from observations: [VNRecognizedTextObservation],
        toPage: (CGRect) -> CGRect,
        pageAspect: CGFloat
    ) -> [MangaTextLine] {
        var lines: [MangaTextLine] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = toPage(observation.boundingBox)   // 归一化，原点左下
            guard box.width > 0, box.height > 0 else { continue }
            let vertical = isVertical(box: box, text: text, pageAspect: pageAspect)
            lines.append(MangaTextLine(text: text, boundingBox: box, isVertical: vertical,
                                       confidence: candidate.confidence))
        }
        return lines
    }

    /// 判定竖排：把归一化包围盒换算成**像素纵横比**再比较（页面非正方时修正）。
    /// 单字符无法判断方向，按横排处理。
    static func isVertical(box: CGRect, text: String, pageAspect: CGFloat = 1) -> Bool {
        guard box.width > 0, box.height > 0, text.count > 1 else { return false }
        // 像素高/宽 = (box.height/box.width) / pageAspect，其中 pageAspect = W/H
        return box.height > box.width * 1.6 * max(0.05, pageAspect)
    }

    // MARK: - 分块 / 合并（纯逻辑，可单测）

    /// 把整页切成带重叠、均匀铺满的方块（像素坐标，原点左下）
    static func tileRects(pageSize: CGSize, tileLongSide: CGFloat, overlap: CGFloat) -> [CGRect] {
        let width = Int(pageSize.width.rounded())
        let height = Int(pageSize.height.rounded())
        guard width > 0, height > 0, tileLongSide > 0 else { return [] }

        let cols = max(1, Int(ceil(Double(width) / Double(tileLongSide))))
        let rows = max(1, Int(ceil(Double(height) / Double(tileLongSide))))
        if cols * rows <= 1 { return [CGRect(x: 0, y: 0, width: width, height: height)] }

        let overlap = min(max(overlap, 0), 0.6)
        let tileW = min(width, Int(ceil(Double(width) / Double(cols) * (1 + overlap))))
        let tileH = min(height, Int(ceil(Double(height) / Double(rows) * (1 + overlap))))

        func origin(_ index: Int, count: Int, tile: Int, total: Int) -> Int {
            guard count > 1 else { return 0 }
            return Int((Double(total - tile) * Double(index) / Double(count - 1)).rounded())
        }

        var rects: [CGRect] = []
        for row in 0..<rows {
            for col in 0..<cols {
                rects.append(CGRect(
                    x: origin(col, count: cols, tile: tileW, total: width),
                    y: origin(row, count: rows, tile: tileH, total: height),
                    width: tileW, height: tileH
                ))
            }
        }
        return rects
    }

    static func normalizedRect(_ rect: CGRect, pageSize: CGSize) -> CGRect {
        guard pageSize.width > 0, pageSize.height > 0 else { return rect }
        return CGRect(x: rect.minX / pageSize.width, y: rect.minY / pageSize.height,
                      width: rect.width / pageSize.width, height: rect.height / pageSize.height)
    }

    /// 合并多策略结果：IoU 超阈值视为同一行，保留置信度更高 / 更长的那条
    static func merge(_ groups: [[MangaTextLine]]) -> [MangaTextLine] {
        var result: [MangaTextLine] = []
        for line in groups.flatMap({ $0 }) {
            if let index = result.firstIndex(where: { iou($0.boundingBox, line.boundingBox) >= mergeIoU }) {
                let existing = result[index]
                let better = line.confidence > existing.confidence
                    || (line.confidence == existing.confidence && line.text.count > existing.text.count)
                if better { result[index] = line }
            } else {
                result.append(line)
            }
        }
        return result
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        return union > 0 ? interArea / union : 0
    }
}
