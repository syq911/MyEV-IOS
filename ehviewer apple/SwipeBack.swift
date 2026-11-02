//
//  SwipeBack.swift
//  ehviewer apple
//
//  全屏右滑返回（知乎式）：从页面任意空白处右滑都能退回上一级。
//
//  为什么不是「加一个手势然后调私有方法」：
//  1.4.21 第一版就是这么做的（swizzle + `handleNavigationTransition:`），
//  在真机上完全没反应——私有 selector 在新系统上找不到目标就静默失败，
//  这类实现没有任何可观测的失败信号，只能靠猜。这里换成全部公开 API：
//
//  · 导航栈里的页面：自己做 `UINavigationControllerDelegate`，用
//    `UIPercentDrivenInteractiveTransition` 驱动**系统默认**的 pop 转场。
//    所以跟手、松手回弹、完成阈值、上一页的推入动画全部是系统原生的，
//    观感和系统返回完全一致，也不需要自己写动画器。
//  · 全屏模态（阅读器用 fullScreenCover 呈现，根本不在导航栈里）：
//    模态没有可用的交互式转场，改为直接平移模态视图，越过阈值后
//    `dismiss(animated: false)` 收尾——这样退出方向是「向右」，而不是
//    系统模态默认的「向下」。
//
//  手势挂在 window 上，所以是全局的：不管当前是哪个页面、哪一层，
//  也不需要每个视图手动加修饰符。
//

#if os(iOS)
import UIKit
import SwiftUI
import EhModels

// MARK: - 判定规则（纯逻辑，单元测试覆盖）

/// 「这次拖动算不算返回」的全部判断都收在这里。
///
/// 抽成不依赖 UIKit 的结构体是为了能写测试：手势逻辑一旦写在
/// `@objc` 回调里就只能靠人肉在真机上试，而这正是上一版翻车的地方。
struct SwipeBackPolicy: Equatable {
    /// 判定「横向意图」时，横向位移必须大于纵向位移的这个倍数
    var horizontalRatio: CGFloat = 1.5
    /// 识别所需的最小横向位移。
    ///
    /// 取 3 而不是 8：`gestureRecognizerShouldBegin` 是 UIKit 在「它认为该开始了」时
    /// 才回调的（此时位移通常已有 8~10pt），但这个时机不保证；
    /// 一旦这里返回 false，本次触摸序列的手势就直接失败、无法重来，
    /// 表现就是「有的滑动有反应、有的没反应」。真正的门槛交给
    /// 横纵比与提交距离，这里只负责过滤掉几乎没动的情况。
    var beginDistance: CGFloat = 3
    /// 松手时判定「确实要返回」的位移
    var commitDistance: CGFloat = 76
    /// 快速轻扫：速度够快时位移可以小一些
    var flickVelocity: CGFloat = 520
    var flickMinDistance: CGFloat = 18
    /// 模态（阅读器）只认左边缘，避免和翻页手势抢
    var modalEdgeWidth: CGFloat = 24

    /// 是否应该开始跟踪这次拖动
    func shouldBegin(dx: CGFloat, dy: CGFloat) -> Bool {
        guard dx >= beginDistance else { return false }
        return dx > abs(dy) * horizontalRatio
    }

    /// 松手时是否提交（返回上一级）
    func shouldCommit(dx: CGFloat, velocityX: CGFloat) -> Bool {
        if dx >= commitDistance { return true }
        return velocityX >= flickVelocity && dx >= flickMinDistance
    }

    /// 模态是否允许从该横坐标起手
    func modalAllowsStart(atX x: CGFloat) -> Bool {
        x <= modalEdgeWidth
    }
}

// MARK: - 交互式 pop 驱动

/// 接管导航控制器的转场，用系统的默认动画做「跟手」的 pop。
///
/// 只实现 `interactionControllerFor`，不提供 `animationControllerFor`：
/// 动画仍然交给 UIKit 默认实现，我们只负责把手指位移换算成转场进度。
/// 这样即使某一版系统不再支持「默认动画 + 自定义交互控制器」的组合，
/// 退化的结果也只是「滑动立即触发返回」，不会变成没反应。
final class InteractivePopDriver: NSObject, UINavigationControllerDelegate {

    private var interaction: UIPercentDrivenInteractiveTransition?
    private weak var nav: UINavigationController?
    /// 接管 delegate 之前的那一个（SwiftUI 可能设过），未实现的方法转回去
    private weak var originalDelegate: UINavigationControllerDelegate?

    private(set) var isDriving = false

    /// 把导航控制器的 delegate 换成自己（保留原来的，其余方法原样转发）
    func attach(to nav: UINavigationController) {
        self.nav = nav
        if nav.delegate !== self {
            originalDelegate = nav.delegate
            nav.delegate = self
        }
    }

