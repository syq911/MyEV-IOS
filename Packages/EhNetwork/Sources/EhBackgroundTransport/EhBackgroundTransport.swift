//
//  EhBackgroundTransport.swift
//  EhBackgroundTransport
//
//  真·后台下载传输层 —— 用 URLSession background 承接下载链路的所有网络 I/O。
//
//  为什么需要它:
//    进程内的 URLSessionConfiguration.default + data(for:) 完全依附于 App 进程，
//    App 一被挂起/锁屏，传输就停。URLSessionConfiguration.background 的传输由系统
//    进程 (nsurlsessiond) 托管，App 挂起 / 锁屏后传输继续，任务完成时系统会唤醒 App
//    (application(_:handleEventsForBackgroundURLSession:completionHandler:))。
//
//  设计要点:
//    - 对外暴露与 `URLSession.data(for:)` 完全同签名的 `data(for:)`，调用方零改动即可迁移。
//    - background session 的 `downloadTask` **不支持 request body**，因此 POST / 带 body 的
//      请求自动回落到前台 session（下载链路里只有 showpage 的 POST API 走这条路，它是
//      毫秒级的接口调用，不影响"图片传输在后台继续"这一核心收益）。
//    - 任务识别：给每个请求打上 `X-Eh-Task` 头，回调里据此把结果投递给对应的 continuation。
//      进程被强杀后残留的孤儿任务无法识别调用方 → 直接丢弃（磁盘 .ehviewer 记录驱动续传）。
//    - 支持 Swift Task 取消：Task 被取消时同步取消底层 URLSession 任务并抛出 CancellationError，
//      保证「暂停下载」能真正掐断在途网络 I/O。
//    - 后台 session 的 cookie 处理历史上不稳定，这里对缺省 Cookie 头的请求显式注入。
//
//  注意: 后台会话不需要任何 entitlement，也不需要新增 UIBackgroundModes。
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import EhSettings

