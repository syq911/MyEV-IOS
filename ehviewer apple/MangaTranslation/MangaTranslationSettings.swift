//
//  MangaTranslationSettings.swift
//  ehviewer apple
//
//  漫画翻译设置 + API Key 安全存储
//

import Foundation
import Security

// MARK: - 翻译后端

enum MangaTranslationProvider: Int, CaseIterable, Sendable {
    case deepSeek = 0
    case appleOnDevice = 1

    var label: String {
        switch self {
        case .deepSeek: return "DeepSeek API"
        case .appleOnDevice: return "Apple 端上翻译"
        }
    }
}

// MARK: - 语言

/// 源语言（用于 OCR 识别语言 + 翻译提示词）
enum MangaTranslationSource: String, CaseIterable, Sendable {
    case auto
    case japanese
    case chinese
    case english
    case korean

    var label: String {
        switch self {
        case .auto: return "自动检测"
        case .japanese: return "日文"
        case .chinese: return "中文"
        case .english: return "英文"
        case .korean: return "韩文"
        }
    }

    /// Vision OCR 的识别语言列表 —— 自动时给中文/日文/英文三种
    var visionLanguages: [String] {
        switch self {
        case .auto: return ["ja-JP", "zh-Hans", "zh-Hant", "en-US"]
        case .japanese: return ["ja-JP"]
        case .chinese: return ["zh-Hans", "zh-Hant"]
        case .english: return ["en-US"]
        case .korean: return ["ko-KR"]
        }
    }

    /// 给翻译提示词用的语言名（自动时留空，交给模型判断）
    var promptName: String {
        switch self {
        case .auto: return ""
        case .japanese: return "日文"
        case .chinese: return "中文"
        case .english: return "英文"
        case .korean: return "韩文"
        }
    }
}

/// 目标语言
enum MangaTranslationTarget: String, CaseIterable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"

    var label: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁体中文"
        case .english: return "英文"
        case .japanese: return "日文"
        }
    }

    /// 给翻译提示词用的语言名
    var promptName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁体中文"
        case .english: return "英文"
        case .japanese: return "日文"
        }
    }
}

// MARK: - 设置

/// 漫画翻译设置。API Key 走 Keychain（失败回退 UserDefaults），其余走 UserDefaults。
///
/// 刻意做成一个**普通单例类 + 计算属性**（不是 @Observable）：
/// 设置界面用局部 @State 读改写回，阅读器在调用时读取最新值，避免 Observation 的复杂度。
final class MangaTranslationSettings: @unchecked Sendable {
    static let shared = MangaTranslationSettings()
    private let defaults = UserDefaults.standard
    private init() {}

    // MARK: 通用

    /// 是否在阅读器工具栏显示「翻译本页」按钮
    var enabled: Bool {
        get { defaults.bool(forKey: "manga_tr_enabled") }
        set { defaults.set(newValue, forKey: "manga_tr_enabled") }
    }

    var provider: MangaTranslationProvider {
        get { MangaTranslationProvider(rawValue: defaults.integer(forKey: "manga_tr_provider")) ?? .deepSeek }
        set { defaults.set(newValue.rawValue, forKey: "manga_tr_provider") }
    }

    var sourceLanguage: MangaTranslationSource {
        get { MangaTranslationSource(rawValue: defaults.string(forKey: "manga_tr_source") ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "manga_tr_source") }
    }

    var targetLanguage: MangaTranslationTarget {
        get { MangaTranslationTarget(rawValue: defaults.string(forKey: "manga_tr_target") ?? "") ?? .simplifiedChinese }
        set { defaults.set(newValue.rawValue, forKey: "manga_tr_target") }
    }

    /// 盖上原文字框时填充的底色：true=按取样色填充；false=纯白
    var useSampledBackground: Bool {
        get { defaults.object(forKey: "manga_tr_sampled_bg") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "manga_tr_sampled_bg") }
    }

    /// 是否在译文下/旁保留一行小号原文
    var showOriginalText: Bool {
        get { defaults.bool(forKey: "manga_tr_show_original") }
        set { defaults.set(newValue, forKey: "manga_tr_show_original") }
    }

    /// 译文字号缩放（0.6 ~ 1.4）
    var fontScale: Double {
        get {
            let v = defaults.object(forKey: "manga_tr_font_scale") as? Double ?? 1.0
            return min(1.4, max(0.6, v))
        }
        set { defaults.set(min(1.4, max(0.6, newValue)), forKey: "manga_tr_font_scale") }
    }

    // MARK: DeepSeek

    /// OpenAI 兼容端点根地址（默认官方 DeepSeek）
    var deepSeekBaseURL: String {
        get { defaults.string(forKey: "manga_tr_ds_base") ?? "https://api.deepseek.com" }
        set { defaults.set(newValue, forKey: "manga_tr_ds_base") }
    }

    var deepSeekModel: String {
        get { defaults.string(forKey: "manga_tr_ds_model") ?? "deepseek-chat" }
        set { defaults.set(newValue, forKey: "manga_tr_ds_model") }
    }

    /// API Key —— 存 Keychain，读取失败回退 UserDefaults
    var deepSeekAPIKey: String {
        get { MangaSecureStore.string(forKey: "deepseek_api_key") ?? "" }
        set { MangaSecureStore.set(newValue, forKey: "deepseek_api_key") }
    }

    var hasAPIKey: Bool { !deepSeekAPIKey.trimmingCharacters(in: .whitespaces).isEmpty }
}

// MARK: - Keychain 存储（Keychain 失败回退 UserDefaults）

/// 极简 Keychain 封装。侧载/adhoc 签名时 Keychain 可能因缺 entitlement 失败，
/// 此时自动回退到 UserDefaults，保证功能不因存储层而不可用。
enum MangaSecureStore {
    private static let service = "Stellatrix.ehviewer-apple.manga-translation"

    static func string(forKey key: String) -> String? {
        if let keychainValue = keychainGet(key) { return keychainValue }
        return UserDefaults.standard.string(forKey: fallbackKey(key))
    }

    static func set(_ value: String, forKey key: String) {
        if value.isEmpty {
            _ = keychainDelete(key)
            UserDefaults.standard.removeObject(forKey: fallbackKey(key))
            return
        }
        // 同步写一份到 Keychain，并保留 UserDefaults 兜底
        let ok = keychainSet(value, key: key)
        if ok {
            UserDefaults.standard.removeObject(forKey: fallbackKey(key))
        } else {
            UserDefaults.standard.set(value, forKey: fallbackKey(key))
        }
    }

    private static func fallbackKey(_ key: String) -> String { "secure_fallback_\(key)" }

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private static func keychainSet(_ value: String, key: String) -> Bool {
        var query = baseQuery(key)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func keychainGet(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private static func keychainDelete(_ key: String) -> Bool {
        SecItemDelete(baseQuery(key) as CFDictionary) == errSecSuccess
    }
}