    /// 开始一次交互式 pop。调用后 UIKit 会回调 `interactionControllerFor`。
    ///
    /// 导航控制器必须由调用方传入：driver 自己持有的 `nav` 是靠 `attach` 赋值的，
    /// 而 `attach` 又在 `begin` 里调用——写成 `guard let nav`（读自己）就永远进不来。
    func begin(on nav: UINavigationController) {
        guard !isDriving, nav.viewControllers.count > 1 else { return }
        // 必须先把 delegate 换成自己，否则 UIKit 不会来问交互控制器，
        // 结果就是「滑动直接整段弹回去」而不是跟手
        attach(to: nav)
        isDriving = true
        let controller = UIPercentDrivenInteractiveTransition()
        controller.completionCurve = .easeOut
        interaction = controller
        nav.popViewController(animated: true)
    }

    func update(progress: CGFloat) {
        guard isDriving else { return }
        interaction?.update(min(max(progress, 0), 0.999))
    }

    func finish() {
        guard isDriving else { return }
        isDriving = false
        interaction?.finish()
        interaction = nil
    }

    func cancel() {
        guard isDriving else { return }
        isDriving = false
        interaction?.cancel()
        interaction = nil
    }

    // MARK: UINavigationControllerDelegate

    func navigationController(
        _ navigationController: UINavigationController,
        interactionControllerFor animationController: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        // 只有我们自己发起的那次 pop 才接管；push / 系统返回返回 nil，走默认动画
        guard isDriving else { return nil }
        return interaction
    }

    // 把没实现的 delegate 方法转给原来的实现，避免顶掉 SwiftUI 自己的逻辑
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return originalDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if originalDelegate?.responds(to: aSelector) == true { return originalDelegate }
        return super.forwardingTarget(for: aSelector)
    }
}

// MARK: - 全局协调器

/// 挂在 window 上的全屏 pan，负责判断「这次右滑该返回哪一层」并执行。
final class SwipeBackCoordinator: NSObject, UIGestureRecognizerDelegate {

    static let shared = SwipeBackCoordinator()

    let policy = SwipeBackPolicy()

    private let popDriver = InteractivePopDriver()
    private weak var window: UIWindow?
    private weak var pan: UIPanGestureRecognizer?

    /// 阅读器是否登记为「可右滑关闭的全屏模态」。
    ///
    /// 不用「必须同时拿到控制器」的方式：阅读器出现时 window 可能还没被安装，
    /// 那样会登记失败、右滑完全没反应。这里只记一个开关，真正用的时候
    /// 再去窗口上找最上层的模态——找不到（或已经被关掉）就自动退化成普通页面逻辑，
    /// 不会像上一版的全局布尔那样把整个 App 卡在「只认边缘」。
    private var readerRegistered = false

    private enum Target {
        case navigation(UINavigationController)
        case modal(UIViewController)
    }

    private var target: Target?
    private var startX: CGFloat = 0
    private var didBeginPop = false
    private var isFollowingModal = false

    // MARK: 安装

    func install(on window: UIWindow) {
        // 已经挂在同一个 window 上就不重复挂（多个宿主视图都会调用到这里）
        if let pan, pan.view === window { return }
        if let old = pan { old.view?.removeGestureRecognizer(old) }
        self.window = window

        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.delegate = self
        recognizer.maximumNumberOfTouches = 1
        // 不吞触摸：识别与否都不能影响页面本身的点击/滚动
        recognizer.cancelsTouchesInView = false
        window.addGestureRecognizer(recognizer)
        pan = recognizer
        diag("SwipeBack: 已安装到 window")
    }

    // MARK: 模态登记

    /// 阅读器出现：登记为「可右滑关闭的全屏模态」
    func readerDidAppear() {
        readerRegistered = true
        diag("SwipeBack: 阅读器已登记")
    }

    /// 阅读器消失：解除登记
    func readerDidDisappear() {
        readerRegistered = false
        diag("SwipeBack: 阅读器已注销")
    }

    // MARK: 手势

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let window else { return }
        let translation = gesture.translation(in: window)
        let dx = max(0, translation.x)

