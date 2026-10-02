//
//  BackgroundDownloadManager.swift
//  ehviewer apple
//
//  后台任务调度 — 只负责 BGTaskScheduler 的注册与调度。
//
//  说明:
//    这里曾经是一套自制的 "URLSession background 下载管理器"，但从未被接线（死代码），
//    且设计有问题（用 taskIdentifier 当 resumeData 的 key，进程重启即失效）。
//    1.4.0 起真正的后台传输由 EhBackgroundTransport (Packages/EhNetwork) 承担，
//    本文件只保留系统后台任务窗口的调度，供下载队列在后台被唤醒时推进。
//

import Foundation
import BackgroundTasks
import EhDownload

final class BackgroundDownloadManager: NSObject, @unchecked Sendable {
    static let shared = BackgroundDownloadManager()

    private let downloadTaskIdentifier = "Stellatrix.ehviewer-apple.download"
    private let refreshTaskIdentifier = "Stellatrix.ehviewer-apple.refresh"

    /// 防止重复注册后台任务
    private var isRegistered = false

    private override init() {
        super.init()
    }

    // MARK: - Background Task Registration

    /// 注册后台任务 (在 App 启动时调用, 仅注册一次)
    func registerBackgroundTasks() {
        guard !isRegistered else { return }
        isRegistered = true
        #if os(iOS) && !targetEnvironment(simulator)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: downloadTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else { return }
            self?.handleBackgroundDownload(task: processingTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            self?.handleBackgroundRefresh(task: refreshTask)
        }
        #endif
    }

    /// 调度后台下载任务
    func scheduleBackgroundDownload() {
        #if os(iOS) && !targetEnvironment(simulator)
        let request = BGProcessingTaskRequest(identifier: downloadTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            debugLog("Failed to schedule background download: \(error)")
        }
        #endif
    }

    /// 调度后台刷新任务
    func scheduleBackgroundRefresh() {
        #if os(iOS) && !targetEnvironment(simulator)
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15分钟后

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            debugLog("Failed to schedule background refresh: \(error)")
        }
        #endif
    }

    // MARK: - Task Handlers

    #if os(iOS) && !targetEnvironment(simulator)
    private func handleBackgroundDownload(task: BGProcessingTask) {
        scheduleBackgroundDownload() // 重新调度下次

        task.expirationHandler = {
            // BGProcessingTask 过期时, 暂停活跃下载 (保留 stateWait 以便恢复)
            Task {
                await DownloadManager.shared.pauseActiveIfNeeded()
            }
            task.setTaskCompleted(success: false)
        }

        // 恢复下载队列中等待的任务
        Task {
            await DownloadManager.shared.resumeAllWaiting()
            // 等待当前任务完成或被系统打断
            // BGProcessingTask 最多有几分钟的执行时间
            try? await Task.sleep(for: .seconds(2))
            task.setTaskCompleted(success: true)
        }
    }

    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        scheduleBackgroundRefresh() // 重新调度

        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        Task {
            task.setTaskCompleted(success: true)
        }
    }
    #endif
}