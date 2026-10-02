//
//  SearchFilterPanel.swift
//  ehviewer apple
//
//  搜索筛选面板 — 对齐 Android (FooIbar) SearchFilter.kt 与 SearchBarScreen.kt：
//  搜索框获焦后，下方依次是「分类 chips」「语言/最低评分/页数 + 开关 chips」「搜索历史/标签建议」。
//

import SwiftUI
import EhModels
import EhSettings

// MARK: - 搜索模式 (自 AdvancedSearchView 迁入；新面板不再暴露切换入口，仅保留字段语义)

enum SearchMode: Int, CaseIterable {
    case normal = 0
    case subscription = 1
    case uploader = 2
    case tag = 3

    var label: String {
        switch self {
        case .normal:       return "Normal search"
        case .subscription: return "Subscription search"
        case .uploader:     return "Specify uploader"
        case .tag:          return "Specify tag"
        }
    }

    var listMode: Int {
        switch self {
        case .normal:       return 0
        case .subscription: return 5
        case .uploader:     return 1
        case .tag:          return 2
        }
    }
}

// MARK: - 分类表 (顺序对齐 Android SearchFilter.kt categoryTable)

struct SearchCategoryItem: Identifiable {
    let category: EhCategory
    let name: String
    let color: Color
    var id: Int { category.rawValue }
}

let searchCategoryTable: [SearchCategoryItem] = [
    SearchCategoryItem(category: .doujinshi, name: "Doujinshi", color: Color(red: 0.957, green: 0.263, blue: 0.212)),
    SearchCategoryItem(category: .manga,     name: "Manga",     color: Color(red: 1.0,   green: 0.596, blue: 0.0)),
    SearchCategoryItem(category: .artistCG,  name: "Artist CG", color: Color(red: 0.984, green: 0.753, blue: 0.176)),
    SearchCategoryItem(category: .gameCG,    name: "Game CG",   color: Color(red: 0.298, green: 0.686, blue: 0.314)),
    SearchCategoryItem(category: .western,   name: "Western",   color: Color(red: 0.545, green: 0.765, blue: 0.290)),
    SearchCategoryItem(category: .nonH,      name: "Non-H",     color: Color(red: 0.129, green: 0.588, blue: 0.953)),
    SearchCategoryItem(category: .imageSet,  name: "Image Set", color: Color(red: 0.247, green: 0.318, blue: 0.710)),
    SearchCategoryItem(category: .cosplay,   name: "Cosplay",   color: Color(red: 0.612, green: 0.153, blue: 0.690)),
    SearchCategoryItem(category: .asianPorn, name: "Asian Porn", color: Color(red: 0.585, green: 0.459, blue: 0.804)),
    SearchCategoryItem(category: .misc,      name: "Misc",      color: Color(red: 0.941, green: 0.384, blue: 0.573)),
]

// MARK: - 面板状态

/// 搜索面板状态。
/// 位掩码沿用 iOS/站点语义 (f_sto=0x010 / f_sh=0x080 / f_sfl=0x100 / f_sfu=0x200 / f_sft=0x400)，
/// 不照抄 FooIbar 内部的 AdvanceTable (SH=0x1/STO=0x2，那是他们的私有枚举)。
@Observable
class AdvancedSearchState {
    var searchMode: SearchMode = .normal
    var selectedCategories: Int = EhCategory.all.rawValue

    /// -1 = 不限；0..13 = ListUrlBuilder.languageTags 下标
    var language: Int = -1

    /// -1 = 未设；2...5 = 最低评分
    var minRating: Int = -1

    /// 空串 = 未设
    var pageFrom: String = ""
    var pageTo: String = ""

    // 5 个开关 chip
    var onlyShowWithTorrents = false      // 0x010 f_sto  有种子
    var searchExpungedGalleries = false   // 0x080 f_sh   已删除
    var disableLanguageFilter = false     // 0x100 f_sfl  禁用语言过滤
    var disableUploaderFilter = false     // 0x200 f_sfu  禁用上传者过滤
    var disableTagFilter = false          // 0x400 f_sft  禁用标签过滤

