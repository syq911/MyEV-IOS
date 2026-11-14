//
//  ZipArchiveTests.swift
//  ehviewer appleTests
//
//  ZIP 读取的回归测试。
//
//  夹具是真实生成的 zip（Python zipfile，分别用 store 与 deflate 两种压缩方式），
//  刻意把 `page1` 写在 `page10` 之后，并混入 `__MACOSX/`、`.DS_Store`、
//  `readme.txt` 和一个目录条目 —— 这些都是真实漫画包里会遇到的脏数据。
//  用 base64 内联而不是放资源文件：测试 target 加资源要改工程文件，
//  而这几百字节完全在可读范围内。
//

#if os(iOS)
import Testing
import Foundation
@testable import ehviewer_apple

struct ZipArchiveTests {

    private func makeArchive(_ base64: String) throws -> ZipArchive {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-\(UUID().uuidString).zip")
        guard let data = Data(base64Encoded: base64) else {
            throw ZipError.notZipArchive
        }
        try data.write(to: url)
        return try ZipArchive(url: url)
    }

    // MARK: store（method 0）

    @Test func readsStoredEntries() throws {
        let archive = try makeArchive(Self.storedZip)
        #expect(archive.entries.count == 8)

        let names = archive.entries.map(\.name)
        #expect(names.contains("page1.jpg"))
        #expect(names.contains("folder/"))

        let entry = try #require(archive.entries.first { $0.name == "page10.jpg" })
        #expect(entry.method == 0)
        #expect(try archive.data(for: entry) == Data("PAGE-10-content".utf8))
    }

    // MARK: deflate（method 8）

    @Test func readsDeflatedEntries() throws {
        let archive = try makeArchive(Self.deflatedZip)
        let entry = try #require(archive.entries.first { $0.name == "page2.jpg" })
        #expect(entry.method == 8)
        #expect(try archive.data(for: entry) == Data("PAGE-2-content".utf8))
    }

    @Test func deflateRoundTripsEveryPage() throws {
        let archive = try makeArchive(Self.deflatedZip)
        let expected: [String: String] = [
            "page1.jpg": "PAGE-1-content",
            "page2.jpg": "PAGE-2-content",
            "page10.jpg": "PAGE-10-content",
            "sub/page3.png": "PNG-PAGE-3"
        ]
        for (name, content) in expected {
            let entry = try #require(archive.entries.first { $0.name == name })
            #expect(try archive.data(for: entry) == Data(content.utf8))
        }
    }

    // MARK: 页面筛选 + 页序

    @Test func filtersJunkAndSortsNaturally() throws {
        let archive = try makeArchive(Self.storedZip)
        let pages = LocalComicImportPlan.pageEntries(from: archive.entries).map(\.name)

        // 垃圾条目与目录必须被剔掉
        #expect(!pages.contains("__MACOSX/._page1.jpg"))
        #expect(!pages.contains(".DS_Store"))
        #expect(!pages.contains("readme.txt"))
        #expect(!pages.contains("folder/"))

        // 页序：1 → 2 → 10（字符串比较会得到 1 → 10 → 2）
        #expect(pages == ["page1.jpg", "page2.jpg", "page10.jpg", "sub/page3.png"])
    }

    @Test func directoryEntriesAreMarked() throws {
        let archive = try makeArchive(Self.storedZip)
        let dir = try #require(archive.entries.first { $0.name == "folder/" })
        #expect(dir.isDirectory)
    }

    // MARK: 异常

