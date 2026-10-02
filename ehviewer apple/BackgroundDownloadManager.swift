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
#if canImport(os)
import os
#endif

/// BGProcessingTask 诊断日志 —— Console.app 连 iPhone 过滤 subsystem 可见
private let bgTaskLog = Logger(subsystem: "Stellatrix.ehviewer-apple", category: "BGTask")

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
    /// BGTask 完成闸门 —— expirationHandler 与正常收尾可能先后来到，
    /// 而 `setTaskCompleted` 只允许调用一次，这里做一次性保护。
    private final class BGTaskGate: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let task: BGTask

        init(task: BGTask) { self.task = task }

        var isFinished: Bool {
            lock.lock(); defer { lock.unlock() }
            return finished
        }

        func finish(success: Bool) {
            lock.lock()
            let alreadyFinished = finished
            finished = true
            lock.unlock()
            guard !alreadyFinished else { return }
            task.setTaskCompleted(success: success)
        }
    }

    /// BGProcessingTask 是**加速器**而非地基：
    /// 系统机会性调度（用户开启「后台 App 刷新」会明显提升概率），每次给几分钟类前台时间。
    /// 即使它一次都不来，后台会话（nsurlsessiond）+ 系统唤醒循环仍会让下载继续。
    private func handleBackgroundDownload(task: BGProcessingTask) {
        scheduleBackgroundDownload() // 重新调度下次

        let gate = BGTaskGate(task: task)

        // ★ 到期只结束本任务，绝不暂停下载：
        //   以前这里调 pauseActiveIfNeeded()，会把在途传输全部取消并刷成「等待中」。
        task.expirationHandler = {
            bgTaskLog.info("BGProcessingTask 到期，交还给后台会话接力")
            gate.finish(success: false)
        }

        bgTaskLog.info("BGProcessingTask 启动，持有运行直到队列空闲")

        Task {
            // 恢复下载队列中等待的任务
            await DownloadManager.shared.resumeAllWaiting()

            // 持有式运行：BGProcessingTask 每次被调度有几分钟时间，
            // 以前只 sleep 2 秒就结束，等于白拿的运行时间全浪费。
            while !Task.isCancelled && !gate.isFinished {
                let tasks = await DownloadManager.shared.getAllTasks()
                let busy = tasks.contains {
                    $0.state == DownloadManager.stateDownload || $0.state == DownloadManager.stateWait
                }
                if !busy { break }
                try? await Task.sleep(for: .seconds(2))
            }

            bgTaskLog.info("BGProcessingTask 收尾（队列空闲或到期）")
            gate.finish(success: true)
        }
    }

    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        scheduleBackgroundRefresh() // 重新调度

        let gate = BGTaskGate(task: task)

        task.expirationHandler = {
            gate.finish(success: false)
        }

        Task {
            gate.finish(success: true)
        }
    }
    #endif
}