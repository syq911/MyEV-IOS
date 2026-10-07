//
//  LibraryStatus.swift
//  ehviewer apple
//
//  画廊「库状态」索引 —— 供各列表行**同步**查询某个画廊：
//    · 是否已下载 / 是否下载中
//    · 是否本地收藏
//
//  各列表行（搜索/热门/标签/上传者、历史、本地收藏、下载…）需要在 body 里直接拿这些状态，
//  而 DownloadManager 是 actor、查询是 async，无法在 body 里 await。因此这里维护一份快照：
//    · 列表出现时刷新（各页 .task 里调用 refresh）；
//    · 有下载进行中时短轮询，保证下载完成后角标自动出现；
//    · 收藏变化（galleryFavoriteChanged 通知）时刷新。
//

import Foundation
import Observation
import SwiftUI
import EhModels
import EhDownload
import EhDatabase

@MainActor
@Observable
final class LibraryStatusStore {
    static let shared = LibraryStatusStore()

    /// gid → DownloadManager.state
    private(set) var downloadStates: [Int64: Int] = [:]
    /// 本地收藏的 gid 集合
    private(set) var localFavoriteGids: Set<Int64> = []

    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.refreshSoon() }
        }
        observers.append(center.addObserver(forName: .galleryFavoriteChanged,
                                            object: nil, queue: .main, using: handler))
    }

    // MARK: - 查询

    func downloadState(for gid: Int64) -> Int? { downloadStates[gid] }

    /// 是否已下载完成
    func isDownloaded(gid: Int64) -> Bool { downloadStates[gid] == DownloadManager.stateFinish }

    /// 是否正在下载 / 排队等待
    func isDownloading(gid: Int64) -> Bool {
        guard let state = downloadStates[gid] else { return false }
        return state == DownloadManager.stateDownload || state == DownloadManager.stateWait
    }

    /// 是否本地收藏（云端收藏状态无法离线得知，仅覆盖本地收藏）
    func isLocalFavorite(gid: Int64) -> Bool { localFavoriteGids.contains(gid) }

    // MARK: - 刷新

    /// 从 DownloadManager / 本地收藏库拉取最新状态；有进行中的下载则保持轮询
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true

        let tasks = await DownloadManager.shared.getAllTasks()
        let favGids = await Self.loadLocalFavoriteGids()

        isRefreshing = false

        var snapshot: [Int64: Int] = [:]
        snapshot.reserveCapacity(tasks.count)
        for task in tasks { snapshot[task.gallery.gid] = task.state }
        if snapshot != downloadStates { downloadStates = snapshot }
        if favGids != localFavoriteGids { localFavoriteGids = favGids }

        let hasActive = tasks.contains {
            $0.state == DownloadManager.stateDownload || $0.state == DownloadManager.stateWait
        }
        if hasActive { startPolling() } else { stopPolling() }
    }

    /// 立刻触发一次刷新（不等待），用于下载/收藏动作之后
    func refreshSoon() {
        Task { await refresh() }
    }

    private static func loadLocalFavoriteGids() async -> Set<Int64> {
        await Task.detached(priority: .utility) {
            let records = (try? EhDatabase.shared.getAllLocalFavorites()) ?? []
            return Set(records.map { $0.gid })
        }.value
    }

    private func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}

// MARK: - 缩略图下载角标

/// 缩略图右上角的下载状态角标：已下载=绿底白✓，下载中=蓝底白↓，其余不显示。
struct DownloadBadge: View {
    let gid: Int64
    var size: CGFloat = 18

    var body: some View {
        let store = LibraryStatusStore.shared
        if store.isDownloaded(gid: gid) {
            iconBadge(systemName: "checkmark", tint: .green, label: "已下载")
        } else if store.isDownloading(gid: gid) {
            iconBadge(systemName: "arrow.down", tint: .blue, label: "下载中")
        }
    }

    private func iconBadge(systemName: String, tint: Color, label: String) -> some View {
        ZStack {
            Circle()
                .fill(tint)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.2))
            Image(systemName: systemName)
                .font(.system(size: size * 0.55, weight: .bold))
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.28), radius: 1, y: 0.5)
        .accessibilityLabel(label)
    }
}
