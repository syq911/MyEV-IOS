//
//  MangaTypesetter.swift
//  ehviewer apple
//
//  排版合成 —— 在原图文字框上盖底色框（改进的"擦字"），再把译文按方向/字号排回去。
//
//  改进点（相对早期版本）：
//   1. **盖字更干净**：底色改为「外圈稳健采样（去离群）」；覆盖框会按方向外扩，
//      但外扩量会自动缩小以避免盖住相邻文字框；边缘加一圈同色羽化，减轻"贴块感"。
//   2. **字号可控**：横排/竖排都设了「可读最小字号」下限，并用二分法快速收敛到能放下的字号；
//      若在最小字号仍放不下，则**截断并加省略号**（宁可少显示，也不超出框去盖住别的文字）。
//

import Foundation
import CoreGraphics
import CoreText
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum MangaTypesetter {

    struct Options {
        /// 盖框底色：true=取样原文框周边底色；false=纯白
        var useSampledBackground: Bool = true
        /// 是否额外标注一行小号原文
        var showOriginalText: Bool = false
        /// 字号缩放 0.6~1.4
        var fontScale: CGFloat = 1.0
    }

    /// 把译文渲染回原图，返回带译文的整页图（失败时返回原图）
    static func render(original: PlatformImage, lines: [MangaTranslatedLine], options: Options) -> PlatformImage {
        guard !lines.isEmpty, let sourceCG = cgImage(of: original) else { return original }
        let width = sourceCG.width
        let height = sourceCG.height
        guard width > 0, height > 0 else { return original }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return original }

        // 先画原图（CGContext 原点左下，与原图位图一致）
        ctx.draw(sourceCG, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        let pageSize = CGSize(width: width, height: height)
        let pageRect = CGRect(origin: .zero, size: pageSize)
        let pageShortSide = min(CGFloat(width), CGFloat(height))

        // 一次性把每条译文的像素框算出来，供「互相避让」使用
        let boxes = lines.map { pixelRect(from: $0.boundingBox, pageSize: pageSize) }

        for (index, line) in lines.enumerated() {
            draw(line: line, index: index, allBoxes: boxes, in: ctx,
                 pageRect: pageRect, pageShortSide: pageShortSide,
                 sourceCG: sourceCG, options: options)
        }

        guard let outCG = ctx.makeImage() else { return original }
        return makeImage(outCG, size: original.size)
    }

    // MARK: - 单条渲染

    private static func draw(
        line: MangaTranslatedLine,
        index: Int,
        allBoxes: [CGRect],
        in ctx: CGContext,
        pageRect: CGRect,
        pageShortSide: CGFloat,
        sourceCG: CGImage,
        options: Options
    ) {
        let box = allBoxes[index]
        guard box.width > 2, box.height > 2 else { return }

        // 覆盖框：从 box 外扩，但外扩量会缩小以避免侵入相邻文字框
        let neighbors = allBoxes.enumerated().filter { $0.offset != index }.map { $0.element }
        let fill = coverRect(box: box, neighbors: neighbors, pageRect: pageRect)

        // 底色（稳健采样，去离群）
        let background: CGColor = options.useSampledBackground
            ? sampledBackground(cgImage: sourceCG, box: box)
            : white

        // 先画一圈同色羽化外圈，再压实心矩形 —— 减轻硬边贴块感
        let feathered = background.copy(alpha: 0.40) ?? background
        fillPath(ctx, rect: fill.insetBy(dx: -2, dy: -2), color: feathered, pageRect: pageRect)
        fillPath(ctx, rect: fill, color: background, pageRect: pageRect)

        // 文字颜色跟随底色明暗
        let textColor = luminance(of: background) > 0.6 ? black : white
        let scale = max(0.3, min(1.5, options.fontScale))
        let minFont = minReadableFont(box: fill, pageShortSide: pageShortSide)

        if line.isVertical {
            drawVertical(text: line.translated, in: ctx, box: fill, color: textColor, scale: scale, minFont: minFont)
        } else {
            drawHorizontal(text: line.translated, in: ctx, box: fill, color: textColor, scale: scale, minFont: minFont)
        }

        if options.showOriginalText, !line.source.isEmpty {
            drawOriginalAnnotation(text: line.source, in: ctx, box: fill, color: textColor, scale: scale)
        }
    }

    /// 覆盖矩形：box 外扩 pad（按尺寸比例），若侵入相邻框则逐步缩小外扩量（最低回到 box 本身）
    static func coverRect(box: CGRect, neighbors: [CGRect], pageRect: CGRect) -> CGRect {
        let padX = max(2, box.width * 0.10)
        let padY = max(2, box.height * 0.10)
        var factor: CGFloat = 1.0
        var result = box.insetBy(dx: -padX, dy: -padY).intersection(pageRect)
        while factor > 0.06, neighbors.contains(where: { $0.intersects(result) }) {
            factor *= 0.5
            result = box.insetBy(dx: -padX * factor, dy: -padY * factor).intersection(pageRect)
        }
        return result
    }

    /// 用给定颜色填充矩形（clip 掉页面外）
    private static func fillPath(_ ctx: CGContext, rect: CGRect, color: CGColor, pageRect: CGRect) {
        let clipped = rect.intersection(pageRect)
        guard clipped.width > 0, clipped.height > 0 else { return }
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.fill(clipped)
        ctx.restoreGState()
    }

    // MARK: - 横排（自动换行 + 字号自适应 + 截断 + 垂直居中）

    private static func drawHorizontal(text: String, in ctx: CGContext, box: CGRect, color: CGColor, scale: CGFloat, minFont: CGFloat) {
        guard !text.isEmpty else { return }
        let startFont = horizontalInitialFontSize(boxHeight: box.height, scale: scale)
        let fontSize = fitFontSize(text: text, box: box, startFont: startFont, minFont: minFont)
        let lines = wrapTruncated(text: text, fontSize: fontSize, color: color,
                                  maxWidth: box.width, maxHeight: box.height)
        guard !lines.isEmpty else { return }

        let lh = lineHeight(of: attributedString("测Ag", fontSize: fontSize, color: color))
        let blockHeight = CGFloat(lines.count) * lh
        var baseline = box.midY + blockHeight / 2 - lh + (lh * 0.25)
        for line in lines {
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let x = box.midX - lineWidth / 2
            ctx.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, ctx)
            baseline -= lh
        }
    }

    // MARK: - 竖排（逐字竖排，必要时分列，从右往左）

    private static func drawVertical(text: String, in ctx: CGContext, box: CGRect, color: CGColor, scale: CGFloat, minFont: CGFloat) {
        let fit = fitVertical(text: text, box: box, scale: scale, minFont: minFont)
        guard !fit.characters.isEmpty else { return }
        let fontSize = fit.fontSize
        let lineHeight = fontSize * 1.06
        let columnWidth = box.width / CGFloat(max(1, fit.columns))

        // 从右往左排各列
        for column in 0..<fit.columns {
            let start = column * fit.charsPerColumn
            let end = min(start + fit.charsPerColumn, fit.characters.count)
            guard start < end else { break }
            let columnChars = Array(fit.characters[start..<end])

            let columnCenterX = box.maxX - (CGFloat(column) + 0.5) * columnWidth
            let columnHeight = CGFloat(columnChars.count) * lineHeight
            var top = box.midY + columnHeight / 2
            for ch in columnChars {
                let line = CTLineCreateWithAttributedString(attributedString(ch, fontSize: fontSize, color: color))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let baseline = top - lineHeight + lineHeight * 0.2
                ctx.textPosition = CGPoint(x: columnCenterX - width / 2, y: baseline)
                CTLineDraw(line, ctx)
                top -= lineHeight
            }
        }
    }

    // MARK: - 原文小注（可选）

    private static func drawOriginalAnnotation(text: String, in ctx: CGContext, box: CGRect, color: CGColor, scale: CGFloat) {
        let fontSize = max(7, box.height * 0.12 * scale)
        let attr = attributedString(text, fontSize: fontSize, color: color.copy(alpha: 0.55) ?? color)
        let line = CTLineCreateWithAttributedString(attr)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard width <= box.width else { return }   // 放不下就不画，避免超出框
        ctx.textPosition = CGPoint(x: box.midX - width / 2, y: box.minY + 2)
        CTLineDraw(line, ctx)
    }

    // MARK: - 字号 / 折行（纯逻辑，可单测）

    /// 可读最小字号：随页面短边与框尺寸给一个下限，避免译文小到看不清
    static func minReadableFont(box: CGRect, pageShortSide: CGFloat) -> CGFloat {
        let relative = pageShortSide * 0.020
        return max(10, min(min(box.width, box.height) * 0.9, relative))
    }

    /// 在 box 内为 text 选一个合适字号：不超过 startFont、不低于 minFont（二分收敛）
    static func fitFontSize(text: String, box: CGRect, startFont: CGFloat, minFont: CGFloat) -> CGFloat {
        guard !text.isEmpty, box.width > 1, box.height > 1 else { return max(8, minFont) }
        let hi = max(minFont, startFont)
        if fits(text: text, fontSize: hi, box: box) { return hi }
        if !fits(text: text, fontSize: minFont, box: box) { return minFont }   // 放不下 → 交给截断
        var lo = minFont
        var high = hi
        for _ in 0..<18 {
            let mid = (lo + high) / 2
            if fits(text: text, fontSize: mid, box: box) { lo = mid } else { high = mid }
        }
        return lo
    }

    /// 该字号下（折行后）能否放进 box
    static func fits(text: String, fontSize: CGFloat, box: CGRect) -> Bool {
        guard fontSize > 0, box.width > 1, box.height > 1 else { return false }
        let attr = attributedString(text, fontSize: fontSize, color: black)
        let lines = wrap(attr, width: box.width)
        let lh = lineHeight(of: attributedString("测Ag", fontSize: fontSize, color: black))
        guard lh > 0 else { return false }
        if CGFloat(lines.count) * lh > box.height + 0.5 { return false }
        return !totalWidthOverflow(lines, maxWidth: box.width + 0.5)
    }

    /// 折行；若在给定字号下放不下，则截断并加省略号，保证 行数 * 行高 <= maxHeight
    static func wrapTruncated(text: String, fontSize: CGFloat, color: CGColor, maxWidth: CGFloat, maxHeight: CGFloat) -> [CTLine] {
        let fitted = truncatedText(text: text, fontSize: fontSize, maxWidth: maxWidth, maxHeight: maxHeight)
        var lines = wrap(attributedString(fitted, fontSize: fontSize, color: color), width: maxWidth)
        if lines.isEmpty {
            lines = [CTLineCreateWithAttributedString(attributedString(fitted, fontSize: fontSize, color: color))]
        }
        return lines
    }

    /// 若在该字号下超出框高，返回截断后的文本（末尾省略号）；否则原样返回。
    /// 纯逻辑，便于单测。
    static func truncatedText(text: String, fontSize: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat) -> String {
        guard fontSize > 0, maxWidth > 1, maxHeight > 1 else { return text }
        let lines = wrap(attributedString(text, fontSize: fontSize, color: black), width: maxWidth)
        let lh = lineHeight(of: attributedString("测Ag", fontSize: fontSize, color: black))
        guard lh > 0, !lines.isEmpty else { return text }
        let maxLines = max(1, Int((maxHeight / lh).rounded(.down)))
        guard lines.count > maxLines else { return text }

        let last = lines[maxLines - 1]
        let range = CTLineGetStringRange(last)
        let ns = text as NSString
        let keep = max(1, min(ns.length, range.location + range.length) - 1)
        return ns.substring(to: keep) + "…"
    }

    /// 竖排布局结果（含可能的截断）
    struct VerticalFit: Equatable {
        let fontSize: CGFloat
        let charsPerColumn: Int
        let columns: Int
        let characters: [String]
    }

    /// 竖排：先按框尺寸算布局，再抬到可读最小字号；若因此放不下则截断字符并加省略号
    static func fitVertical(text: String, box: CGRect, scale: CGFloat, minFont: CGFloat) -> VerticalFit {
        let all = Array(text).map { String($0) }
        guard !all.isEmpty, box.width > 1, box.height > 1 else {
            return VerticalFit(fontSize: max(8, minFont), charsPerColumn: 1, columns: 1, characters: all)
        }
        let layout = verticalLayout(charCount: all.count, boxSize: box.size, scale: scale)
        let fontSize = max(minFont, layout.fontSize)
        let spacing = fontSize * 1.06
        let charsPerColumn = max(1, Int((box.height / spacing).rounded(.down)))
        let maxColumns = max(1, Int((box.width / (fontSize * 1.02)).rounded(.down)))

        var characters = all
        var columns = Int((Double(characters.count) / Double(charsPerColumn)).rounded(.up))
        if columns > maxColumns {
            let capacity = maxColumns * charsPerColumn
            let keep = max(1, capacity - 1)
            characters = Array(all.prefix(keep)) + ["…"]
            columns = Int((Double(characters.count) / Double(charsPerColumn)).rounded(.up))
        }
        return VerticalFit(fontSize: fontSize, charsPerColumn: charsPerColumn, columns: columns, characters: characters)
    }

    /// 竖排布局：尽量让字号贴合框宽，列数不超过能塞进框宽的列数（兜底最小 9）
    static func verticalLayout(charCount: Int, boxSize: CGSize, scale: CGFloat) -> (fontSize: CGFloat, charsPerColumn: Int, columns: Int) {
        guard charCount > 0, boxSize.width > 0, boxSize.height > 0 else {
            return (12, max(1, charCount), 1)
        }
        var fontSize = min(boxSize.width, boxSize.height) * scale
        fontSize = max(9, min(fontSize, 200))

        var charsPerColumn = 1
        var columns = 1
        for _ in 0..<12 {
            charsPerColumn = max(1, Int(floor(boxSize.height / (fontSize * 1.06))))
            columns = Int(ceil(Double(charCount) / Double(charsPerColumn)))
            let neededWidth = CGFloat(columns) * fontSize * 1.02
            if neededWidth <= boxSize.width || fontSize <= 9 { break }
            // 需要更多列 → 缩小字号
            fontSize = max(9, fontSize * (boxSize.width / neededWidth))
        }
        return (fontSize, max(1, charsPerColumn), max(1, columns))
    }

    /// 横排初始字号（后续再按实际换行收缩）
    static func horizontalInitialFontSize(boxHeight: CGFloat, scale: CGFloat) -> CGFloat {
        max(8, boxHeight * scale)
    }

    // MARK: - 颜色采样

    /// 取文字框「外圈」的稳健平均色作为底色 —— 在均值基础上剔除离群像素，
    /// 避免取到文字笔画/描边而把底色算脏。
    private static func sampledBackground(cgImage: CGImage, box: CGRect) -> CGColor {
        let ring: CGFloat = 3
        let outer = box.insetBy(dx: -ring, dy: -ring).intersection(
            CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        )
        guard outer.width > 2, outer.height > 2 else { return white }

        let side = 32
        let edge = 6          // 采样外圈宽度（像素）
        let bytesPerRow = side * 4
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        // 1) 收集外圈像素
        var samples: [(Double, Double, Double)] = []
        samples.reserveCapacity(side * edge * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let small = CGContext(
                    data: base, width: side, height: side,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: colorSpace, bitmapInfo: bitmapInfo
                  ) else { return }

            small.interpolationQuality = .high
            small.draw(cgImage, in: CGRect(
                x: -outer.minX * CGFloat(side) / outer.width,
                y: -outer.minY * CGFloat(side) / outer.height,
                width: CGFloat(cgImage.width) * CGFloat(side) / outer.width,
                height: CGFloat(cgImage.height) * CGFloat(side) / outer.height
            ))

            let pixels = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<side {
                for x in 0..<side {
                    guard x < edge || y < edge || x >= side - edge || y >= side - edge else { continue }
                    let idx = (y * side + x) * 4
                    samples.append((Double(pixels[idx]) / 255.0,
                                    Double(pixels[idx + 1]) / 255.0,
                                    Double(pixels[idx + 2]) / 255.0))
                }
            }
        }
        guard !samples.isEmpty else { return white }

        // 2) 均值 → 剔除离群 → 再均值
        let m0 = mean(samples)
        let threshold = 0.22
        let inliers = samples.filter {
            let d = abs($0.0 - m0.0) + abs($0.1 - m0.1) + abs($0.2 - m0.2)
            return d < threshold * 3
        }
        let final = mean(inliers.isEmpty ? samples : inliers)
        return CGColor(red: final.0, green: final.1, blue: final.2, alpha: 1)
    }

    private static func mean(_ values: [(Double, Double, Double)]) -> (Double, Double, Double) {
        guard !values.isEmpty else { return (1, 1, 1) }
        var r = 0.0, g = 0.0, b = 0.0
        for v in values { r += v.0; g += v.1; b += v.2 }
        let n = Double(values.count)
        return (r / n, g / n, b / n)
    }

    // MARK: - 工具

    private static let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    private static let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

    static func pixelRect(from normalized: CGRect, pageSize: CGSize) -> CGRect {
        // 归一化原点左下 → 像素原点左下，直接对应
        CGRect(
            x: normalized.minX * pageSize.width,
            y: normalized.minY * pageSize.height,
            width: normalized.width * pageSize.width,
            height: normalized.height * pageSize.height
        )
    }

    private static func luminance(of color: CGColor) -> CGFloat {
        let comps = color.components ?? [1, 1, 1, 1]
        guard comps.count >= 3 else { return 1 }
        return 0.299 * comps[0] + 0.587 * comps[1] + 0.114 * comps[2]
    }

    private static func attributedString(_ text: String, fontSize: CGFloat, color: CGColor) -> NSAttributedString {
        let font = systemCTFont(size: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color,
        ]
        return NSAttributedString(string: text, attributes: attrs)
    }

    private static func systemCTFont(size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private static func lineHeight(of attributed: NSAttributedString) -> CGFloat {
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return ascent + descent + leading
    }

    private static func totalWidthOverflow(_ lines: [CTLine], maxWidth: CGFloat) -> Bool {
        for line in lines {
            if CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maxWidth { return true }
        }
        return false
    }

    /// 用 CTTypesetter 做断行
    private static func wrap(_ attributed: NSAttributedString, width: CGFloat) -> [CTLine] {
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length
        var lines: [CTLine] = []
        var start = 0
        while start < length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            if count <= 0 { break }
            let line = CTTypesetterCreateLine(typesetter, CFRangeMake(start, count))
            lines.append(line)
            start += count
        }
        if lines.isEmpty { lines = [CTLineCreateWithAttributedString(attributed)] }
        return lines
    }

    // MARK: - 平台桥接

    static func cgImage(of image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        return image.cgImage
        #else
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
    }

    private static func makeImage(_ cgImage: CGImage, size: CGSize) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: size)
        #endif
    }
}
