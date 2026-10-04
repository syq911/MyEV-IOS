//
//  MangaTranslationTests.swift
//  ehviewer appleTests
//
//  漫画翻译的纯逻辑回归：竖排判定、竖排布局、坐标映射、译文 JSON 解析
//

import Testing
import Foundation
import CoreGraphics
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
}
