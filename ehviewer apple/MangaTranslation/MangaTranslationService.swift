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
    /// 批量翻译。
    /// 返回「输入下标 → 译文」的映射：只要模型翻出了某几条就返回那几条，
    /// 缺的条目就不出现（由调用方决定如何降级），避免因个别条数不齐而整页不翻。
    func translate(
        _ texts: [String],
        source: MangaTranslationSource,
        target: MangaTranslationTarget
    ) async throws -> [Int: String]
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
    ) async throws -> [Int: String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw MangaTranslationError.missingAPIKey }
        guard !texts.isEmpty else { return [:] }

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
            // 低温保证「严格按格式输出 / 条数稳定」，高温容易漏项或改写结构
            temperature: 0.3,
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

        // 1) 首选「带下标」的 JSON，能容忍漏项并按 i 精确对位
        if let indexed = Self.parseIndexedTranslations(content), !indexed.isEmpty {
            return indexed
        }
        // 2) 回退：纯字符串数组，按下标配对
        let array = try Self.parseTranslations(content)
        var map: [Int: String] = [:]
        for (index, text) in array.enumerated() where index < texts.count {
            map[index] = text
        }
        guard !map.isEmpty else { throw MangaTranslationError.emptyResponse }
        return map
    }

    // MARK: 提示词

    static func systemPrompt(source: MangaTranslationSource, target: MangaTranslationTarget) -> String {
        let sourceHint = source.promptName.isEmpty ? "（自动判断）" : source.promptName
        return """
        你是一名资深的漫画本地化译者。用户会给你一个 JSON 字符串数组，每一项是一段漫画对白或旁白。
        请把每一项翻译成\(target.promptName)。源语言为\(sourceHint)。
        要求：
        1. 只输出一个 JSON 数组，每个元素形如 {"i": 序号, "t": "译文"}；i 是从 0 开始、与输入一一对应的下标。
        2. 不要输出解释、标题或 Markdown 代码块。即使某条无法翻译，也要保留它正确的 i 序号，绝不整体错位。
        3. 译文简洁、口语化，符合漫画对白语气，不要逐字硬译。
        4. 拟声词/语气词翻成自然的目标语言表达。
        """
    }

    static func userPrompt(texts: [String]) -> String {
        // 带上下标，减少模型对位错误
        let indexed = texts.enumerated().map { ["i": $0.offset, "text": $0.element] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: indexed),
              let string = String(data: data, encoding: .utf8) else {
            return (try? JSONEncoder().encode(texts)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        return string
    }

    // MARK: 解析

    /// 从模型输出里提取 `{"i":..,"t":..}` 数组，返回「下标 → 译文」。解析失败返回 nil。
    static func parseIndexedTranslations(_ content: String) -> [Int: String]? {
        guard let json = jsonBody(content), let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let array = object as? [[String: Any]] else { return nil }

        var map: [Int: String] = [:]
        for element in array {
            let index: Int?
            if let i = element["i"] as? Int {
                index = i
            } else if let number = element["i"] as? NSNumber {
                index = number.intValue
            } else if let i = element["index"] as? Int {
                index = i
            } else {
                index = nil
            }
            let text = (element["t"] as? String)
                ?? (element["translation"] as? String)
                ?? (element["text"] as? String)
            if let index, let text, !text.isEmpty {
                map[index] = text
            }
        }
        return map.isEmpty ? nil : map
    }

    /// 从模型输出里提取 JSON 字符串数组。
    /// **不再因条数不匹配而抛错** —— 有多少返回多少，缺的由调用方降级处理。
    static func parseTranslations(_ content: String) throws -> [String] {
        guard let json = jsonBody(content), let data = json.data(using: .utf8) else {
            throw MangaTranslationError.emptyResponse
        }
        if let strings = try? JSONDecoder().decode([String].self, from: data) {
            return strings
        }
        if let any = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            let strings = any.compactMap { $0 as? String }
            if !strings.isEmpty { return strings }
        }
        throw MangaTranslationError.emptyResponse
    }

    /// 抽出正文里的 JSON 主体（数组或对象），去掉代码块围栏与多余文字
    static func jsonBody(_ content: String) -> String? {
        let cleaned = stripCodeFences(content)
        guard let start = cleaned.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let end = cleaned.lastIndex(where: { $0 == "]" || $0 == "}" }),
              start <= end else { return nil }
        return String(cleaned[start...end])
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
