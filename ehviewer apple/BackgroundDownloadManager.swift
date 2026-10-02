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
import EhModels
#if canImport(os)
import os
#endif

/// BGProcessingTask 诊断日志 —— Console.app 连 iPhone 过滤 subsystem 可见
private let bgTaskLog = Logger(subsystem: "Stellatrix.ehviewer-apple", category: "BGTask")

final class BackgroundDownloadManager: NSObject, @unchecked Sendable {
    static let shared = BackgroundDownloadManager()

    private let downloadTaskIdentifier = "Stellatrix.ehviewer-apple.download"
    private let refreshTaskIdentifier = "Stellatrix.ehviewer-apple.refresh"
    /// iOS 26+ 持续处理任务标识 —— 用户点下载后即使切后台/锁屏也能继续跑
    private let continuedTaskIdentifier = "Stellatrix.ehviewer-apple.continued"

    /// 防止重复注册后台任务
    private var isRegistered = false

    // MARK: - 持续处理任务状态 (iOS 26+)

    private let continuedLock = NSLock()
    /// 当前是否有在跑的持续处理任务（同一 identifier 同时只允许一个）
    private var _continuedActive = false
    /// 进度监控任务：定期把下载进度喂给系统卡片，空闲时收尾
    private var _continuedMonitor: Task<Void, Never>?

    private override init() {
        super.init()
    }

    // MARK: - Background Task Registration

    /// 注册后台任务 (在 App 启动时调用, 仅注册一次)
    func registerBackgroundTasks() {
        guard !isRegistered else { return }
        isRegistered = true
        #if os(iOS) && !targetEnvironment(simulator)
        diag("BGTask: 开始注册 \(downloadTaskIdentifier) / \(refreshTaskIdentifier)")
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: downloadTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else { return }
            self?.handleBackgroundDownload(task: processingTask)
        }
        diag("BGTask: 已注册 \(downloadTaskIdentifier)")

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            self?.handleBackgroundRefresh(task: refreshTask)
        }
        diag("BGTask: 已注册 \(refreshTaskIdentifier)")

        // iOS 26+: 持续处理任务 —— 用户在前台点了下载后，即使把 App 切后台/锁屏，
        // 系统仍会给我们一段可运行时间（网络 + CPU 均可用），并在灵动岛/锁屏显示进度卡片。
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: continuedTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let continued = task as? BGContinuedProcessingTask else { return }
            self?.handleContinuedProcessing(task: continued)
        }
        diag("BGTask: 已注册 \(continuedTaskIdentifier)")
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

    /// 提交「持续处理任务」(iOS 26+)。**必须在用户主动操作时调用**（点下载 / 继续下载）。
    ///
    /// 与 BGProcessingTask 的区别：这个是**确定性**的后台运行窗口 —— 只要用户在系统卡片
    /// 上不取消，App 切后台/锁屏后仍可持续数分钟地跑下载流水线（网络 + CPU 都可用），
    /// 而不是依赖机会性调度。系统会在灵动岛/锁屏显示进度卡片，用户可随时取消。
    func submitContinuedProcessing(title: String, subtitle: String) {
        #if os(iOS) && !targetEnvironment(simulator)
        continuedLock.lock()
        let alreadyActive = _continuedActive
        continuedLock.unlock()
        guard !alreadyActive else { return }   // 同一 identifier 同时只允许一个实例

        let request = BGContinuedProcessingTaskRequest(
            identifier: continuedTaskIdentifier,
            title: title.isEmpty ? "下载中" : title,
            subtitle: subtitle
        )
        // 默认 .queue：系统忙时排队而不是直接失败
        do {
            try BGTaskScheduler.shared.submit(request)
            diag("BGContinued: 已提交请求 \(title)")
        } catch {
            debugLog("Failed to submit continued processing: \(error)")
            diag("BGContinued: 提交失败 \(error)")
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
        diag("BGTask: handleBackgroundDownload 启动")

        Task {
            // 恢复下载队列中等待的任务
            diag("BGTask: 即将 resumeAllWaiting")
            await DownloadManager.shared.resumeAllWaiting()
            diag("BGTask: resumeAllWaiting 返回")

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
            diag("BGTask: handleBackgroundDownload 收尾")
            gate.finish(success: true)
        }
    }

    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        scheduleBackgroundRefresh() // 重新调度
        diag("BGTask: handleBackgroundRefresh 启动")

        let gate = BGTaskGate(task: task)

        task.expirationHandler = {
            gate.finish(success: false)
        }

        Task {
            gate.finish(success: true)
        }
    }

    /// 持续处理任务的处理入口 (iOS 26+)。
    ///
    /// 拿到任务后：
    ///  1. 立刻推进下载队列（resumeAllWaiting）；
    ///  2. 挂一个 1 秒轮询的监控，把「已下载页数/总页数」喂给 task.progress，
    ///     这样系统卡片能显示真实进度（**进度长期不变的持续任务会被系统优先回收**）；
    ///  3. 队列空闲（无 下载中/等待中）时收尾并 setTaskCompleted。
    /// 用户点系统卡片上的取消、或系统资源紧张 → expirationHandler 触发，同样收尾。
    private func handleContinuedProcessing(task: BGContinuedProcessingTask) {
        bgTaskLog.info("BGContinuedProcessingTask 启动")
        diag("BGContinued: 启动")

        continuedLock.lock()
        _continuedActive = true
        continuedLock.unlock()

        let gate = BGTaskGate(task: task)

        task.expirationHandler = { [weak self] in
            // 下载本身不受影响：在途后台会话仍由 nsurlsessiond 托管，回到前台自动续传。
            bgTaskLog.info("BGContinuedProcessingTask 到期/取消")
            diag("BGContinued: 到期/取消")
            self?.endContinuedMonitor()
            gate.finish(success: false)
        }

        // 推进下载队列（冷启动 / 被挂起恢复都靠它）
        Task { await DownloadManager.shared.resumeAllWaiting() }

        let monitor = Task { [weak self] in
            var idleStreak = 0
            while !Task.isCancelled {
                if gate.isFinished { break }

                let tasks = await DownloadManager.shared.getAllTasks()
                if let active = tasks.first(where: {
                    $0.state == DownloadManager.stateDownload || $0.state == DownloadManager.stateWait
                }) {
                    idleStreak = 0
                    let total = max(1, active.gallery.pages)
                    let done = min(max(0, active.downloadedPages), total)
                    task.progress.totalUnitCount = Int64(total)
                    task.progress.completedUnitCount = Int64(done)
                    task.updateTitle(active.gallery.bestTitle, subtitle: "已下载 \(done)/\(total) 页")
                } else {
                    // 连续两次空闲才收尾，避免刚好落在两个画廊切换的瞬间
                    idleStreak += 1
                    if idleStreak >= 2 { break }
                }
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            bgTaskLog.info("BGContinuedProcessingTask 收尾（队列空闲）")
            diag("BGContinued: 收尾")
            gate.finish(success: true)
            self?.endContinuedMonitor()
        }

        continuedLock.lock()
        _continuedMonitor = monitor
        continuedLock.unlock()
    }

    /// 结束持续处理任务的监控并复位标志（任务本身由 BGTaskGate 负责只收尾一次）
    private func endContinuedMonitor() {
        continuedLock.lock()
        let monitor = _continuedMonitor
        _continuedMonitor = nil
        _continuedActive = false
        continuedLock.unlock()
        monitor?.cancel()
    }
    #endif
}