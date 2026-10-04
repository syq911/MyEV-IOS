//
//  MangaTranslationTests.swift
//  ehviewer appleTests
//
//  漫画翻译的纯逻辑回归：竖排判定、竖排布局、坐标映射、译文 JSON 解析
//

import Testing
import Foundation
import CoreGraphics
import CoreText
import Vision
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import ehviewer_apple

struct MangaTranslationTests {

    // MARK: OCR 配置（纯逻辑）

    @Test func plannedAttemptsCoverFallbacks() {
        let attempts = VisionTextRecognizer.plannedAttempts(languages: ["ja-JP"])
        // 至少包含：指定语言 + 通用多语言 + fast 兜底
        #expect(attempts.count >= 2)
        // 每次尝试都必须开启语言纠错（CJK 关闭纠错会零观测）
        #expect(attempts.allSatisfy { $0.usesLanguageCorrection })
        #expect(attempts.first?.languages == ["ja-JP"])
        #expect(attempts.contains { $0.recognitionLevel == .fast })
    }

    @Test func plannedAttemptsDeduplicatesBroadLanguages() {
        let attempts = VisionTextRecognizer.plannedAttempts(languages: VisionTextRecognizer.broadLanguages)
        // 已经是通用集合时不再重复追加 identical 配置
        let accurateBroad = attempts.filter {
            $0.recognitionLevel == .accurate && $0.languages == VisionTextRecognizer.broadLanguages
        }
        #expect(accurateBroad.count == 1)
    }

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

    // MARK: 竖排布局

    @Test func verticalLayoutFitsWidth() {
        let layout = MangaTypesetter.verticalLayout(
            charCount: 20, boxSize: CGSize(width: 100, height: 200), scale: 1.0)
        #expect(layout.columns >= 1)
        #expect(layout.charsPerColumn >= 1)
        // 列数 × 字号 必须能塞进框宽（留 2% 容差）
        #expect(CGFloat(layout.columns) * layout.fontSize <= 102)
        // 每列字符数 × 列数 至少覆盖全部字符
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

    // MARK: 译文 JSON 解析

    @Test func parseTranslationsPlain() throws {
        let out = try DeepSeekTranslator.parseTranslations("[\"你好\",\"世界\"]", expected: 2)
        #expect(out == ["你好", "世界"])
    }

    @Test func parseTranslationsWithCodeFence() throws {
        let text = "```json\n[\"a\",\"b\"]\n```"
        let out = try DeepSeekTranslator.parseTranslations(text, expected: 2)
        #expect(out == ["a", "b"])
    }

    @Test func parseTranslationsWithPreamble() throws {
        let text = "好的，结果如下：\n[\"一\",\"二\",\"三\"]"
        let out = try DeepSeekTranslator.parseTranslations(text, expected: 3)
        #expect(out == ["一", "二", "三"])
    }

    @Test func parseTranslationsCountMismatch() {
        #expect(throws: MangaTranslationError.self) {
            _ = try DeepSeekTranslator.parseTranslations("[\"a\"]", expected: 2)
        }
    }

    @Test func parseTranslationsEmpty() {
        #expect(throws: MangaTranslationError.self) {
            _ = try DeepSeekTranslator.parseTranslations("no array here", expected: 1)
        }
    }

    // MARK: 真实 Vision OCR 回归（覆盖历史「识别不到文字」）

    /// 真机/模拟器上跑真实 Vision：横排英文
    @Test func ocrRecognizesRenderedEnglish() async throws {
        let image = try #require(makeTextImage("HELLO WORLD"))
        let cgImage = try #require(MangaTypesetter.cgImage(of: image))
        let lines = try await VisionTextRecognizer(languages: ["en-US"]).recognize(in: cgImage)
        #expect(!lines.isEmpty)
    }

    /// 真机/模拟器上跑真实 Vision：竖排日语（历史 bug 就在这里——关闭纠错会零观测）
    @Test func ocrRecognizesRenderedJapanese() async throws {
        let image = try #require(makeTextImage("こんにちは"))
        let cgImage = try #require(MangaTypesetter.cgImage(of: image))
        let lines = try await VisionTextRecognizer(languages: ["ja-JP"]).recognize(in: cgImage)
        #expect(!lines.isEmpty)
    }

    // MARK: 测试辅助

    /// 把一段文字渲染成白底黑字的位图，供真实 OCR 用例使用
    private func makeTextImage(_ text: String, fontSize: CGFloat = 120) -> PlatformImage? {
        let width = 1000
        let height = 320
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // 用 CoreText 选取「能渲染该字符串」的回退字体（日文会回退到 Hiragino 等）
        let baseFont = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let font = CTFontCreateForString(baseFont, text as CFString, CFRangeMake(0, text.utf16.count))
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.textPosition = CGPoint(
            x: (CGFloat(width) - bounds.width) / 2,
            y: (CGFloat(height) - bounds.height) / 2
        )
        CTLineDraw(line, ctx)

        guard let cgImage = ctx.makeImage() else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        #endif
    }
}
