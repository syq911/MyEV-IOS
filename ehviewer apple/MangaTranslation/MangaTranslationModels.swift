//
//  MangaTranslationModels.swift
//  ehviewer apple
//
//  漫画页内翻译 —— 数据模型
//
//  流程: 页图 → Vision OCR(含位置/方向) → 翻译 → 排版合成 → 翻译后的整页图
//

import Foundation
import CoreGraphics

/// 一行被识别出来的原文（含位置与方向）
struct MangaTextLine: Identifiable, Sendable, Equatable {
    let id: UUID
    /// 识别出的原文
    var text: String
    /// Vision 归一化坐标（原点在**左下角**，取值 0~1）
    var boundingBox: CGRect
    /// 是否竖排（日漫常见）
    var isVertical: Bool
    /// Vision 置信度（0~1，用于多策略合并时择优）
    var confidence: Float

    init(id: UUID = UUID(), text: String, boundingBox: CGRect, isVertical: Bool, confidence: Float = 1) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.isVertical = isVertical
        self.confidence = confidence
    }
}

/// 翻译并排版后的一条内容（供渲染层使用）
struct MangaTranslatedLine: Identifiable, Sendable, Equatable {
    let id: UUID
    /// 原文
    var source: String
    /// 译文
    var translated: String
    /// Vision 归一化坐标（原点左下）
    var boundingBox: CGRect
    /// 是否竖排
    var isVertical: Bool

    init(id: UUID = UUID(), source: String, translated: String, boundingBox: CGRect, isVertical: Bool) {
        self.id = id
        self.source = source
        self.translated = translated
        self.boundingBox = boundingBox
        self.isVertical = isVertical
    }
}

/// 翻译阶段 —— 驱动阅读器里的进度 HUD
enum MangaTranslationStage: Equatable {
    case idle
    case recognizing
    case translating
    case rendering
    case done
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .recognizing, .translating, .rendering: return true
        case .idle, .done, .failed: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return ""
        case .recognizing: return "识别文字…"
        case .translating: return "翻译中…"
        case .rendering: return "排版合成…"
        case .done: return "完成"
        case .failed(let message): return message
        }
    }
}

/// 一次页翻译的结果
struct MangaPageTranslation {
    /// 渲染好的、带译文的整页图
    var image: PlatformImage
    /// 每条译文（调试/导出用）
    var lines: [MangaTranslatedLine]
}