    /// 全关 = 0（不是 -1）。ListUrlBuilder 只在有任一项时才输出 advsearch=1。
    var advanceSearchValue: Int {
        var value = 0
        if onlyShowWithTorrents { value |= 0x010 }
        if searchExpungedGalleries { value |= 0x080 }
        if disableLanguageFilter { value |= 0x100 }
        if disableUploaderFilter { value |= 0x200 }
        if disableTagFilter { value |= 0x400 }
        return value
    }

    /// 全选 / 全不选都视作「不限」，不发 f_cats
    var categoryValue: Int {
        selectedCategories == EhCategory.all.rawValue ? 0 : selectedCategories
    }

    var minRatingValue: Int { (minRating >= 2 && minRating <= 5) ? minRating : -1 }
    var pageFromValue: Int { Int(pageFrom) ?? -1 }
    var pageToValue: Int { Int(pageTo) ?? -1 }

    /// 是否有任一筛选生效（分类/语言不算，它们是独立语义）
    var hasActiveFilter: Bool {
        advanceSearchValue != 0 || minRatingValue != -1 || pageFromValue != -1 || pageToValue != -1
    }

    func isCategorySelected(_ cat: EhCategory) -> Bool {
        selectedCategories & cat.rawValue != 0
    }

    func toggleCategory(_ cat: EhCategory) {
        selectedCategories ^= cat.rawValue
    }

    /// 从快速搜索/URL 还原筛选（语言混在关键词里无法反解，这里不恢复，对齐 iOS 既有行为）
    /// - Parameter category: 0 = 不限（全分类）；否则为分类位掩码
    func restore(category: Int, advanceSearch: Int, minRating: Int, pageFrom: Int, pageTo: Int) {
        selectedCategories = category != 0 ? category : EhCategory.all.rawValue
        let bits = max(advanceSearch, 0)
        onlyShowWithTorrents = bits & 0x010 != 0
        searchExpungedGalleries = bits & 0x080 != 0
        disableLanguageFilter = bits & 0x100 != 0
        disableUploaderFilter = bits & 0x200 != 0
        disableTagFilter = bits & 0x400 != 0
        self.minRating = (minRating >= 2 && minRating <= 5) ? minRating : -1
        self.pageFrom = pageFrom > 0 ? String(pageFrom) : ""
        self.pageTo = pageTo > 0 ? String(pageTo) : ""
    }

    func reset() {
        searchMode = .normal
        selectedCategories = EhCategory.all.rawValue
        language = -1
        minRating = -1
        pageFrom = ""
        pageTo = ""
        onlyShowWithTorrents = false
        searchExpungedGalleries = false
        disableLanguageFilter = false
        disableUploaderFilter = false
        disableTagFilter = false
    }
}

// MARK: - 筛选面板

