//
//  LaunchDiagnostics.swift
//  EhModels
//
//  诊断用「启动断点日志」(breadcrumb) —— Release 也生效，用于定位「一打开就闪退」。
//
//  背景:
//    Release 版 debugLog 被编译剔除，崩溃前不留任何痕迹；iOS 的 .ips 又不方便导出。
//    这里把关键流程的每一步同步写入
//      <App Documents>/EhViewerDiagnostics.log
//    （App 声明了 UIFileSharingEnabled，可在「文件」App 或电脑的文件共享里直接取出），
//    并在崩溃时记录异常原因与调用栈。每条写完立即 flush，保证崩溃前最后一条一定落盘。
//
//  用法:
//    启动最早处调用 LaunchDiagnostics.shared.beginLaunch("...")（内部安装崩溃捕获），
//    之后各层用 diag("...") 打点即可 —— EhModels 是 App / EhSpider / EhDownload /
//    EhBackgroundTransport 的公共依赖，都能直接调用。
//
//  ⚠️ 诊断代码：问题定位后应移除或降噪，避免长期写用户 Documents。
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(os)
import os
#endif

#if canImport(os)
private let diagOSLog = Logger(subsystem: "Stellatrix.ehviewer-apple", category: "LaunchDiag")
#endif

/// 全局打点 —— 任意线程可用，等价于 LaunchDiagnostics.shared.mark
public func diag(_ text: String) {
    LaunchDiagnostics.shared.mark(text)
}

/// 崩溃 / 启动断点日志。线程安全；写入同步 + flush。
public final class LaunchDiagnostics: @unchecked Sendable {

    public static let shared = LaunchDiagnostics()

    /// 导出文件名（「文件」App / 电脑文件共享里可见）
    public static let exportFileName = "EhViewerDiagnostics.log"
    /// 超过该大小则在下次启动时轮转，避免无限增长
    private static let rotateBytes = 512 * 1024

    private let lock = NSLock()
    private var handle: FileHandle?
    private var step = 0
    private let logURL: URL?
    private var hasBegun = false
    private var crashHandlersInstalled = false

    #if canImport(Darwin)
    /// 供信号处理器使用：预打开 fd + 预分配消息，避免在信号上下文里分配内存或加锁
    private var signalFD: Int32 = -1
    private var signalMessage: UnsafeMutablePointer<CChar>?
    #endif

    /// 实例属性（非 static）：Swift 6 语言模式下 static let 非 Sendable 类型（DateFormatter）会编译报错
    private let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private init() {
        // 优先 Documents（可被文件共享导出）；失败退回 Caches
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        let url = dir?.appendingPathComponent(Self.exportFileName)
        logURL = url
        guard let url else { return }

        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > Self.rotateBytes {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) {
            _ = fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    /// 启动最早处调用：安装崩溃捕获 + 写本次启动的头（每进程只写一次）
    public func beginLaunch(_ context: String) {
        installCrashHandlers()

        lock.lock()
        let shouldWriteHeader = !hasBegun
        hasBegun = true
        lock.unlock()
        guard shouldWriteHeader else { return }

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let bundleID = Bundle.main.bundleIdentifier ?? "?"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let memMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        mark("======== LAUNCH[\(context)] v\(version)(\(build)) \(bundleID) · \(osVersion) · 内存\(memMB)MB ========")
    }

    /// 记录一个断点 —— 同步写入并 flush，保证崩溃前最后一条一定落盘
    public func mark(_ text: String) {
        lock.lock()
        step += 1
        let line = "[\(stampFormatter.string(from: Date()))] #\(step) \(Thread.isMainThread ? "M" : "B") \(text)\n"
        if let data = line.data(using: .utf8) {
            handle?.write(data)
            try? handle?.synchronize()
        }
        lock.unlock()

        #if canImport(os)
        diagOSLog.info("\(text, privacy: .public)")
        #endif
    }

    /// 日志文件路径（便于提示用户去哪里取）
    public var logFilePath: String? { logURL?.path }

    // MARK: - 崩溃捕获

    private func installCrashHandlers() {
        lock.lock()
        let already = crashHandlersInstalled
        crashHandlersInstalled = true
        lock.unlock()
        guard !already else { return }

        #if canImport(Darwin)
        prepareSignalWriter()

        // ObjC 异常（如 BGTaskScheduler 的 NSInternalInconsistencyException）能拿到名字/原因/栈
        NSSetUncaughtExceptionHandler { exception in
            let d = LaunchDiagnostics.shared
            d.mark("💥 UNCAUGHT EXCEPTION: \(exception.name.rawValue)")
            d.mark("💥 reason: \(exception.reason ?? "(nil)")")
            for frame in exception.callStackSymbols { d.mark("💥 \(frame)") }
        }

        // Swift 陷阱 / 段错误走信号：处理器只写一行固定标记，再交回默认处理
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig, ehLaunchSignalHandler)
        }
        #endif
    }

    #if canImport(Darwin)
    private func prepareSignalWriter() {
        guard let path = logURL?.path else { return }
        signalFD = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        signalMessage = strdup("\n💥💥 SIGNAL 崩溃 —— 崩溃发生在上一条 #步骤 之后\n")
    }

    /// 信号处理器内调用：只做异步信号安全的 write，不加锁、不分配
    func writeSignalCrash() {
        guard signalFD >= 0, let message = signalMessage else { return }
        _ = write(signalFD, UnsafeRawPointer(message), strlen(message))
    }
    #endif
}

#if canImport(Darwin)
/// 顶层非捕获函数，可直接作为 C 信号处理器
func ehLaunchSignalHandler(_ sig: Int32) {
    LaunchDiagnostics.shared.writeSignalCrash()
    signal(sig, SIG_DFL)
    raise(sig)
}
#endif
