//
//  MangaTranslationService.swift
//  ehviewer apple
//
//  翻译后端：协议 + DeepSeek（OpenAI 兼容）
//

import Foundation

// MARK: - 错误

enum MangaTranslationError: LocalizedError {
    case missingAPIKey
    case badURL
    case http(status: Int, body: String)
    case emptyResponse
    case countMismatch(expected: Int, got: Int)
    case noTextRecognized
    case imageUnavailable
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "未配置翻译 API Key（可在设置中填写，或改用 Apple 端上翻译）"
        case .badURL: return "翻译接口地址无效"
        case .http(let status, let body): return "翻译接口返回 \(status)：\(body)"
        case .emptyResponse: return "翻译结果为空或格式无法解析"
        case .countMismatch(let expected, let got): return "译文条数不匹配（期望 \(expected)，实际 \(got)）"
        case .noTextRecognized: return "本页没有识别到文字（可在设置里把源语言改为「日文」重试）"
        case .imageUnavailable: return "当前页图片尚未加载完成"
        case .cancelled: return "翻译已取消"
        }
    }
}

// MARK: - 协议

protocol MangaTranslator: Sendable {
    /// 批量翻译。返回数组长度、顺序必须与 `texts` 一致。
    func translate(
        _ texts: [String],
        source: MangaTranslationSource,
        target: MangaTranslationTarget
    ) async throws -> [String]
}

// MARK: - DeepSeek（OpenAI 兼容）

struct DeepSeekTranslator: MangaTranslator {
    let apiKey: String
    let baseURL: String
    let model: String

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    func translate(
        _ texts: [String],
        source: MangaTranslationSource,
        target: MangaTranslationTarget
    ) async throws -> [String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw MangaTranslationError.missingAPIKey }
        guard !texts.isEmpty else { return [] }

        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: trimmed + "/chat/completions") else { throw MangaTranslationError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let payload = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: Self.systemPrompt(source: source, target: target)),
                .init(role: "user", content: Self.userPrompt(texts: texts)),
            ],
            temperature: 1.1,
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MangaTranslationError.emptyResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MangaTranslationError.http(status: http.statusCode, body: String(body.prefix(300)))
        }

        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = decoded.choices.first?.message.content else {
            throw MangaTranslationError.emptyResponse
        }
        return try Self.parseTranslations(content, expected: texts.count)
    }

    // MARK: 提示词

    static func systemPrompt(source: MangaTranslationSource, target: MangaTranslationTarget) -> String {
        let sourceHint = source.promptName.isEmpty ? "（自动判断）" : source.promptName
        return """
        你是一名资深的漫画本地化译者。用户会给你一个 JSON 字符串数组，每一项是一段漫画对白或旁白。
        请把每一项翻译成\(target.promptName)。源语言为\(sourceHint)。
        要求：
        1. 严格只输出一个 JSON 字符串数组，长度与顺序和输入完全一致；不要输出解释、标题或 Markdown 代码块。
        2. 译文简洁、口语化，符合漫画对白语气，不要逐字硬译。
        3. 拟声词/语气词翻成自然的目标语言表达。
        """
    }

    static func userPrompt(texts: [String]) -> String {
        let data = (try? JSONEncoder().encode(texts)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    // MARK: 解析

    /// 从模型输出里提取 JSON 字符串数组，并校验条数
    static func parseTranslations(_ content: String, expected: Int) throws -> [String] {
        let cleaned = stripCodeFences(content)
        guard let start = cleaned.firstIndex(of: "["),
              let end = cleaned.lastIndex(of: "]"),
              start <= end else {
            throw MangaTranslationError.emptyResponse
        }
        let json = String(cleaned[start...end])
        guard let data = json.data(using: .utf8) else {
            throw MangaTranslationError.emptyResponse
        }

        var result: [String]?
        if let strings = try? JSONDecoder().decode([String].self, from: data) {
            result = strings
        } else if let any = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            result = any.map { $0 as? String ?? String(describing: $0) }
        }

        guard let translations = result else { throw MangaTranslationError.emptyResponse }
        guard translations.count == expected else {
            throw MangaTranslationError.countMismatch(expected: expected, got: translations.count)
        }
        return translations
    }

    /// 去掉 ```json ... ``` 代码块围栏
    static func stripCodeFences(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            // 去掉首行围栏
            if let newline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: newline)...])
            }
            if let range = s.range(of: "```", options: .backwards) {
                s = String(s[..<range.lowerBound])
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - OpenAI 兼容请求/响应

private struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    let model: String
    let messages: [Message]
    let temperature: Double
    let stream: Bool
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
}
