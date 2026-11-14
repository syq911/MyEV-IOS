//
//  LocalComicsView.swift
//  ehviewer apple
//
//  底部「本地」标签：导入并阅读手机里的漫画（压缩包 / 文件夹）。
//
//  交互设计参考常见漫画软件（Tachiyomi 的 Local source、Perfect Viewer）：
//  - 列表里每本显示封面（第一页）、标题、页数、阅读进度
//  - 点开直接进阅读器，复用 App 现有阅读器（翻页/双页/翻译/进度条全都在）
//  - 左滑删除，删除只影响 App 内的副本
//  - 支持一次选多个压缩包批量导入
//

import SwiftUI
import Observation
import UniformTypeIdentifiers
import EhModels

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - 封面缩略图

enum LocalComicThumbnail {
    /// 用 ImageIO 直接解一张小图。
    /// 不加载整页再缩：本地漫画单页可能 3000×4000，列表里几十本书全解一遍会明显卡顿。
    nonisolated static func load(url: URL, maxPixel: CGFloat) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}

private struct LocalComicCoverView: View {
    let url: URL?
    let width: CGFloat

    @State private var image: PlatformImage?

    private var height: CGFloat { width * 4 / 3 }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            if let image {
                #if os(iOS)
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                #else
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                #endif
            } else {
                Image(systemName: "book.closed")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) {
            guard let url, image == nil else { return }
            let loaded = await Task.detached(priority: .utility) {
                LocalComicThumbnail.load(url: url, maxPixel: 300)
            }.value
            if let loaded { image = loaded }
        }
    }
}

// MARK: - 数据模型

@MainActor
@Observable
final class LocalComicsModel {

    private(set) var comics: [LocalComic] = []
    private(set) var isImporting = false
    private(set) var importProgress: Double = 0
    var importError: String?

    var sortOrder: LocalComicSort = .recentlyAdded {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: Self.sortKey) }
    }

    private static let sortKey = "localComics.sortOrder"

    private let storage: LocalComicStorage
    private var library = LocalComicLibrary()
    private var pendingSave: Task<Void, Never>?

    init(storage: LocalComicStorage = LocalComicStorage(root: LocalComicStorage.defaultRoot())) {
        self.storage = storage
        if let saved = UserDefaults.standard.string(forKey: Self.sortKey),
           let order = LocalComicSort(rawValue: saved) {
            sortOrder = order
        }
        reload()
    }

    var sortedComics: [LocalComic] { library.sorted(by: sortOrder) }

    func reload() {
        library = storage.loadLibrary()
        comics = library.sorted(by: sortOrder)
    }

    func pageURLs(for comic: LocalComic) -> [URL] {
        storage.pageURLs(for: comic)
    }

    func coverURL(for comic: LocalComic) -> URL? {
        storage.pageURLs(for: comic).first
    }

    // MARK: 导入

    func importItems(_ urls: [URL]) {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        importProgress = 0
        importError = nil

        let storage = self.storage
        Task { @MainActor in
            do {
                let added = try await Task.detached(priority: .userInitiated) { () -> [LocalComic] in
                    let importer = LocalComicImporter(storage: storage)
                    var results: [LocalComic] = []
                    for (index, url) in urls.enumerated() {
                        let base = Double(index) / Double(urls.count)
                        let slice = 1.0 / Double(urls.count)
                        let comics = try importer.importItem(at: url) { fraction in
                            let value = base + fraction * slice
                            Task { @MainActor in self.importProgress = value }
                        }
                        results.append(contentsOf: comics)
                    }
                    return results
                }.value

                for comic in added {
                    library.upsert(comic)
                }
                try? storage.saveLibrary(library)
                reload()
                isImporting = false
                importProgress = 1
            } catch {
                diag("LocalComic: 导入失败 \(error.localizedDescription)")
                importError = error.localizedDescription
                isImporting = false
            }
        }
    }

    // MARK: 删除

    func delete(_ comic: LocalComic) {
        // 先改索引再删文件：反过来的话，删文件成功、写索引失败会留下幽灵条目
        library.remove(id: comic.id)
        try? storage.saveLibrary(library)
        storage.removeFiles(for: comic)
        reload()
    }

    // MARK: 阅读进度

    /// 只更新内存 + 延迟落盘。
    /// 每翻一页都写一次 JSON（几百 KB）会明显拖慢翻页，而进度丢一秒无所谓。
    func updateProgress(comicID: UUID, page: Int) {
        library.updateProgress(id: comicID, page: page)
        scheduleSave()
    }

    func flushProgress() {
        pendingSave?.cancel()
        pendingSave = nil
        try? storage.saveLibrary(library)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let storage = self.storage
        pendingSave = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            try? storage.saveLibrary(self.library)
        }
    }
}

