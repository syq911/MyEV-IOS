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

class AppDelegate: NSObject, UIApplicationDelegate {

    /// 后台下载完成回调
    /// URLSession background 的传输由系统进程托管，App 被唤醒后必须把 completionHandler
    /// 交还给会话，否则系统会认为 App 未处理事件（后续不再唤醒，甚至杀进程）。
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundDownloadBridge.handleBackgroundSessionCompletion(completionHandler)
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 注册后台任务
        BackgroundDownloadManager.shared.registerBackgroundTasks()

        // ★ 冷启动对账 (M3):
        //   1. 清掉上一条进程（被强杀）残留的孤儿后台任务 —— 带本传输层标记但已无等待者；
        //   2. 恢复等待队列 —— 磁盘 .ehviewer 记录会跳过已下好的页，缺哪页补哪页。
        //   系统在强杀 App 时会取消后台传输（Apple 明确行为），所以续传必须靠这一步。
        BackgroundDownloadBridge.reconcileOrphanTasks()
        Task {
            await DownloadManager.shared.resumeAllWaiting()
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // 调度后台下载任务
        BackgroundDownloadManager.shared.scheduleBackgroundDownload()
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