    @Test func rejectsNonZipData() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-\(UUID().uuidString).bin")
        try Data("this is definitely not a zip file".utf8).write(to: url)
        #expect(throws: (any Error).self) {
            _ = try ZipArchive(url: url)
        }
    }

    @Test func crc32MatchesKnownVector() {
        // 标准测试向量：CRC32("123456789") == 0xCBF43926
        #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    // MARK: 夹具

    private static let storedZip = "UEsDBBQAAAAAACVtbl0V1RAIDwAAAA8AAAAKAAAAcGFnZTEwLmpwZ1BBR0UtMTAtY29udGVudFBLAwQUAAAAAAAlbW5dwunxzg4AAAAOAAAACQAAAHBhZ2UyLmpwZ1BBR0UtMi1jb250ZW50UEsDBBQAAAAAACVtbl0H1Xz3DgAAAA4AAAAJAAAAcGFnZTEuanBnUEFHRS0xLWNvbnRlbnRQSwMEFAAAAAAAJW1uXVvIiUcKAAAACgAAAA0AAABzdWIvcGFnZTMucG5nUE5HLVBBR0UtM1BLAwQUAAAAAAAlbW5dOZz7BgQAAAAEAAAAFAAAAF9fTUFDT1NYLy5fcGFnZTEuanBnanVua1BLAwQUAAAAAAAlbW5dOZz7BgQAAAAEAAAACQAAAC5EU19TdG9yZWp1bmtQSwMEFAAAAAAAJW1uXS/dsscMAAAADAAAAAoAAAByZWFkbWUudHh0bm90IGFuIGltYWdlUEsDBBQAAAAAACVtbl0AAAAAAAAAAAAAAAAHAAAAZm9sZGVyL1BLAQIUABQAAAAAACVtbl0V1RAIDwAAAA8AAAAKAAAAAAAAAAAAAACAAQAAAABwYWdlMTAuanBnUEsBAhQAFAAAAAAAJW1uXcLp8c4OAAAADgAAAAkAAAAAAAAAAAAAAIABNwAAAHBhZ2UyLmpwZ1BLAQIUABQAAAAAACVtbl0H1Xz3DgAAAA4AAAAJAAAAAAAAAAAAAACAAWwAAABwYWdlMS5qcGdQSwECFAAUAAAAAAAlbW5dW8iJRwoAAAAKAAAADQAAAAAAAAAAAAAAgAGhAAAAc3ViL3BhZ2UzLnBuZ1BLAQIUABQAAAAAACVtbl05nPsGBAAAAAQAAAAUAAAAAAAAAAAAAACAAdYAAABfX01BQ09TWC8uX3BhZ2UxLmpwZ1BLAQIUABQAAAAAACVtbl05nPsGBAAAAAQAAAAJAAAAAAAAAAAAAACAAQwBAAAuRFNfU3RvcmVQSwECFAAUAAAAAAAlbW5dL92yxwwAAAAMAAAACgAAAAAAAAAAAAAAgAE3AQAAcmVhZG1lLnR4dFBLAQIUABQAAAAAACVtbl0AAAAAAAAAAAAAAAAHAAAAAAAAAAAAEAD9QWsBAABmb2xkZXIvUEsFBgAAAAAIAAgAxwEAAJABAAAAAA=="

    private static let deflatedZip = "UEsDBBQAAAAIACVtbl0V1RAIEQAAAA8AAAAKAAAAcGFnZTEwLmpwZwtwdHfVNTTQTc7PK0nNKwEAUEsDBBQAAAAIACVtbl3C6fHOEAAAAA4AAAAJAAAAcGFnZTIuanBnC3B0d9U10k3OzytJzSsBAFBLAwQUAAAACAAlbW5dB9V89xAAAAAOAAAACQAAAHBhZ2UxLmpwZwtwdHfVNdRNzs8rSc0rAQBQSwMEFAAAAAgAJW1uXVvIiUcMAAAACgAAAA0AAABzdWIvcGFnZTMucG5nC/Bz1w1wdHfVNQYAUEsDBBQAAAAIACVtbl05nPsGBgAAAAQAAAAUAAAAX19NQUNPU1gvLl9wYWdlMS5qcGfLKs3LBgBQSwMEFAAAAAgAJW1uXTmc+wYGAAAABAAAAAkAAAAuRFNfU3RvcmXLKs3LBgBQSwMEFAAAAAgAJW1uXS/dsscOAAAADAAAAAoAAAByZWFkbWUudHh0y8svUUjMU8jMTUxPBQBQSwMEFAAAAAgAJW1uXQAAAAACAAAAAAAAAAcAAABmb2xkZXIvAwBQSwECFAAUAAAACAAlbW5dFdUQCBEAAAAPAAAACgAAAAAAAAAAAAAAgAEAAAAAcGFnZTEwLmpwZ1BLAQIUABQAAAAIACVtbl3C6fHOEAAAAA4AAAAJAAAAAAAAAAAAAACAATkAAABwYWdlMi5qcGdQSwECFAAUAAAACAAlbW5dB9V89xAAAAAOAAAACQAAAAAAAAAAAAAAgAFwAAAAcGFnZTEuanBnUEsBAhQAFAAAAAgAJW1uXVvIiUcMAAAACgAAAA0AAAAAAAAAAAAAAIABpwAAAHN1Yi9wYWdlMy5wbmdQSwECFAAUAAAACAAlbW5dOZz7BgYAAAAEAAAAFAAAAAAAAAAAAAAAgAHeAAAAX19NQUNPU1gvLl9wYWdlMS5qcGdQSwECFAAUAAAACAAlbW5dOZz7BgYAAAAEAAAACQAAAAAAAAAAAAAAgAEWAQAALkRTX1N0b3JlUEsBAhQAFAAAAAgAJW1uXS/dsscOAAAADAAAAAoAAAAAAAAAAAAAAIABQwEAAHJlYWRtZS50eHRQSwECFAAUAAAACAAlbW5dAAAAAAIAAAAAAAAABwAAAAAAAAAAABAA/UF5AQAAZm9sZGVyL1BLBQYAAAAACAAIAMcBAACgAQAAAAA="
}

#endif
