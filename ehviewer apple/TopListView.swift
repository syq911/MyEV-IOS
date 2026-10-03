//
//  TopListView.swift
//  ehviewer apple
//
//  排行榜视图 - 7 个类别 × 4 个时间维度
//

import SwiftUI
import EhModels
import EhAPI
import EhSettings

struct TopListView: View {
    @State private var vm = TopListViewModel()
    @State private var selectedCategory = 0
    @State private var selectedPeriod = 0

    /// 被推入父导航栈时，不创建自己的 NavigationStack，避免嵌套
    private var isPushed: Bool = false

    private let periods = ["全部时间", "过去一年", "过去一个月", "昨天"]

    /// 时间维度 → toplist.php 的 tl 参数
    /// 对齐 e-hentai 真实页面: 11 全部时间 / 12 过去一年 / 13 过去一个月 / 15 昨天
    private static let periodTL = [11, 12, 13, 15]

    init(isPushed: Bool = false) {
        self.isPushed = isPushed
    }

    var body: some View {
        if isPushed {
            // 父 NavigationStack (MoreTabView / MainTabView) 已注册所需 destination
            topListContent
        } else {
            NavigationStack {
                topListContent
                    // 与全 App 保持一致：全部走 value-based 导航，避免与顶层
                    // NavigationStack 里的 destination-based 链接混用导致路径错乱
                    .navigationDestination(for: GalleryInfo.self) { gallery in
                        GalleryDetailView(gallery: gallery)
                            .id(gallery.gid)
                    }
                    .navigationDestination(for: UploaderSearchDestination.self) { dest in
                        GalleryListView(mode: .uploader(keyword: dest.uploader), isPushed: true)
                    }
                    .navigationDestination(for: TagSearchDestination.self) { dest in
                        GalleryListView(mode: .tag(keyword: dest.tag), isPushed: true)
                    }
            }
        }
    }

