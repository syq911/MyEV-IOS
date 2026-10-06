//
//  DownloadOrderingTests.swift
//  ehviewer appleTests
//
//  下载系统回归测试：
//    1) 下载顺序：永远按「加入时间」先加入先下载（FIFO），与列表显示顺序无关。
//    2) 显示顺序：用户长按拖动只改展示顺序，可持久化，绝不影响下载调度。
//    3) 持久化：重启后 `getAllDownloads()` 仍按「加入顺序 / 用户拖动顺序」返回，
//       不会像旧实现那样翻转成「最新在最上」。
//

import Testing
import Foundation
import EhModels
import EhDatabase
import EhDownload

struct DownloadOrderingTests {

    // MARK: - 测试数据构造

    private static func makeTask(gid: Int64,
                                 state: Int = DownloadManager.stateWait,
                                 added: TimeInterval,
                                 sortOrder: Int = 0) -> DownloadTask {
        DownloadTask(
            gallery: GalleryInfo(gid: gid, token: "t\(gid)", title: "Gallery \(gid)"),
            label: nil,
            state: state,
            addedDate: Date(timeIntervalSince1970: added),
            sortOrder: sortOrder
        )
    }

    private static func makeRecord(gid: Int64,
                                   date: TimeInterval,
                                   sortOrder: Int = 0) -> DownloadRecord {
        DownloadRecord(
            gid: gid, token: "t\(gid)", title: "Gallery \(gid)",
            pages: 10, state: DownloadManager.stateWait,
            sortOrder: sortOrder, date: Date(timeIntervalSince1970: date)
        )
    }

    // MARK: - 下载顺序：先加入先下载

    /// 数组顺序是「显示顺序」，这里故意把后加入的排在前面：
    /// 调度必须按 addedDate 取最早的一个，而不是取数组第一个。
    @Test func nextWaitingIndexPicksEarliestAddedDate() {
        let tasks = [
            Self.makeTask(gid: 3, added: 300, sortOrder: 0),
            Self.makeTask(gid: 1, added: 100, sortOrder: 1),
            Self.makeTask(gid: 2, added: 200, sortOrder: 2),
        ]
        #expect(DownloadOrdering.nextWaitingIndex(in: tasks) == 1)
    }

    @Test func nextWaitingIndexIgnoresNonWaitingStates() {
        let tasks = [
            Self.makeTask(gid: 1, state: DownloadManager.stateFinish, added: 100),
            Self.makeTask(gid: 2, state: DownloadManager.stateNone, added: 200),
            Self.makeTask(gid: 3, state: DownloadManager.stateWait, added: 300),
            Self.makeTask(gid: 4, state: DownloadManager.stateDownload, added: 400),
        ]
        #expect(DownloadOrdering.nextWaitingIndex(in: tasks) == 2)
    }

    @Test func nextWaitingIndexNilWhenNothingWaiting() {
        let tasks = [
            Self.makeTask(gid: 1, state: DownloadManager.stateFinish, added: 100),
            Self.makeTask(gid: 2, state: DownloadManager.stateNone, added: 200),
            Self.makeTask(gid: 3, state: DownloadManager.stateFailed, added: 300),
        ]
        #expect(DownloadOrdering.nextWaitingIndex(in: tasks) == nil)
    }

    /// 加入时间相同时保持稳定（保留靠前的下标），不因拖动而抖动。
    @Test func nextWaitingIndexIsStableOnTie() {
        let tasks = [
            Self.makeTask(gid: 7, added: 100),
            Self.makeTask(gid: 8, added: 100),
        ]
        #expect(DownloadOrdering.nextWaitingIndex(in: tasks) == 0)
    }

    /// 关键回归（bug #1）：拖动改变显示顺序后，下载顺序（谁先下载）不变。
    @Test func reorderingDisplayDoesNotChangeDownloadOrder() {
        var tasks = [
            Self.makeTask(gid: 1, added: 100),
            Self.makeTask(gid: 2, added: 200),
            Self.makeTask(gid: 3, added: 300),
        ]
        let before = DownloadOrdering.nextWaitingIndex(in: tasks)

        // 把最后加入的 gid 3 拖到列表最前 → 数组顺序变成 [3, 1, 2]
        tasks = DownloadOrdering.applyingMove(
            to: tasks, visibleGids: [1, 2, 3],
            fromOffsets: IndexSet(integer: 2), toOffset: 0)

        #expect(tasks.map { $0.gallery.gid } == [3, 1, 2])
        let after = DownloadOrdering.nextWaitingIndex(in: tasks)
        #expect(before == 0)
        #expect(after == 1)                       // gid 1 现在排在数组中间
        #expect(tasks[after].gallery.gid == 1)    // 但它仍应最先下载（最早加入）
    }

