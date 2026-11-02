//
//  FullScreenSwipeBack.swift
//  ehviewer apple
//
//  全屏滑动返回（知乎式：从任意空白处右滑都能回上一级）。
//
//  系统自带的 `interactivePopGestureRecognizer` 只在屏幕左边缘 20pt 内生效，
//  这是 UIScreenEdgePanGestureRecognizer 的硬限制，delegate 改不了触发区域。
//
//  做法：在导航控制器视图上再挂一个全屏 pan，把它交给系统手势自己的 target
//  处理（`handleNavigationTransition:`）。这样跟手动画、完成/取消阈值、
//  手势取消后的回弹，全部沿用系统实现，不需要接管 UINavigationControllerDelegate
//  —— 接管转场会和 SwiftUI 的 NavigationStack 抢控制权，反而更容易出问题。
//
//  两个配套问题一起解决：
//  1. 导航栏隐藏时（阅读器全屏），系统会禁用边缘手势。把 delegate 换成自己，
//     只要栈里还能 pop 就允许开始。
//  2. 阅读器里横滑是翻页，全屏返回会抢走翻页。进入阅读器时把
//     `requiresEdgeStart` 置为 true，只认左边缘 20pt 起手。
//

#if os(iOS)
import UIKit
import ObjectiveC

@MainActor
final class FullScreenSwipeBack: NSObject, UIGestureRecognizerDelegate {

    static let shared = FullScreenSwipeBack()

    /// 为 true 时只在左边缘 20pt 内起手才算返回（阅读器用）。
    /// 阅读器里横向滑动是翻页，全屏返回必须让位。
    ///
    /// 用 `nonisolated(unsafe)` 而不是 `@MainActor`：阅读器的 setup/cleanup 是
    /// SwiftUI 视图方法，不保证静态隔离；一个布尔开关的读写竞争可以忽略，
    /// 但为了省掉跨隔离的 `Task` 跳转（会让标志晚一帧生效），这里直接放开。
    nonisolated(unsafe) var requiresEdgeStart = false

    /// 已经装过的导航控制器（避免重复挂手势）
    private let installed = NSHashTable<UINavigationController>.weakObjects()

    /// 左边缘判定阈值（pt）
    private static let edgeWidth: CGFloat = 20

    // MARK: - 安装

    /// 在 App 启动时调用一次，之后每个导航控制器首次出现时自动挂载。
    static func installGlobally() {
        swizzleViewDidAppear()
    }

    private static func swizzleViewDidAppear() {
        let original = #selector(UINavigationController.viewDidAppear(_:))
        let swizzled = #selector(UINavigationController.fsb_viewDidAppear(_:))
        guard let m1 = class_getInstanceMethod(UINavigationController.self, original),
              let m2 = class_getInstanceMethod(UINavigationController.self, swizzled) else { return }
        method_exchangeImplementations(m1, m2)
    }

    func install(on nav: UINavigationController) {
        guard !installed.contains(nav) else { return }
        installed.add(nav)

        // ① 导航栏隐藏时也让系统边缘手势可用
        nav.interactivePopGestureRecognizer?.delegate = self

        // ② 全屏 pan
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        nav.view.addGestureRecognizer(pan)
    }

    // MARK: - 手势

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let nav = navFor(pan), nav.viewControllers.count > 1 else { return }
        forwardToSystemPop(nav, gesture: pan)
    }

    /// 从手势的视图反查所属导航控制器（pan 挂在 nav.view 上）
    private func navFor(_ gesture: UIGestureRecognizer) -> UINavigationController? {
        if let nav = gesture.view as? UINavigationController { return nav }
        return gesture.view?.next as? UINavigationController
    }

    /// 把自定义 pan 交给系统手势的 target，复用系统转场。
    ///
    /// 每次状态变化都要转交一次：系统的 target 是「按当前手势状态更新转场进度」，
    /// 不是「注册一次就持续跟踪」。少了这一步会出现「拖到一半没反应」。
    private func forwardToSystemPop(_ nav: UINavigationController, gesture: UIPanGestureRecognizer) {
        guard let system = nav.interactivePopGestureRecognizer else { return }
        let selector = NSSelectorFromString("handleNavigationTransition:")
        guard let targets = system.value(forKey: "targets") as? [NSObject] else { return }
        for target in targets where target.responds(to: selector) {
            _ = target.perform(selector, with: gesture)
            return
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let nav = navFor(gesture), nav.viewControllers.count > 1 else { return false }

        // 系统边缘手势：栈里能返回就允许。
        // 这一条修的是「导航栏隐藏后边缘手势失效」——系统的默认实现依赖导航栏状态。
        if gesture === nav.interactivePopGestureRecognizer {
            return true
        }

        guard let pan = gesture as? UIPanGestureRecognizer else { return true }

        // 只认横向右滑，避免和纵向滚动打架
        let velocity = pan.velocity(in: pan.view)
        guard velocity.x > 0, abs(velocity.x) > abs(velocity.y) else { return false }

        // 阅读器：只认左边缘，其余横滑留给翻页
        if requiresEdgeStart {
            return pan.location(in: pan.view).x <= Self.edgeWidth
        }
        return true
    }

    /// 不与其它手势同时识别：横向滚动列表里，返回手势一旦开始就该独占。
    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}

extension UINavigationController {
    /// 交换实现：每次导航控制器出现时挂一次全屏返回。
    @objc fileprivate func fsb_viewDidAppear(_ animated: Bool) {
        // 交换后这里调用的是原实现
        self.fsb_viewDidAppear(animated)
        FullScreenSwipeBack.shared.install(on: self)
    }
}
#endif
