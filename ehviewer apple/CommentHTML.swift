//
//  CommentHTML.swift
//  ehviewer apple
//
//  评论 HTML → 富文本：保留 <a href="..."> 链接（可点击跳转），其余标签剥离。
//  对齐 Android Foobar EhViewer：评论里的链接可点击，站内画廊链接在 App 内打开，
//  其余链接交给系统（浏览器）打开。
//

import Foundation
import SwiftUI
import EhModels

enum CommentHTML {

    /// <a ... href="URL" ...>label</a>
    private static let anchorRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "<a\\s+[^>]*?href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
    }()

    private static let tagRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "<[^>]+>", options: [])
    }()

    /// 把评论 HTML 转成带链接的 AttributedString
    static func attributed(_ html: String) -> AttributedString {
        guard let regex = anchorRegex, !html.isEmpty else {
            return AttributedString(stripTags(html))
        }

        var result = AttributedString()
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        var cursor = 0

        for match in regex.matches(in: html, range: full) {
            // 链接之前的普通文本
            if match.range.location > cursor {
                let plain = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                result.append(AttributedString(stripTags(plain)))
            }
            let href = ns.substring(with: match.range(at: 1))
            let label = stripTags(ns.substring(with: match.range(at: 2)))
            var run = AttributedString(label.isEmpty ? href : label)
            if let url = URL(string: href) {
                run.link = url
            }
            result.append(run)
            cursor = match.range.location + match.range.length
        }

        if cursor < ns.length {
            result.append(AttributedString(stripTags(ns.substring(from: cursor))))
        }
        return result
    }

    private static func stripTags(_ text: String) -> String {
        guard let regex = tagRegex else {
            return text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    /// 从画廊链接解析出 GalleryInfo；非站内画廊链接返回 nil。
    /// 形如 https://e-hentai.org/g/<gid>/<token>/ 或 https://exhentai.org/g/<gid>/<token>/
    static func galleryInfo(from url: URL) -> GalleryInfo? {
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let gIndex = parts.firstIndex(of: "g"),
              parts.count > gIndex + 2,
              let gid = Int64(parts[gIndex + 1]) else { return nil }
        let token = parts[gIndex + 2]
        guard token.count >= 8 else { return nil }
        return GalleryInfo(gid: gid, token: token)
    }
}