    private var topListContent: some View {
        VStack(spacing: 0) {
            // 类别选择 —— 横向可滚动，避免一行放不下被省略号截断
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(vm.categoryNames.enumerated()), id: \.offset) { i, name in
                        categoryChip(index: i, name: name)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .disabled(vm.categoryNames.isEmpty)

            // 时间维度选择
            Picker("时间", selection: $selectedPeriod) {
                ForEach(0..<periods.count, id: \.self) { i in
                    Text(periods[i]).tag(i)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .disabled(vm.categoryNames.isEmpty)

            Divider()

            if vm.isLoading {
                ProgressView("加载排行榜...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .foregroundStyle(.secondary)
                    Button("重试") {
                        Task { await vm.load() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                topListBody
            }
        }
        .navigationTitle("排行榜")
        .onChange(of: vm.categoryNames) { _, names in
            if selectedCategory >= names.count {
                selectedCategory = 0
            }
        }
        .onChange(of: selectedCategory) { _, _ in
            Task { await loadGalleryIfNeeded() }
        }
        .onChange(of: selectedPeriod) { _, _ in
            Task { await loadGalleryIfNeeded() }
        }
        .task {
            await vm.load()
            await loadGalleryIfNeeded()
        }
    }

    /// 当前选中的分类名
    private var currentCategoryName: String {
        guard selectedCategory >= 0, selectedCategory < vm.categoryNames.count else { return "" }
        return vm.categoryNames[selectedCategory]
    }

    /// 是否 Gallery 分类 —— 只有它用画廊行样式展示（左封面 + 右文字信息）
    private var isGalleryCategory: Bool { currentCategoryName == "Gallery" }

    /// Gallery 分类的数据来自 toplist.php?tl= 标准画廊列表（带封面），按需加载
    private func loadGalleryIfNeeded(force: Bool = false) async {
        guard isGalleryCategory else { return }
        let index = min(max(selectedPeriod, 0), Self.periodTL.count - 1)
        await vm.loadGalleryTopList(tl: Self.periodTL[index], force: force)
    }

    /// 分类选择胶囊（横向滚动，放得下全部分类）
    private func categoryChip(index: Int, name: String) -> some View {
        let selected = selectedCategory == index
        return Button {
            selectedCategory = index
        } label: {
            Text(name)
                .font(.subheadline)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12)))
                .overlay(Capsule().stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var topListBody: some View {
        if isGalleryCategory {
            galleryListBody
        } else {
            textListBody
        }
    }

    /// Gallery 分类：标准画廊列表（左封面 + 右文字信息，对齐首页卡片）
    @ViewBuilder
    private var galleryListBody: some View {
        if vm.isLoadingGallery && vm.galleryItems.isEmpty {
            ProgressView("加载排行榜...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.galleryErrorMessage, vm.galleryItems.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(error)
                    .foregroundStyle(.secondary)
                Button("重试") {
                    Task { await loadGalleryIfNeeded(force: true) }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(vm.galleryItems, id: \.gid) { gallery in
                NavigationLink(value: gallery) {
                    GalleryRow(
                        gallery: gallery,
                        showJpnTitle: AppSettings.shared.showJpnTitle,
                        fixThumbUrl: AppSettings.shared.fixThumbUrl
                    )
                }
                .listRowInsets(EdgeInsets())
            }
            .listStyle(.plain)
        }
    }

    /// 其它分类 (Uploader / Tagging / ...)：文字列表，点击进入上传者/标签画廊列表
    private var textListBody: some View {
        let items = vm.items(for: selectedCategory, period: selectedPeriod)
        return List(items.indices, id: \.self) { idx in
            let item = items[idx]
            if let uploader = Self.uploaderName(from: item.href) {
                NavigationLink(value: UploaderSearchDestination(uploader: uploader)) {
                    TopListRow(rank: idx + 1, item: item)
                }
            } else {
                NavigationLink(value: TagSearchDestination(tag: Self.tagName(from: item.href) ?? item.text)) {
                    TopListRow(rank: idx + 1, item: item)
                }
            }
        }
        .listStyle(.plain)
    }

    /// 从 /uploader/<name> 形式的 href 里取出上传者名
    private static func uploaderName(from href: String?) -> String? {
        guard let href, let r = href.range(of: "/uploader/") else { return nil }
        let rest = href[r.upperBound...]
        let name = rest.split(separator: "/").first.map(String.init) ?? ""
        let decoded = name.removingPercentEncoding ?? name
        return decoded.isEmpty ? nil : decoded
    }

    /// 从 /tag/<name> 形式的 href 里取出标签名
    private static func tagName(from href: String?) -> String? {
        guard let href, let r = href.range(of: "/tag/") else { return nil }
        let rest = href[r.upperBound...]
        let name = rest.split(separator: "/").first.map(String.init) ?? ""
        let decoded = name.removingPercentEncoding ?? name
        return decoded.isEmpty ? nil : decoded
    }
}

struct TopListRow: View {
    let rank: Int
    let item: TopListItem

    var body: some View {
        HStack(spacing: 12) {
            // 排名
            Text("\(rank)")
                .font(.headline)
                .foregroundStyle(rankColor)
                .frame(width: 30)

            Text(item.text)
                .lineLimit(2)

            Spacer()

            if item.href != nil {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var rankColor: Color {
        switch rank {
        case 1: return .yellow
        case 2: return .gray
        case 3: return .orange
        default: return .secondary
        }
    }
}

// MARK: - ViewModel

@Observable
class TopListViewModel {
    var isLoading = false
    var errorMessage: String?
    var detail: TopListDetail?

    /// Gallery 分类：来自 toplist.php?tl= 的标准画廊列表（含封面/标签/评分）
    var galleryItems: [GalleryInfo] = []
    var isLoadingGallery = false
    var galleryErrorMessage: String?
    private var loadedGalleryTL: Int?

    var categoryNames: [String] {
        detail?.lists.map { $0.name } ?? []
    }

    func load() async {
        guard !isLoading else { return }
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }

        do {
            let url = EhURL.topListUrl()
            let parsed = try await EhAPI.shared.getTopList(url: url)
            await MainActor.run {
                self.detail = parsed
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = EhError.localizedMessage(for: error)
                self.isLoading = false
            }
        }
    }

    /// 加载 Gallery 分类的标准排行榜（带封面）。
    ///
    /// 总览页 (toplist.php 不带 tl) 里的每一项只有一行文字链接、**不含封面图**，
    /// 所以 Gallery 分类改用带 tl 参数的标准紧凑画廊列表页 (itg gltc)，
    /// 结构与首页完全一致，通用解析器可直接吃下（对应 Android ListUrlBuilder.MODE_TOPLIST）。
    func loadGalleryTopList(tl: Int, force: Bool = false) async {
        if !force, loadedGalleryTL == tl, !galleryItems.isEmpty { return }
        await MainActor.run {
            isLoadingGallery = true
            galleryErrorMessage = nil
        }

        do {
            let url = "\(EhURL.topListUrl())?tl=\(tl)"
            let parsed = try await EhAPI.shared.getGalleryList(url: url)
            await MainActor.run {
                self.galleryItems = parsed.galleries
                self.loadedGalleryTL = tl
                self.isLoadingGallery = false
            }
        } catch {
            await MainActor.run {
                self.galleryErrorMessage = EhError.localizedMessage(for: error)
                self.isLoadingGallery = false
            }
        }
    }

    func items(for categoryIndex: Int, period: Int) -> [TopListItem] {
        guard let detail, categoryIndex >= 0, categoryIndex < detail.lists.count else { return [] }
        let category = detail.lists[categoryIndex]
        switch period {
        case 1: return category.pastYear
        case 2: return category.pastMonth
        case 3: return category.yesterday
        default: return category.allTime
        }
    }
}

#Preview {
    TopListView()
}