public final class EhBackgroundTransport: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    public static let shared = EhBackgroundTransport()

    /// 后台会话标识（必须全局唯一且稳定，进程重启靠它重连同一个会话）
    private static let sessionIdentifier = "Stellatrix.ehviewer-apple.download.v1"
    /// 任务识别头
    private static let taskHeader = "X-Eh-Task"

    private let lock = NSLock()
    /// taskID → 等待中的 continuation
    private var continuations: [String: CheckedContinuation<(Data, URLResponse), Error>] = [:]
    /// taskID → 底层 URLSession 任务（取消时用）
    private var taskByID: [String: URLSessionTask] = [:]
    /// 取消先于任务创建到达时，把 id 记下来，创建后立即取消
    private var cancelledIDs: Set<String> = []
    /// 系统交给我们的后台会话事件处理完成回调
    private var backgroundCompletionHandler: (() -> Void)?

    private var _session: URLSession!
    private var _foregroundSession: URLSession!

    /// 后台会话（下载链路主力）
    public var session: URLSession { _session }
    /// 前台会话（POST / 带 body 的请求兜底）
    public var foregroundSession: URLSession { _foregroundSession }

    private override init() {
        super.init()

        let timeout = TimeInterval(AppSettings.shared.downloadTimeout)

        let bgConfig = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        bgConfig.isDiscretionary = false        // ★ 必须 false，否则系统"挑时间"下载，体感就是没在下载
        bgConfig.sessionSendsLaunchEvents = true
        bgConfig.waitsForConnectivity = true    // 断网自动等待恢复
        bgConfig.allowsCellularAccess = true
        bgConfig.httpCookieStorage = HTTPCookieStorage.shared
        bgConfig.httpShouldSetCookies = true
        bgConfig.timeoutIntervalForRequest = max(timeout, 30)
        bgConfig.timeoutIntervalForResource = max(timeout * 4, 3600)
        _session = URLSession(configuration: bgConfig, delegate: self, delegateQueue: nil)

        let fgConfig = URLSessionConfiguration.default
        fgConfig.httpCookieStorage = .shared
        fgConfig.timeoutIntervalForRequest = max(timeout, 30)
        fgConfig.timeoutIntervalForResource = max(timeout * 4, 3600)
        _foregroundSession = URLSession(configuration: fgConfig)
    }

    // MARK: - 对外接口（与 URLSession.data(for:) 同签名）

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        // ① background 的 downloadTask 不支持 request body → POST / 带 body 回落前台
        if request.httpBody != nil || request.httpBodyStream != nil {
            return try await _foregroundSession.data(for: request)
        }
        if let method = request.httpMethod?.uppercased(), method != "GET", method != "HEAD" {
            return try await _foregroundSession.data(for: request)
        }

        let taskID = UUID().uuidString
        var req = request
        req.setValue(taskID, forHTTPHeaderField: Self.taskHeader)
        injectCookiesIfNeeded(&req)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                continuations[taskID] = continuation
                let task = _session.downloadTask(with: req)
                taskByID[taskID] = task
                let cancelledBeforeResume = cancelledIDs.remove(taskID) != nil
                if cancelledBeforeResume {
                    continuations.removeValue(forKey: taskID)
                    taskByID.removeValue(forKey: taskID)
                }
                lock.unlock()

                if cancelledBeforeResume {
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.cancelTask(taskID)
        }
    }

    /// 由 AppDelegate 在 `handleEventsForBackgroundURLSession` 中转发
    public func handleBackgroundSessionCompletion(_ handler: @escaping () -> Void) {
        lock.lock()
        backgroundCompletionHandler = handler
        lock.unlock()
        // ★ 必须触碰一次 session：系统在后台唤醒 App 时，需要 App 用同一个 identifier
        //   重建会话，否则事件不会被投递、completionHandler 永远不会被调用（App 会被杀）
        _ = _session
    }

    /// 取消所有在途的下载任务（暂停 / 取消下载时调用）
    public func cancelAllTasks() {
        _session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = Self.taskID(of: downloadTask),
              let continuation = takeContinuation(id),
              let response = downloadTask.response else {
            // 无法识别的任务（进程重启后的孤儿）→ 丢弃临时文件
            try? FileManager.default.removeItem(at: location)
            return
        }
        do {
            let data = try Data(contentsOf: location)
            try? FileManager.default.removeItem(at: location)
            continuation.resume(returning: (data, response))
        } catch {
            try? FileManager.default.removeItem(at: location)
            continuation.resume(throwing: error)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }   // 成功路径已在 didFinishDownloadingTo 处理
        guard let id = Self.taskID(of: task), let continuation = takeContinuation(id) else { return }
        continuation.resume(throwing: error)
    }

    public func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {}

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        lock.unlock()
        guard let handler else { return }
        DispatchQueue.main.async { handler() }
    }

    // MARK: - 内部工具

    private func takeContinuation(_ id: String) -> CheckedContinuation<(Data, URLResponse), Error>? {
        lock.lock()
        defer { lock.unlock() }
        taskByID.removeValue(forKey: id)
        cancelledIDs.remove(id)
        return continuations.removeValue(forKey: id)
    }

    /// 取消一个在途任务：continuation 还没建立时先记账，等创建后立即取消
    private func cancelTask(_ id: String) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: id)
        let task = taskByID.removeValue(forKey: id)
        if continuation == nil { cancelledIDs.insert(id) }
        lock.unlock()
        task?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    private static func taskID(of task: URLSessionTask) -> String? {
        task.currentRequest?.value(forHTTPHeaderField: taskHeader)
            ?? task.originalRequest?.value(forHTTPHeaderField: taskHeader)
    }

    /// 后台会话的 cookie 处理不稳定 → 缺省时显式注入
    private func injectCookiesIfNeeded(_ request: inout URLRequest) {
        guard request.value(forHTTPHeaderField: "Cookie") == nil,
              let url = request.url,
              let cookies = HTTPCookieStorage.shared.cookies(for: url),
              !cookies.isEmpty else { return }
        let fields = HTTPCookie.requestHeaderFields(with: cookies)
        for (key, value) in fields {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }
}