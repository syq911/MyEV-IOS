import Foundation

// MARK: - DownloadOrdering
//
// 下载队列的排序规则（纯逻辑，便于单元测试）。
//
// 设计要点（对应下载排序 bug）：
//   - **下载顺序** 永远按「加入时间」`addedDate`（先加入先下载），与列表里被
//     用户拖动后的展示顺序无关。
//   - **展示顺序** 由队列数组下标决定，可以被用户长按拖动改变并持久化
//     （`sortOrder`），但绝不参与下载调度。

public enum DownloadOrdering {

    /// 下一个应当下载的任务下标：在所有 `stateWait` 中取「加入时间最早」的一个。
    ///
    /// - 与数组下标顺序无关（数组下标 = 用户看到的展示顺序，可被拖动改变）。
    /// - 加入时间相同时保留靠前的那个（older index），保证顺序稳定。
    /// - 没有等待中的任务时返回 `nil`。
    public static func nextWaitingIndex(in tasks: [DownloadTask]) -> Int? {
        var best: Int?
        var bestDate = Date.distantFuture
        for (index, task) in tasks.enumerated() where task.state == DownloadManager.stateWait {
            if task.addedDate < bestDate {
                best = index
                bestDate = task.addedDate
            }
        }
        return best
    }

    /// 把一个数组中的元素从 `fromOffsets` 移动到 `toOffset`（等价于 SwiftUI
    /// `onMove` / `MutableCollection.move(fromOffsets:toOffset:)` 的语义）。
    ///
    /// 这里自己实现是因为 EhDownload 包不依赖 SwiftUI。
    public static func moving<T>(_ items: [T], fromOffsets: IndexSet, toOffset: Int) -> [T] {
        guard !fromOffsets.isEmpty else { return items }

        let sortedSource = fromOffsets.sorted()
        let movingItems = sortedSource.map { items[$0] }

        var destination = toOffset
        for index in sortedSource where index < toOffset {
            destination -= 1
        }

        var result = items
        for index in sortedSource.sorted(by: >) {
            result.remove(at: index)
        }
        destination = max(0, min(destination, result.count))
        result.insert(contentsOf: movingItems, at: destination)
        return result
    }

    /// 把「列表里显示的条目」的拖动结果合并回整条下载队列。
    ///
    /// - `visibleGids`：当前列表实际展示的 gid 顺序（可能是按标签/状态/搜索过滤后的子集）。
    /// - 拖动只改变这些 gid 之间的相对顺序，未显示的条目保持原位，
    ///   因此过滤视图下的拖动也不会打乱被隐藏的条目。
    public static func applyingMove(to tasks: [DownloadTask],
                                    visibleGids: [Int64],
                                    fromOffsets: IndexSet,
                                    toOffset: Int) -> [DownloadTask] {
        let newVisible = moving(visibleGids, fromOffsets: fromOffsets, toOffset: toOffset)

        var byGid: [Int64: DownloadTask] = [:]
        byGid.reserveCapacity(tasks.count)
        for task in tasks { byGid[task.gallery.gid] = task }

        let visibleSet = Set(visibleGids)
        var iterator = newVisible.makeIterator()
        var result: [DownloadTask] = []
        result.reserveCapacity(tasks.count)

        for task in tasks {
            if visibleSet.contains(task.gallery.gid) {
                if let gid = iterator.next(), let moved = byGid[gid] {
                    result.append(moved)
                }
            } else {
                result.append(task)
            }
        }
        return result
    }
}
