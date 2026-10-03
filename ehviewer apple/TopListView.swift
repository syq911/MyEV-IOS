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

    init(isPushed: Bool = false) {
        self.isPushed = isPushed
    }

    /// 从排行榜链接中解析画廊 gid 和 token
    /// href 格式: https://e-hentai.org/g/12345/abcdef1234/ 或 /g/12345/abcdef1234/
    private static func parseGalleryHref(_ href: String?) -> (gid: Int64, token: String)? {
        guard let href else { return nil }
        // 匹配 /g/{gid}/{token}/ 模式
        let pattern = #"/g/(\d+)/([0-9a-f]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: href, range: NSRange(href.startIndex..., in: href)),
              match.numberOfRanges >= 3 else { return nil }
        guard let gidRange = Range(match.range(at: 1), in: href),
              let tokenRange = Range(match.range(at: 2), in: href),
              let gid = Int64(href[gidRange]) else { return nil }
        return (gid, String(href[tokenRange]))
    }

    var body: some View {
        if isPushed {
            topListContent
        } else {
            NavigationStack {
                topListContent
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
        .task { await vm.load() }
    }

    /// 当前选中的分类名
    private var currentCategoryName: String {
        guard selectedCategory >= 0, selectedCategory < vm.categoryNames.count else { return "" }
        return vm.categoryNames[selectedCategory]
    }

    /// 是否 Gallery 分类 —— 只有它用画廊行样式展示（左封面 + 右文字信息）
    private var isGalleryCategory: Bool { currentCategoryName == "Gallery" }

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
        let items = vm.items(for: selectedCategory, period: selectedPeriod)
        List(items.indices, id: \.self) { idx in
            let item = items[idx]
            if isGalleryCategory, let parsed = Self.parseGalleryHref(item.href) {
                // Gallery 分类：复用「热门」的画廊行 (左封面 + 右文字信息)
                NavigationLink {
                    GalleryDetailView(gallery: galleryInfo(item, parsed: parsed))
                        .id(parsed.gid)
                } label: {
                    GalleryRow(
                        gallery: galleryInfo(item, parsed: parsed),
                        showJpnTitle: AppSettings.shared.showJpnTitle,
                        fixThumbUrl: AppSettings.shared.fixThumbUrl
                    )
                }
            } else if isGalleryCategory {
                // Gallery 分类但链接解析失败 —— 退化为纯文本行
                TopListRow(rank: idx + 1, item: item)
            } else {
                // 其它分类 (Uploader / Tagging / ...)：点击用搜索逻辑打开对应内容
                NavigationLink {
                    searchDestination(for: item)
                } label: {
                    TopListRow(rank: idx + 1, item: item)
                }
            }
        }
        .listStyle(.plain)
    }

    private func galleryInfo(_ item: TopListItem, parsed: (gid: Int64, token: String)) -> GalleryInfo {
        GalleryInfo(gid: parsed.gid, token: parsed.token, title: item.text, thumb: item.thumb)
    }

    /// 非 Gallery 分类点击后的跳转目标：上传者走上传者搜索，其余走关键词搜索
    @ViewBuilder
    private func searchDestination(for item: TopListItem) -> some View {
        if let uploader = Self.uploaderName(from: item.href) {
            GalleryListView(mode: .uploader(keyword: uploader), isPushed: true)
        } else {
            GalleryListView(mode: .search(keyword: item.text), isPushed: true)
        }
    }

    /// 从 /uploader/<name> 形式的 href 里取出上传者名
    private static func uploaderName(from href: String?) -> String? {
        guard let href, let r = href.range(of: "/uploader/") else { return nil }
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
