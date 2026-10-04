//
//  MangaTranslationTests.swift
//  ehviewer appleTests
//
//  漫画翻译回归测试：
//  - 纯逻辑：竖排判定（含页面纵横比修正）、竖排布局、坐标映射、合并去重、译文 JSON 解析
//  - 真实 Vision：合成密集页面召回
//  - **金标准（golden）**：对 `Tests/Fixtures/ocr_fixture_page.jpg` 做 OCR，
//    与 `Tests/Fixtures/ocr_fixture_expected.txt`（用户用快捷指令截图识别的正确结果）比对。
//

import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import ehviewer_apple

struct MangaTranslationTests {

    // MARK: 竖排判定

    @Test func verticalDetection() {
        // 高窄框 + 多字符 → 竖排
        #expect(VisionTextRecognizer.isVertical(
            box: CGRect(x: 0, y: 0, width: 0.05, height: 0.30), text: "こんにちは"))
        // 宽扁框 → 横排
        #expect(!VisionTextRecognizer.isVertical(
            box: CGRect(x: 0, y: 0, width: 0.30, height: 0.05), text: "Hello"))
        // 单字符无法判断方向 → 按横排
        #expect(!VisionTextRecognizer.isVertical(
            box: CGRect(x: 0, y: 0, width: 0.05, height: 0.30), text: "あ"))
    }

    @Test func verticalDetectionUsesPageAspect() {
        // 归一化盒子在方页下接近正方；但竖长页（W/H=0.5）实际像素更高 → 应判为竖排
        let box = CGRect(x: 0, y: 0, width: 0.10, height: 0.09)
        #expect(VisionTextRecognizer.isVertical(box: box, text: "かな", pageAspect: 0.5))
        #expect(!VisionTextRecognizer.isVertical(box: box, text: "かな", pageAspect: 1.0))
    }

    // MARK: 竖排布局

    @Test func verticalLayoutFitsWidth() {
        let layout = MangaTypesetter.verticalLayout(
            charCount: 20, boxSize: CGSize(width: 100, height: 200), scale: 1.0)
        #expect(layout.columns >= 1)
        #expect(layout.charsPerColumn >= 1)
        #expect(CGFloat(layout.columns) * layout.fontSize <= 102)
        #expect(layout.charsPerColumn * layout.columns >= 20)
    }

    @Test func verticalLayoutNeverBelowMinFont() {
        let layout = MangaTypesetter.verticalLayout(
            charCount: 500, boxSize: CGSize(width: 20, height: 20), scale: 1.0)
        #expect(layout.fontSize >= 9)
    }

    // MARK: 坐标映射（归一化原点左下 → 像素原点左下）

    @Test func pixelRectMapping() {
        let rect = MangaTypesetter.pixelRect(
            from: CGRect(x: 0.25, y: 0.50, width: 0.50, height: 0.25),
            pageSize: CGSize(width: 400, height: 800))
        #expect(rect.minX == 100)
        #expect(rect.minY == 400)
        #expect(rect.width == 200)
        #expect(rect.height == 200)
    }

    // MARK: 合并去重（纯逻辑）

    @Test func mergeDeduplicatesOverlappingLines() {
        let box = CGRect(x: 0.10, y: 0.10, width: 0.20, height: 0.05)
        let low = MangaTextLine(text: "こんにちは", boundingBox: box, isVertical: false, confidence: 0.5)
        let high = MangaTextLine(text: "こんにちは。", boundingBox: box.offsetBy(dx: 0.004, dy: 0.003),
                                 isVertical: false, confidence: 0.9)
        let other = MangaTextLine(text: "さようなら",
                                  boundingBox: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.05),
                                  isVertical: false, confidence: 0.8)
        let merged = VisionTextRecognizer.merge([[low, other], [high]])
        #expect(merged.count == 2)
        #expect(merged.contains { $0.text == "こんにちは。" })   // 置信度高者胜
        #expect(merged.contains { $0.text == "さようなら" })
    }

    @Test func iouOfIdenticalBoxesIsOne() {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        #expect(abs(VisionTextRecognizer.iou(box, box) - 1) < 0.001)
        #expect(VisionTextRecognizer.iou(box, CGRect(x: 0.9, y: 0.9, width: 0.05, height: 0.05)) == 0)
    }

    // MARK: 译文 JSON 解析

    @Test func parseTranslationsPlain() throws {
        let out = try DeepSeekTranslator.parseTranslations("[\"你好\",\"世界\"]", expected: 2)
        #expect(out == ["你好", "世界"])
    }

    @Test func parseTranslationsWithCodeFence() throws {
        let out = try DeepSeekTranslator.parseTranslations("```json\n[\"a\",\"b\"]\n```", expected: 2)
        #expect(out == ["a", "b"])
    }

    @Test func parseTranslationsCountMismatch() {
        #expect(throws: MangaTranslationError.self) {
            _ = try DeepSeekTranslator.parseTranslations("[\"a\"]", expected: 2)
        }
    }

    // MARK: 金标准：真实页图 OCR 必须匹配「快捷指令截图识字」的正确结果

    /// 用程序对金标准图片做 OCR，与基准文本比对。
    /// 基准文本 = 用户用系统「快捷指令 → 从图像中提取文本」得到的正确结果。
    /// 不允许人工看图；完全由程序判定，相似度不达标即失败。
    @Test func ocrMatchesGoldenFixture() async throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ehviewer appleTests
            .deletingLastPathComponent()   // ehviewer apple
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Tests/Fixtures")

        let imageURL = fixtures.appendingPathComponent("ocr_fixture_page.jpg")
        let expectedURL = fixtures.appendingPathComponent("ocr_fixture_expected.txt")

        let expected = try String(contentsOf: expectedURL, encoding: .utf8)
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("无法加载金标准测试图片：\(imageURL.path)")
            return
        }

        let lines = try await VisionTextRecognizer(languages: ["ja-JP"]).recognize(in: cgImage)
        let ocr = lines.map(\.text).joined(separator: "\n")

        let ratio = Self.lcsRecall(reference: expected, hypothesis: ocr)
        // 至少识别出多行，且与基准文本的字符召回率达标
        #expect(lines.count >= 3, "识别行数过少（\(lines.count)）。OCR=\(ocr)")
        #expect(ratio >= 0.60, "与基准文本字符召回率过低（\(String(format: "%.3f", ratio))）。OCR=\(ocr)")
    }

    // MARK: 真实 Vision OCR 召回（合成密集页面）

    /// 多行密集页面：整页有 6 句分散的对白，断言至少识别出 5 句。
    @Test func ocrRecoversMostLinesOnDensePage() async throws {
        let page = try #require(makeDensePage())
        let cgImage = try #require(MangaTypesetter.cgImage(of: page))
        let lines = try await VisionTextRecognizer(languages: ["ja-JP"]).recognize(in: cgImage)

        let joined = lines.map(\.text).joined().replacingOccurrences(of: " ", with: "")
        let phrases = ["おはよう", "天気", "待って", "ありがとう", "そうなん", "どこに"]
        let hits = phrases.filter { joined.contains($0) }.count
        #expect(hits >= 5, "仅召回 \(hits)/6 句；识别文本=\(joined)")
    }

    /// 竖排页面：合成竖排图在不同系统/模拟器上的可识别性不一，
    /// 因此这里只在「识别到内容」时强制校验方向判定。
    @Test func ocrVerticalPageClassifiesDirectionWhenRecognized() async throws {
        let page = try #require(makeVerticalPage())
        let cgImage = try #require(MangaTypesetter.cgImage(of: page))
        let lines = try await VisionTextRecognizer(languages: ["ja-JP"]).recognize(in: cgImage)
        for line in lines where line.text.count > 1 {
            #expect(line.isVertical, "竖排被误判为横排：\(line.text)")
        }
    }

    // MARK: 比对工具

    /// 归一化：只保留字母/数字（含 CJK、假名），去掉空白与标点
    static func normalized(_ text: String) -> [Character] {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// 以基准文本为参照的字符召回率 = LCS(基准, 识别) / len(基准)
    static func lcsRecall(reference: String, hypothesis: String) -> Double {
        let a = normalized(reference)
        let b = normalized(hypothesis)
        guard !a.isEmpty else { return 0 }
        guard !b.isEmpty else { return 0 }

        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for i in 1...a.count {
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            previous = current
        }
        return Double(previous[b.count]) / Double(a.count)
    }

    // MARK: 测试辅助 —— 页面渲染

    private func makePage(size: CGSize, draw: (CGContext, CGSize) -> Void) -> PlatformImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.textMatrix = .identity
        draw(ctx, size)
        guard let cgImage = ctx.makeImage() else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        #endif
    }

    /// 在 (x, y)（左上角起点，y 向下）绘制一段文字，可选竖排
    private func drawText(
        _ text: String,
        _ ctx: CGContext,
        x: CGFloat,
        y: CGFloat,
        fontSize: CGFloat,
        vertical: Bool,
        pageHeight: CGFloat
    ) {
        let baseFont = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let font = CTFontCreateForString(baseFont, text as CFString, CFRangeMake(0, text.utf16.count))
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]

        if vertical {
            var cursorY = pageHeight - y
            for character in text {
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: String(character), attributes: attributes))
                let bounds = CTLineGetBoundsWithOptions(line, [])
                ctx.textPosition = CGPoint(x: x, y: cursorY - bounds.height)
                CTLineDraw(line, ctx)
                cursorY -= fontSize * 1.12
            }
        } else {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, [])
            ctx.textPosition = CGPoint(x: x, y: pageHeight - y - bounds.height)
            CTLineDraw(line, ctx)
        }
    }

    private func makeDensePage() -> PlatformImage? {
        makePage(size: CGSize(width: 1248, height: 1824)) { ctx, size in
            drawText("おはようございます", ctx, x: 90, y: 220, fontSize: 46, vertical: false, pageHeight: size.height)
            drawText("今日はいい天気ですね", ctx, x: 140, y: 540, fontSize: 42, vertical: false, pageHeight: size.height)
            drawText("ちょっと待ってください", ctx, x: 700, y: 860, fontSize: 38, vertical: false, pageHeight: size.height)
            drawText("ありがとうございました", ctx, x: 160, y: 1180, fontSize: 44, vertical: false, pageHeight: size.height)
            drawText("そうなんだ", ctx, x: 660, y: 1480, fontSize: 46, vertical: false, pageHeight: size.height)
            drawText("どこに行くの", ctx, x: 220, y: 1700, fontSize: 42, vertical: false, pageHeight: size.height)
        }
    }

    private func makeVerticalPage() -> PlatformImage? {
        makePage(size: CGSize(width: 500, height: 1500)) { ctx, size in
            drawText("こんにちはありがとうございます", ctx, x: 340, y: 80, fontSize: 52, vertical: true, pageHeight: size.height)
            drawText("よろしくおねがいします", ctx, x: 150, y: 420, fontSize: 50, vertical: true, pageHeight: size.height)
        }
    }
}