        switch gesture.state {
        case .began:
            // 目标已在 gestureRecognizerShouldBegin 里解析好（那是唯一能拦住手势的时机），
            // 这里只做兜底
            if target == nil {
                startX = gesture.location(in: window).x - translation.x
                target = resolveTarget(in: window, at: gesture.location(in: window))
                logTarget()
            }
            didBeginPop = false
            isFollowingModal = false

        case .changed:
            guard let target else { return }
            switch target {
            case .navigation(let nav):
                // 先等一小段位移确认「真的要横滑」，再接管转场，
                // 否则轻微的水平抖动也会触发返回
                if !didBeginPop {
                    guard policy.shouldBegin(dx: dx, dy: translation.y) else { return }
                    didBeginPop = true
                    popDriver.begin(on: nav)
                }
                let width = max(window.bounds.width, 1)
                popDriver.update(progress: dx / width)

            case .modal(let controller):
                guard policy.shouldBegin(dx: dx, dy: translation.y),
                      policy.modalAllowsStart(atX: startX) else { return }
                isFollowingModal = true
                controller.view.transform = CGAffineTransform(translationX: dx, y: 0)
            }

        case .ended:
            let velocity = gesture.velocity(in: window).x
            commit(dx: dx, velocityX: velocity)

        case .cancelled, .failed:
            rollback()

        default:
            break
        }
    }

    private func commit(dx: CGFloat, velocityX: CGFloat) {
        guard let target else { return }
        let shouldCommit = policy.shouldCommit(dx: dx, velocityX: velocityX)

        switch target {
        case .navigation(_):
            guard didBeginPop else { rollback(); return }
            if shouldCommit {
                diag("SwipeBack: 提交返回（导航），dx=\(Int(dx)) v=\(Int(velocityX))")
                popDriver.finish()
            } else {
                diag("SwipeBack: 取消（导航），dx=\(Int(dx)) v=\(Int(velocityX))")
                popDriver.cancel()
            }

        case .modal(let controller):
            guard isFollowingModal else { return }
            if shouldCommit {
                diag("SwipeBack: 提交返回（模态），dx=\(Int(dx)) v=\(Int(velocityX))")
                finishModal(controller)
            } else {
                diag("SwipeBack: 取消（模态），dx=\(Int(dx)) v=\(Int(velocityX))")
                UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) {
                    controller.view.transform = .identity
                }
            }
        }
        target = nil
    }

    private func rollback() {
        guard let target else { return }
        switch target {
        case .navigation(_):
            if didBeginPop { popDriver.cancel() }
        case .modal(let controller):
            if isFollowingModal {
                UIView.animate(withDuration: 0.2) { controller.view.transform = .identity }
            }
        }
        target = nil
    }

    /// 模态向右滑出后无动画地关掉，避免系统默认的「向下」退出动画
    private func finishModal(_ controller: UIViewController) {
        let width = controller.view.bounds.width
        UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut]) {
            controller.view.transform = CGAffineTransform(translationX: width, y: 0)
        } completion: { _ in
            controller.dismiss(animated: false)
            controller.view.transform = .identity
        }
    }

    // MARK: 目标解析

    private func resolveTarget(in window: UIWindow, at point: CGPoint) -> Target? {
        // ① 阅读器这类全屏模态：它在窗口最上层，必须单独处理。
        //    这里用「窗口上是否真有被 present 的控制器」做校验，
        //    登记漏掉注销时不会误伤普通页面
        if readerRegistered,
           let root = window.rootViewController,
           let top = topmostPresented(from: root),
           top !== root {
            return .modal(top)
        }

        // ② 普通页面：找出触摸点所在的导航控制器
        guard let hit = window.hitTest(point, with: nil) else { return nil }
        // 从滑杆/分段控件上起手时不当返回（阅读器进度条、排行榜周期切换）
        if isExcludedControl(hit) { return nil }
        var responder: UIResponder? = hit
        while let current = responder {
            if let nav = current as? UINavigationController, nav.viewControllers.count > 1 {
                return .navigation(nav)
            }
            responder = current.next
        }
        return nil
    }

    private func topmostPresented(from root: UIViewController?) -> UIViewController? {
        var current = root
        while let presented = current?.presentedViewController { current = presented }
        return current
    }

    private func isExcludedControl(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let v = current {
            if v is UISlider || v is UISegmentedControl || v is UIDatePicker
                || v is UIPageControl || v is UISwitch { return true }
            current = v.superview
        }
        return false
    }

    private func logTarget() {
        guard let target else {
            diag("SwipeBack: 目标=无（不可返回）")
            return
        }
        switch target {
        case .navigation(let nav):
            diag("SwipeBack: 目标=导航栈(\(nav.viewControllers.count) 层)")
        case .modal(_):
            diag("SwipeBack: 目标=全屏模态")
        }
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === pan, let window else { return false }
        let translation = gesture.translation(in: window)
        let dx = translation.x
        let dy = translation.y
        // 只认「向右的横滑」，纵向滚动、左滑一律放行给页面自己
        guard dx > 0, dx > abs(dy) * policy.horizontalRatio else { return false }

        // 目标必须在这里解析：`shouldBegin` 是手势放行的唯一闸口，
        // 而状态 `.began` 是它**之后**才送达的——上一版把解析写在 `.began` 里，
        // 于是这里永远读到 nil、手势从不开始，表现就是「完全没效果」。
        let point = gesture.location(in: window)
        guard let resolved = resolveTarget(in: window, at: point) else {
            target = nil
            return false
        }
        target = resolved
        startX = point.x - dx
        logTarget()
        return true
    }

    /// 不与其他手势抢：横向返回一旦成立就独占；否则全部让给别人
    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}

// MARK: - SwiftUI 接入

private struct SwipeBackInstallerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { SwipeBackHost() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class SwipeBackHost: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installIfPossible()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            installIfPossible()
        }

        private func installIfPossible() {
            guard let window = view.window else { return }
            SwipeBackCoordinator.shared.install(on: window)
        }
    }
}

extension View {
    /// 在根视图上挂一次即全局生效（手势挂在 window 上，与页面层级无关）
    func installSwipeBack() -> some View {
        background(SwipeBackInstallerView().frame(width: 0, height: 0))
    }
}
#endif