// MARK: - 界面

struct LocalComicsView: View {

    @State private var model = LocalComicsModel()
    @State private var showImporter = false
    @State private var readingComic: LocalComic?
    @State private var pendingDelete: LocalComic?

    var body: some View {
        NavigationStack {
            Group {
                if model.comics.isEmpty {
                    emptyState
                } else {
                    comicList
                }
            }
            .navigationTitle("本地")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    sortMenu
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(model.isImporting)
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: allowedTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    model.importItems(urls)
                case .failure(let error):
                    model.importError = error.localizedDescription
                }
            }
            .alert("导入失败", isPresented: Binding(
                get: { model.importError != nil },
                set: { if !$0 { model.importError = nil } }
            )) {
                Button("好") { model.importError = nil }
            } message: {
                Text(model.importError ?? "")
            }
            .confirmationDialog(
                LocalComicText.deleteTitle,
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let comic = pendingDelete { model.delete(comic) }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text(LocalComicText.deleteMessage)
            }
            .overlay {
                if model.isImporting { importingOverlay }
            }
            #if os(iOS)
            .fullScreenCover(item: $readingComic) { comic in
                reader(for: comic)
            }
            #else
            .sheet(item: $readingComic) { comic in
                reader(for: comic)
                    .frame(minWidth: 800, minHeight: 600)
            }
            #endif
        }
    }

    // MARK: 子视图

    private var comicList: some View {
        List {
            ForEach(model.sortedComics) { comic in
                Button {
                    readingComic = comic
                } label: {
                    row(comic)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = comic
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func row(_ comic: LocalComic) -> some View {
        HStack(spacing: 12) {
            LocalComicCoverView(url: model.coverURL(for: comic), width: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(comic.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                Text("\(comic.pageCount) \(LocalComicText.pagesSuffix)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if comic.hasProgress {
                    Text(comic.progressText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(LocalComicText.emptyTitle)
                .font(.headline)
            Text(LocalComicText.emptyHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showImporter = true
            } label: {
                Label(LocalComicText.importButton, systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondary.opacity(0.04))
    }

    private var importingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView(value: model.importProgress)
                .frame(width: 200)
            Text(LocalComicText.importing)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: Binding(
                get: { model.sortOrder },
                set: { model.sortOrder = $0; model.reload() }
            )) {
                ForEach(LocalComicSort.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    private func reader(for comic: LocalComic) -> some View {
        ImageReaderView(
            gid: comic.readerIdentity,
            token: "",
            pages: comic.pageCount,
            previewSet: nil,
            initialPage: comic.lastReadPage,
            localPages: model.pageURLs(for: comic),
            localTitle: comic.title,
            onLocalProgress: { page in
                model.updateProgress(comicID: comic.id, page: page)
            }
        )
        .id(comic.id)
        .onDisappear { model.flushProgress() }
    }

    /// 允许选择：文件夹、zip、cbz、rar、cbr
    private var allowedTypes: [UTType] {
        var types: [UTType] = [.folder, .zip]
        for ext in ["cbz", "rar", "cbr"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }
}