struct SearchFilterPanel: View {
    @Bindable var state: AdvancedSearchState
    @State private var showPageDialog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            categoryRow
            filterRow
        }
        .padding(.vertical, 6)
        .sheet(isPresented: $showPageDialog) {
            PageRangeDialog(from: state.pageFrom, to: state.pageTo) { from, to in
                state.pageFrom = from
                state.pageTo = to
            }
        }
    }

    // MARK: 第一行：分类 chips（选中的排前面）

    private var categoryRow: some View {
        // 用「分组拼接」而不是 sorted(by:)，保证组内顺序稳定（Swift 的 sort 不保证稳定）
        let selected = searchCategoryTable.filter { state.isCategorySelected($0.category) }
        let unselected = searchCategoryTable.filter { !state.isCategorySelected($0.category) }

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selected + unselected) { item in
                    categoryChip(item)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func categoryChip(_ item: SearchCategoryItem) -> some View {
        let isSelected = state.isCategorySelected(item.category)
        return Button {
            state.toggleCategory(item.category)
        } label: {
            Text(item.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? .white : .primary)
                .background(isSelected ? item.color : Color(.systemGray5), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 第二行：语言 / 最低评分 / 页数 / 开关 chips

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                languageMenu
                minRatingMenu
                pagesChip
                toggleChip("已删除", isOn: $state.searchExpungedGalleries)
                toggleChip("有种子", isOn: $state.onlyShowWithTorrents)
                toggleChip("禁用排除项：语言", isOn: $state.disableLanguageFilter)
                toggleChip("禁用排除项：上传者", isOn: $state.disableUploaderFilter)
                toggleChip("禁用排除项：标签", isOn: $state.disableTagFilter)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
    }

    private var languageMenu: some View {
        let hasSelection = state.language >= 0 && state.language < ListUrlBuilder.languageTags.count
        return Menu {
            Button("不限") { state.language = -1 }
            ForEach(Array(ListUrlBuilder.languageTags.enumerated()), id: \.offset) { index, tag in
                Button(Self.languageDisplayName(tag)) { state.language = index }
            }
        } label: {
            menuChipLabel(
                text: hasSelection ? Self.languageDisplayName(ListUrlBuilder.languageTags[state.language]) : "语言",
                selected: hasSelection
            )
        }
    }

    private var minRatingMenu: some View {
        let hasSelection = state.minRating >= 2
        return Menu {
            Button("不限") { state.minRating = -1 }
            ForEach(2...5, id: \.self) { star in
                Button("\(star) 星") { state.minRating = star }
            }
        } label: {
            menuChipLabel(text: hasSelection ? "\(state.minRating) 星" : "最低评分", selected: hasSelection)
        }
    }

    private var pagesChip: some View {
        let from = Int(state.pageFrom) ?? 0
        let to = Int(state.pageTo) ?? 0
        let text: String
        if from > 0 && to > 0 {
            text = "\(from) - \(to) P"
        } else if from > 0 {
            text = "\(from)+ P"
        } else if to > 0 {
            text = "\(to)- P"
        } else {
            text = "页数"
        }
        return Button {
            showPageDialog = true
        } label: {
            chipLabel(text: text, selected: from > 0 || to > 0)
        }
        .buttonStyle(.plain)
    }

    private func toggleChip(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            chipLabel(text: title, selected: isOn.wrappedValue)
        }
        .buttonStyle(.plain)
    }

    // MARK: 样式

    private func chipLabel(text: String, selected: Bool) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(selected ? Color.accentColor.opacity(0.15) : Color(.systemGray5), in: Capsule())
    }

    private func menuChipLabel(text: String, selected: Bool) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .background(selected ? Color.accentColor.opacity(0.15) : Color(.systemGray5), in: Capsule())
    }

    /// 语言名优先取标签库中文翻译（对齐 Android EhTagDatabase.getTranslation），取不到则显示原文
    static func languageDisplayName(_ tag: String) -> String {
        if let translated = EhTagDatabase.shared.getTranslation(tag) { return translated }
        return tag.split(separator: ":").last.map(String.init) ?? tag
    }
}

// MARK: - 页数范围弹窗（校验失败不关闭）

private struct PageRangeDialog: View {
    let onConfirm: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var fromText: String
    @State private var toText: String
    @State private var errorText: String?

    init(from: String, to: String, onConfirm: @escaping (String, String) -> Void) {
        self.onConfirm = onConfirm
        _fromText = State(initialValue: from)
        _toText = State(initialValue: to)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    TextField("0", text: $fromText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Text("到").foregroundStyle(.secondary)
                    TextField("0", text: $toText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }

                if let errorText {
                    Label(errorText, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("页数")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") { confirm() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.height(220)])
        #endif
    }

    /// 校验规则对齐 Android SearchFilter.kt invalidator：
    /// - 只填上限：上限 ≥ 10
    /// - 上下限都填：下限 ≤ min(上限/2, 上限−20)
    private func confirm() {
        let from = clamp(Int(fromText) ?? 0, 0, 1000)
        let to = clamp(Int(toText) ?? 0, 0, 2000)

        if to != 0 {
            if from != 0 {
                if from > min(to / 2, to - 20) {
                    errorText = "页数范围差至少为 20"
                    return
                }
            } else if to < 10 {
                errorText = "页数最大值至少为 10"
                return
            }
        }

        errorText = nil
        onConfirm(from > 0 ? String(from) : "", to > 0 ? String(to) : "")
        dismiss()
    }

    private func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}

// MARK: - macOS compat (LoginView 依赖 secondarySystemGroupedBackground)

#if os(macOS)
extension NSColor {
    static var systemGroupedBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemGroupedBackground: NSColor { .controlBackgroundColor }
    static var systemGray5: NSColor { .separatorColor }
}
#endif