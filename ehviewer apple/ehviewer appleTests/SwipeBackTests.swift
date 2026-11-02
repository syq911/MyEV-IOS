//
//  SwipeBackTests.swift
//  ehviewer appleTests
//
//  全屏右滑返回的判定规则。
//
//  手势本身没法在单元测试里跑（要真机/模拟器的手 EventArgs），但「什么算一次返回」
//  是可以脱离 UIKit 断言的——上一版之所以是「完全没效果」，恰恰是因为判定逻辑
//  埋在 @objc 回调里、没有任何东西能断言它。
//

#if os(iOS)
import Testing
import CoreGraphics
@testable import ehviewer_apple

struct SwipeBackPolicyTests {

    private let policy = SwipeBackPolicy()

    // MARK: 是否开始跟踪

    @Test func rightSwipeStartsTracking() {
        #expect(policy.shouldBegin(dx: 20, dy: 4))
    }

    @Test func verticalDragIsIgnored() {
        // 纵向滚动页面不该被当成返回
        #expect(!policy.shouldBegin(dx: 10, dy: 30))
        #expect(!policy.shouldBegin(dx: 30, dy: 30))
    }

    @Test func leftSwipeIsIgnored() {
        #expect(!policy.shouldBegin(dx: -30, dy: 2))
    }

    @Test func tinyMovementIsIgnored() {
        // 几乎没动就不算拖动（真正的门槛是横纵比与提交距离）
        #expect(!policy.shouldBegin(dx: 0, dy: 0))
        #expect(!policy.shouldBegin(dx: 2, dy: 0))
        #expect(policy.shouldBegin(dx: 3, dy: 0), "达到起始距离应当开始")
    }

    @Test func diagonalDragNeedsHorizontalDominance() {
        // 横向必须是纵向的 1.5 倍以上：20 对 14 不够（需要 > 21），20 对 10 够
        #expect(!policy.shouldBegin(dx: 20, dy: 14))
        #expect(policy.shouldBegin(dx: 20, dy: 10))
    }

    // MARK: 是否提交返回

    @Test func longDragCommits() {
        #expect(policy.shouldCommit(dx: 120, velocityX: 0))
        #expect(policy.shouldCommit(dx: 76, velocityX: 0), "达到提交距离即提交")
    }

    @Test func shortSlowDragCancels() {
        #expect(!policy.shouldCommit(dx: 40, velocityX: 120))
        #expect(!policy.shouldCommit(dx: 0, velocityX: 0))
    }

    @Test func quickFlickCommits() {
        // 位移不大但速度够快，用户意图明确
        #expect(policy.shouldCommit(dx: 30, velocityX: 900))
    }

    @Test func flickNeedsMinimumDistance() {
        // 速度再快，几乎没有位移也不能算返回（否则轻扫会误退出）
        #expect(!policy.shouldCommit(dx: 5, velocityX: 2000))
    }

    @Test func slowFlickDoesNotCommit() {
        #expect(!policy.shouldCommit(dx: 60, velocityX: 100))
    }

    // MARK: 模态（阅读器）只认左边缘

    @Test func modalStartsOnlyFromLeftEdge() {
        #expect(policy.modalAllowsStart(atX: 0))
        #expect(policy.modalAllowsStart(atX: 24))
        #expect(!policy.modalAllowsStart(atX: 25))
        // 屏幕中间起手 → 让位给翻页手势
        #expect(!policy.modalAllowsStart(atX: 200))
    }

    @Test func modalEdgeWidthIsSmallEnoughToNotBlockPaging() {
        // 24pt 足够窄，覆盖不到阅读区的主要翻页区域
        #expect(policy.modalEdgeWidth <= 32)
    }
}

#endif
