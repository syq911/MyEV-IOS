//
//  NaturalSort.swift
//  ehviewer apple
//
//  自然排序 —— 给「文件名里带数字」的场景用。
//
//  为什么必须自定义：字符串比较会把 `10.jpg` 排到 `2.jpg` 前面，
//  而漫画包里的页序恰恰就是 `1.jpg … 10.jpg … 100.jpg` 这种。
//  系统 API 里没有「数字感知排序」（Finder 那种效果需要自己实现）。
//
//  规则（与 Finder / Windows 资源管理器一致）：
//  - 连续的数字按**数值**比较：2 < 10 < 100
//  - 数字段之外的字符按大小写不敏感比较，相等时再用原串定序（保证稳定）
//  - 数值相等时位数少的在前：`1` < `01`（避免 `01` 与 `1` 互相比不出来）
//  - 纯数字段可以任意长，不转换成 Int（避免超长文件名溢出）
//

import Foundation

enum NaturalSort {

    /// 自然序比较：`lhs` 是否应排在 `rhs` 之前
    static func isOrderedBefore(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    /// 自然序比较
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = Array(lhs)
        let right = Array(rhs)
        var i = 0
        var j = 0

        while i < left.count && j < right.count {
            let lc = left[i]
            let rc = right[j]

            if lc.isNumber && rc.isNumber {
                var li = i
                while li < left.count && left[li].isNumber { li += 1 }
                var rj = j
                while rj < right.count && right[rj].isNumber { rj += 1 }

                let leftDigits = left[i..<li]
                let rightDigits = right[j..<rj]
                let digitOrder = compareDigits(leftDigits, rightDigits)
                if digitOrder != .orderedSame { return digitOrder }

                i = li
                j = rj
                continue
            }

            // 非数字：大小写不敏感比较
            let lo = String(lc).lowercased()
            let ro = String(rc).lowercased()
            if lo != ro {
                return lo < ro ? .orderedAscending : .orderedDescending
            }
            i += 1
            j += 1
        }

        if i < left.count { return .orderedDescending }
        if j < right.count { return .orderedAscending }

        // 忽略大小写后完全相等 → 用原串打破平局，保证排序结果是确定的
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    /// 比较两段数字（都是纯数字）
    ///
    /// 先去掉前导零再比长度、比字典序，全程不转 Int ——
    /// `99999999999999999999.jpg` 这种超长数字也不会溢出。
    private static func compareDigits(_ lhs: ArraySlice<Character>, _ rhs: ArraySlice<Character>) -> ComparisonResult {
        let l = lhs.drop { $0 == "0" }
        let r = rhs.drop { $0 == "0" }

        if l.count != r.count {
            return l.count < r.count ? .orderedAscending : .orderedDescending
        }
        if l != r {
            return l.lexicographicallyPrecedes(r) ? .orderedAscending : .orderedDescending
        }
        // 数值相等：位数少的（前导零少的）排前面
        if lhs.count != rhs.count {
            return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    /// 对字符串数组做自然排序
    static func sorted(_ names: [String]) -> [String] {
        names.sorted(by: isOrderedBefore)
    }
}
