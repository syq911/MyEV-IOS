//
//  AppDelegate.swift
//  ehviewer apple
//
//  iOS App Delegate — 处理后台下载回调
//

#if os(iOS)
import UIKit
import EhSettings
import EhDownload
import EhModels

class AppDelegate: NSObject, UIApplicationDelegate {

    /// 后台下载完成回调
    /// URLSession background 的传输由系统进程托管，App 被唤醒后必须把 completionHandler
    /// 交还给会话，否则系统会认为 App 未处理事件（后续不再唤醒，甚至杀进程）。
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        diag("handleEventsForBackgroundURLSession: \(identifier)")
        BackgroundDownloadBridge.handleBackgroundSessionCompletion(completionHandler)
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        diag("didFinishLaunching: 进入")

        // 注册后台任务
        BackgroundDownloadManager.shared.registerBackgroundTasks()
        diag("didFinishLaunching: registerBackgroundTasks 返回")

        // ★ 冷启动对账 (M3):
        //   1. 清掉上一条进程（被强杀）残留的孤儿后台任务 —— 带本传输层标记但已无等待者；
        //   2. 恢复等待队列 —— 磁盘 .ehviewer 记录会跳过已下好的页，缺哪页补哪页。
        //   系统在强杀 App 时会取消后台传输（Apple 明确行为），所以续传必须靠这一步。
        BackgroundDownloadBridge.reconcileOrphanTasks()
        diag("didFinishLaunching: reconcileOrphanTasks 返回")

        Task {
            diag("launchResume: 即将 resumeAllWaiting")
            await DownloadManager.shared.resumeAllWaiting()
            diag("launchResume: resumeAllWaiting 返回")
        }
        diag("didFinishLaunching: 返回 true")
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // 进入后台时同时提交「下载处理」与「后台刷新」两类系统任务：
        // 机会性调度不保证执行，但两类都登记能尽量多争取后台运行窗口。
        BackgroundDownloadManager.shared.scheduleBackgroundDownload()
        BackgroundDownloadManager.shared.scheduleBackgroundRefresh()
        diag("didEnterBackground: 已提交 BGProcessingTask / BGAppRefreshTask")
    }

    /// 回到前台时的兜底：若队列里有等待中的任务但当前没有活跃任务，立即重新推进。
    /// 覆盖「App 被短暂挂起后自行恢复、未走冷启动」这条路径；
    /// 冷启动时 resumeAllWaiting 已处理过，此处是幂等的二次保险。
    func applicationDidBecomeActive(_ application: UIApplication) {
        diag("didBecomeActive: 兜底 resumeAllWaiting")
        Task { await DownloadManager.shared.resumeAllWaiting() }
    }

    /// 屏幕旋转控制 (对齐 Android Settings.KEY_SCREEN_ROTATION)
    /// 0=跟随系统, 1=竖屏锁定, 2=横屏锁定
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        switch AppSettings.shared.screenRotation {
        case 1:
            return .portrait
        case 2:
            return .landscape
        default:
            // 跟随系统: 允许全部方向 (iPhone 不含倒置竖屏)
            return .allButUpsideDown
        }
    }
}
#endif
