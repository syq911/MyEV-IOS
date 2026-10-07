//
//  CommentHTMLTests.swift
//  ehviewer appleTests
//
//  评论富文本回归测试：HTML → 保留链接的 AttributedString、站内画廊链接解析。
//

import Testing
import Foundation
@testable import ehviewer_apple

struct CommentHTMLTests {

    /// 保留 <a href> 链接，剥离其它标签
    @Test func preservesLinks() {
        let html = "看这个 <a href=\"https://e-hentai.org/g/123/abcdef0123/\">画廊</a> 很好"
        let attr = CommentHTML.attributed(html)
        let text = String(attr.characters)
        #expect(text.contains("画廊"))
        #expect(text.contains("很好"))
        #expect(!text.contains("<a"))
        #expect(!text.contains("href"))

        let links = attr.runs.compactMap { $0.link }
        #expect(links.count == 1)
        #expect(links.first?.absoluteString == "https://e-hentai.org/g/123/abcdef0123/")
    }

    /// 无链接时等同于剥离标签
    @Test func stripsTagsWithoutLinks() {
        let attr = CommentHTML.attributed("<b>你好</b><br>世界")
        #expect(String(attr.characters) == "你好世界")
        #expect(attr.runs.compactMap { $0.link }.isEmpty)
    }

    /// 解析站内画廊链接
    @Test func parsesGalleryURL() {
        let g = CommentHTML.galleryInfo(from: URL(string: "https://e-hentai.org/g/12345/0123456789/")!)
        #expect(g?.gid == 12345)
        #expect(g?.token == "0123456789")

        let ex = CommentHTML.galleryInfo(from: URL(string: "https://exhentai.org/g/999/abcdefghij")!)
        #expect(ex?.gid == 999)
        #expect(ex?.token == "abcdefghij")

        // 非画廊链接 → nil
        #expect(CommentHTML.galleryInfo(from: URL(string: "https://example.com/foo")!) == nil)
        // g 段后缺少 token → nil
        #expect(CommentHTML.galleryInfo(from: URL(string: "https://e-hentai.org/g/123/")!) == nil)
    }
}