    // MARK: - 拖动排序语义 (等价 SwiftUI onMove)

    @Test func movingMatchesSwiftUISemantics() {
        let items = ["A", "B", "C", "D"]
        #expect(DownloadOrdering.moving(items, fromOffsets: IndexSet(integer: 2), toOffset: 0)
                == ["C", "A", "B", "D"])
        #expect(DownloadOrdering.moving(items, fromOffsets: IndexSet(integer: 0), toOffset: 4)
                == ["B", "C", "D", "A"])
        #expect(DownloadOrdering.moving(items, fromOffsets: IndexSet(integer: 0), toOffset: 2)
                == ["B", "A", "C", "D"])
        #expect(DownloadOrdering.moving(items, fromOffsets: IndexSet(), toOffset: 0) == items)
    }

    @Test func applyingMoveReordersWholeQueue() {
        let tasks = [
            Self.makeTask(gid: 1, added: 100),
            Self.makeTask(gid: 2, added: 200),
            Self.makeTask(gid: 3, added: 300),
        ]
        let moved = DownloadOrdering.applyingMove(
            to: tasks, visibleGids: [1, 2, 3],
            fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(moved.map { $0.gallery.gid } == [2, 3, 1])
    }

    /// 过滤视图（按标签/状态/搜索）下拖动：只改变可见项的相对顺序，隐藏项保持原位。
    @Test func applyingMoveWithFilteredSubsetKeepsHiddenInPlace() {
        let tasks = [
            Self.makeTask(gid: 1, added: 100),
            Self.makeTask(gid: 2, added: 200),
            Self.makeTask(gid: 3, added: 300),
            Self.makeTask(gid: 4, added: 400),
        ]
        let moved = DownloadOrdering.applyingMove(
            to: tasks, visibleGids: [1, 3],
            fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(moved.map { $0.gallery.gid } == [3, 2, 1, 4])
    }

    // MARK: - 持久化（内存数据库）

    /// 未拖动过（sortOrder 全 0）时，按加入顺序返回 —— 重启后仍是「先加入的在上」。
    @Test func downloadsPersistedInAddOrder() throws {
        let db = try EhDatabase.makeInMemoryForTesting()

        try db.insertDownload(Self.makeRecord(gid: 1, date: 100))
        try db.insertDownload(Self.makeRecord(gid: 2, date: 200))
        try db.insertDownload(Self.makeRecord(gid: 3, date: 300))

        let gids = try db.getAllDownloads().map { $0.gid }
        #expect(gids == [1, 2, 3])
    }

    /// 用户拖动后的显示顺序会被持久化并在读取时生效；同时 date（下载顺序）保持不变。
    @Test func downloadsPersistManualDisplayOrder() throws {
        let db = try EhDatabase.makeInMemoryForTesting()

        try db.insertDownload(Self.makeRecord(gid: 1, date: 100, sortOrder: 0))
        try db.insertDownload(Self.makeRecord(gid: 2, date: 200, sortOrder: 1))
        try db.insertDownload(Self.makeRecord(gid: 3, date: 300, sortOrder: 2))

        // 模拟把 gid 3 拖到最前
        try db.setDownloadSortOrders([3, 1, 2])

        let gids = try db.getAllDownloads().map { $0.gid }
        #expect(gids == [3, 1, 2])

        // 下载顺序（date 升序）不受拖动影响 —— 仍然是 1, 2, 3
        let byDate = try db.getAllDownloads().sorted { $0.date < $1.date }.map { $0.gid }
        #expect(byDate == [1, 2, 3])
    }

    /// 新增下载默认排在最后：sortOrder 取「当前最大值 + 1」，date 也最新。
    @Test func newlyAddedDownloadGoesLast() throws {
        let db = try EhDatabase.makeInMemoryForTesting()

        try db.insertDownload(Self.makeRecord(gid: 1, date: 100, sortOrder: 0))
        try db.insertDownload(Self.makeRecord(gid: 2, date: 200, sortOrder: 1))

        // 拖动后顺序变成 2,1
        try db.setDownloadSortOrders([2, 1])

        // 新加入 gid 3：sortOrder = max(0,1) + 1 = 2
        let nextSortOrder = try db.getAllDownloads().map { $0.sortOrder }.max().map { $0 + 1 } ?? 0
        try db.insertDownload(Self.makeRecord(gid: 3, date: 300, sortOrder: nextSortOrder))

        let gids = try db.getAllDownloads().map { $0.gid }
        #expect(gids == [2, 1, 3])
    }
}
