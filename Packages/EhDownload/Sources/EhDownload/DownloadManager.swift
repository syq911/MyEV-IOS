import Foundation
import EhModels
import EhDatabase
import EhSpider
import EhBackgroundTransport
#if canImport(UIKit)
import UIKit
#endif
#if canImport(os)
import os
#endif

/// 后台下载诊断日志 —— 用 Console.app 连 iPhone 过滤 subsystem 即可观察
/// 「切后台后传输是否仍在推进」。关键路径用 .info，细节用 .debug。
private let bgLog = Logger(subsystem: "Stellatrix.ehviewer-apple", category: "Download")

// MARK: - DownloadManager (对应 Android DownloadManager.java)
// 下载队列管理 Actor

public actor DownloadManager {
    public static let shared = DownloadManager()

    // MARK: - 状态常量

    public static let stateInvalid = -1
    public static let stateNone    = 0
    public static let stateWait    = 1
    public static let stateDownload = 2
    public static let stateFinish  = 3
    public static let stateFailed  = 4

    // MARK: - 属性

    /// 下载队列
    /// ⚠️ lazy: 首次访问时同步从数据库加载。
    ///   以前是 init 里 `Task { await loadFromDatabase() }` —— Actor 不保证 Task 之间的
    ///   执行顺序，App 启动后立刻打开已下载画廊时队列可能还是空的，
    ///   于是被判定为"未下载"、整本走网络 (issue #8 问题二)
    private lazy var downloadQueue: [DownloadTask] = {
        diag("DownloadManager: 首次访问 → 同步加载下载队列(DB)")
        let tasks = Self.tasksFromDatabase(downloadDirectory: downloadDirectory)
        diag("DownloadManager: 下载队列加载完成 count=\(tasks.count)")
        return tasks
    }()
    private var activeTask: DownloadTask?
    /// 当前真正在执行的任务 gid — executeDownload 每次从 await 恢复后都要用它确认
    /// 自己是否仍然是活跃任务 (可能已被 pause/delete/pauseAll 取代)
    private var runningGid: Int64?
    /// 每个在途页的字节采样：key = "gid:page"。
    /// ★ 必须按页分开采样：同一 gid 下有多个并发 worker 时，各任务的
    ///   totalBytesWritten 相互独立，混在一起做差会得到毫无意义的巨大"速度"。
    private var transferSample: [String: (gid: Int64, at: Date, bytes: Int64, rate: Double)] = [:]
    private let maxConcurrent = 1  // 同一时间只下载一个画廊
    private var isRunning = false

    /// 下载监听器（用于通知集成）
    public weak var listener: DownloadListener?

    /// 下载目录
    public nonisolated var downloadDirectory: URL {
        // macOS: 支持用户自定义路径
        #if os(macOS)
        if let customPath = UserDefaults.standard.string(forKey: "downloadPath"),
           !customPath.isEmpty {
            return URL(fileURLWithPath: customPath)
        }
        #endif
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("download")
    }

    private init() {
        // 确保下载目录存在
        var dir = downloadDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // iOS/iPadOS: 排除 iCloud 备份
        #if os(iOS)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? dir.setResourceValues(resourceValues)
        #endif

        // 传输层字节进度（已节流 500ms）→ 换算实时速度刷进下载队列，
        // 让下载列表 / 灵动岛在长页面传输期间也能持续跳动
        EhBackgroundTransport.shared.progressHandler = { context, written, _ in
            Task {
                await DownloadManager.shared.applyTransferProgress(
                    gid: context.gid,
                    page: context.page,
                    written: written
                )
            }
        }
    }

    /// 从数据库加载已有下载任务 (nonisolated static: 供 lazy 属性同步初始化)
    private nonisolated static func tasksFromDatabase(downloadDirectory: URL) -> [DownloadTask] {
        do {
            let records = try EhDatabase.shared.getAllDownloads()
            var tasks: [DownloadTask] = records.map { record in
                let gallery = GalleryInfo(
                    gid: record.gid, token: record.token,
                    title: record.title, titleJpn: record.titleJpn,
                    thumb: record.thumb,
                    category: EhCategory(rawValue: record.category),
                    posted: record.posted, uploader: record.uploader,
                    rating: record.rating, pages: record.pages
                )
                return DownloadTask(gallery: gallery, label: record.label, state: record.state,
                                    addedDate: record.date, sortOrder: record.sortOrder)
            }
            // 扫描磁盘已下载的图片文件，恢复中断下载的进度
            for i in tasks.indices {
                let task = tasks[i]
                if task.state == Self.stateFinish {
                    // 已完成的任务直接设置为总页数
                    tasks[i].downloadedPages = task.gallery.pages
                } else if task.gallery.pages > 0 {
                    // 扫描目录中已有的图片文件数
                    let dir = downloadDirectory.appendingPathComponent(
                        Self.galleryDirectoryName(gid: task.gallery.gid, title: task.gallery.bestTitle)
                    )
                    let existingPages = SpiderInfoFile.getDownloadedPages(in: dir, totalPages: task.gallery.pages)
                    tasks[i].downloadedPages = existingPages.count
                }
            }
            return tasks
        } catch {
            print("Failed to load downloads from database: \(error)")
            return []
        }
    }

    // MARK: - 公共接口

    /// 添加下载任务 (Fix A-1: 已有 failed/none 状态时自动恢复而非静默忽略)
    public func startDownload(gallery: GalleryInfo, label: String? = nil) async {
        // 检查是否已在队列中
        if let existingIndex = downloadQueue.firstIndex(where: { $0.gallery.gid == gallery.gid }) {
            let existingState = downloadQueue[existingIndex].state
            if existingState == Self.stateNone || existingState == Self.stateFailed {
                // 已暂停或已失败 → 重置为等待并恢复
                downloadQueue[existingIndex].state = Self.stateWait
                try? EhDatabase.shared.updateDownloadState(gid: gallery.gid, state: Self.stateWait)
                if !isRunning { processQueue() }
            }
            // stateWait / stateDownload / stateFinish → 不重复操作
            return
        }

        // 新任务插入到列表最前面（新加入的显示在最上）；
        // 下载顺序仍由 addedDate 决定（先加入先下载），与展示顺序互不影响。
        let nextSortOrder = DownloadOrdering.insertionSortOrderForTop(
            existing: downloadQueue.map(\.sortOrder))
        let addedDate = Date()
        let task = DownloadTask(gallery: gallery, label: label,
                                addedDate: addedDate, sortOrder: nextSortOrder)
        downloadQueue.insert(task, at: 0)

        // 持久化到数据库
        let record = DownloadRecord(
            gid: gallery.gid, token: gallery.token,
            title: gallery.bestTitle, titleJpn: gallery.titleJpn,
            thumb: gallery.thumb, category: gallery.category.rawValue,
            posted: gallery.posted, uploader: gallery.uploader,
            rating: gallery.rating, simpleLanguage: gallery.simpleLanguage,
            pages: gallery.pages, state: Self.stateWait,
            sortOrder: nextSortOrder, date: addedDate
        )
        try? EhDatabase.shared.insertDownload(record)

        // 启动队列处理
        if !isRunning {
            processQueue()
        }
    }

    /// 暂停下载
    public func pauseDownload(gid: Int64) {
        let wasActive = activeTask?.gallery.gid == gid
        if wasActive {
            if let spider = spider(forGid: gid) {
                Task { await spider.cancelAll() }
            }
            // ★ 直接掐断该画廊在途的后台传输（即使 spider 引用已丢失也能停住）
            EhBackgroundTransport.shared.cancelTasks(gid: gid)
            clearTransferSamples(gid: gid)
            // ★ 先失效 runningGid: 正在 await 中的 executeDownload 恢复后会自行退出，
            //   不会再把状态写回队列 (否则会覆盖这里设置的"已暂停")
            runningGid = nil
            activeTask = nil
        }
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
            downloadQueue[index].state = Self.stateNone
            downloadQueue[index].spider = nil
            try? EhDatabase.shared.updateDownloadState(gid: gid, state: Self.stateNone)
        }
        if wasActive { processQueue() }
    }

    /// 暂停所有下载（磁盘满时紧急调用）
    public func pauseAllDownloads() {
        // 取消当前活跃任务
        if let gid = activeTask?.gallery.gid, let spider = spider(forGid: gid) {
            Task { await spider.cancelAll() }
        }
        // 掐断所有在途后台传输（磁盘满等紧急暂停）
        EhBackgroundTransport.shared.cancelAllTasks()
        transferSample.removeAll()
        runningGid = nil
        activeTask = nil
        isRunning = false

        // 暂停队列中所有等待/下载中的任务
        for i in downloadQueue.indices {
            if downloadQueue[i].state == Self.stateWait || downloadQueue[i].state == Self.stateDownload {
                downloadQueue[i].state = Self.stateNone
                downloadQueue[i].spider = nil
                try? EhDatabase.shared.updateDownloadState(gid: downloadQueue[i].gallery.gid, state: Self.stateNone)
            }
        }
        print("[DownloadManager] ⚠️ 所有下载已暂停（磁盘空间不足）")
    }

    /// 恢复下载
    public func resumeDownload(gid: Int64) {
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
            downloadQueue[index].state = Self.stateWait
            try? EhDatabase.shared.updateDownloadState(gid: gid, state: Self.stateWait)
            // 用 activeTask == nil 判断，避免 isRunning 残留 true 时队列卡死
            if activeTask == nil {
                runningGid = nil
                isRunning = false
                processQueue()
            }
        }
    }

    /// 强制尝试处理队列 (外部调用，修复 isRunning 残留问题)
    public func kickQueue() {
        if activeTask == nil {
            runningGid = nil
            isRunning = false
            processQueue()
        }
    }

    /// 删除下载 (可选删除文件)
    public func deleteDownload(gid: Int64, deleteFiles: Bool = false) {
        // 先获取 gallery 信息 (必须在 removeAll 之前)
        let task = downloadQueue.first(where: { $0.gallery.gid == gid })
        let title = task?.gallery.bestTitle
        let pages = task?.gallery.pages ?? 0

        if activeTask?.gallery.gid == gid {
            if let spider = spider(forGid: gid) {
                Task { await spider.cancelAll() }
            }
            EhBackgroundTransport.shared.cancelTasks(gid: gid)
            clearTransferSamples(gid: gid)
            // ★ 失效 runningGid，正在执行的 executeDownload 恢复后不会再访问已删除的任务
            runningGid = nil
            activeTask = nil
        }

        downloadQueue.removeAll { $0.gallery.gid == gid }
        try? EhDatabase.shared.deleteDownload(gid: gid)

        if deleteFiles {
            // 清除 SpiderDen 阅读缓存
            if pages > 0 {
                SpiderDen.clearCache(forGid: gid, pages: pages)
            }

            if let title = title, !title.isEmpty {
                // 精确匹配: 使用实际标题
                let dir = galleryDirectory(gid: gid, title: title)
                try? FileManager.default.removeItem(at: dir)
            } else {
                // 回退: 枚举下载目录中匹配 "gid-*" 前缀的目录
                let prefix = "\(gid)-"
                if let contents = try? FileManager.default.contentsOfDirectory(
                    at: downloadDirectory, includingPropertiesForKeys: nil) {
                    for item in contents where item.lastPathComponent.hasPrefix(prefix) {
                        try? FileManager.default.removeItem(at: item)
                    }
                }
            }
        }

        processQueue()
    }

    /// 获取所有下载任务
    public func getAllTasks() -> [DownloadTask] {
        downloadQueue
    }

    /// 手动拖动下载列表重新排序（**只改显示顺序，不影响下载顺序**）。
    ///
    /// - Parameters:
    ///   - visibleGids: 当前列表实际展示的 gid 顺序（可能是按标签/状态/搜索过滤后的子集）。
    ///   - fromOffsets / toOffset: SwiftUI `onMove` 提供的源位置与目标位置。
    public func moveTasks(visibleGids: [Int64], fromOffsets: IndexSet, toOffset: Int) {
        downloadQueue = DownloadOrdering.applyingMove(
            to: downloadQueue, visibleGids: visibleGids,
            fromOffsets: fromOffsets, toOffset: toOffset
        )
        persistDisplayOrder()
    }

    /// 把当前数组下标写回 `sortOrder` 并持久化（仅供展示顺序使用）
    private func persistDisplayOrder() {
        for index in downloadQueue.indices {
            downloadQueue[index].sortOrder = index
        }
        try? EhDatabase.shared.setDownloadSortOrders(downloadQueue.map { $0.gallery.gid })
    }

    /// 获取任务状态
    public func getTaskState(gid: Int64) -> Int {
        if activeTask?.gallery.gid == gid {
            return activeTask?.state ?? Self.stateNone
        }
        return downloadQueue.first(where: { $0.gallery.gid == gid })?.state ?? Self.stateInvalid
    }

    /// 更改下载标签 (对齐 Android DownloadManager.changeLabel)
    public func changeLabel(gids: [Int64], label: String?) {
        for gid in gids {
            if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
                downloadQueue[index].label = label
                // 同步到数据库
                if var record = try? EhDatabase.shared.getDownload(gid: gid) {
                    record.label = label
                    try? EhDatabase.shared.updateDownload(record)
                }
            }
        }
    }

    /// 更新下载进度 (由 SpiderInfoUpdater 调用，同步到队列以便 UI 读取)
    public func updateDownloadedPages(gid: Int64, count: Int) {
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
            // 夹取到 [0, 总页数]：进度条永远不该出现超过 100% 的情况
            let total = max(0, downloadQueue[index].gallery.pages)
            downloadQueue[index].downloadedPages = min(max(0, count), total)
        }
    }

    /// 更新下载速度 (由 SpiderInfoUpdater 调用，同步到队列以便 UI 读取)
    public func updateDownloadSpeed(gid: Int64, speed: Int64) {
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
            downloadQueue[index].speed = speed
        }
    }

    /// 丢弃某个画廊的所有字节采样（暂停 / 删除时调用）
    private func clearTransferSamples(gid: Int64) {
        transferSample = transferSample.filter { $0.value.gid != gid }
    }

    /// 单个页任务的字节进度（传输层已按 500ms 节流）→ 换算实时速度刷进队列。
    ///
    /// ★ 按 (gid, page) 分开采样：同一下载里多个 worker 并发取不同页，各自的
    ///   totalBytesWritten 是**独立**计数器。以前只按 gid 存一个采样点，等于拿
    ///   不同任务的计数器交替做差 —— 差值毫无意义，长页 + 短页混在一起时能算出
    ///   上百 MB/s 的假速度。现在按页算速率，再按 gid 求和得到真实总速度。
    func applyTransferProgress(gid: Int64, page: Int?, written: Int64) {
        let now = Date()
        let key = "\(gid):\(page ?? -1)"

        if let sample = transferSample[key] {
            let elapsed = now.timeIntervalSince(sample.at)
            if elapsed >= 0.4 {
                let delta = written - sample.bytes
                // delta < 0 说明底层任务被重建（换 H@H 节点等），旧速率作废重新采样
                let rate = delta >= 0 ? Double(delta) / elapsed : 0
                transferSample[key] = (gid, now, written, rate)
            }
        } else {
            transferSample[key] = (gid, now, written, 0)
        }

        // 清掉 5 秒内没有更新的采样（任务已结束 / 卡住），避免旧速率被一直累加
        let cutoff = now.addingTimeInterval(-5)
        if transferSample.contains(where: { $0.value.at < cutoff }) {
            transferSample = transferSample.filter { $0.value.at >= cutoff }
        }

        // 该画廊所有在途页的速率之和 = 实时速度
        let totalRate = transferSample.values
            .filter { $0.gid == gid }
            .reduce(0.0) { $0 + $1.rate }

        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
            downloadQueue[index].speed = Int64(totalRate)
        }
    }

    /// 设置下载监听器
    public func setListener(_ listener: DownloadListener?) {
        self.listener = listener
    }

    // MARK: - 后台任务支持

    /// 恢复队列处理（App 冷启动 / BGProcessingTask 唤醒时调用）
    ///
    /// 用 `activeTask == nil` 判定而不是 `isRunning`：后者在异常中断路径上可能残留 true，
    /// 会让队列永远卡死（与 resumeDownload / kickQueue 保持同一套判定）。
    public func resumeAllWaiting() {
        diag("resumeAllWaiting: 进入")
        guard activeTask == nil else {
            diag("resumeAllWaiting: 已有活跃任务，忽略")
            return
        }
        let waitingGids = downloadQueue.filter { $0.state == Self.stateWait }.map(\.gallery.gid)
        guard !waitingGids.isEmpty else {
            diag("resumeAllWaiting: 无等待任务，返回")
            return
        }
        diag("resumeAllWaiting: 待恢复 gid=\(waitingGids)")
        runningGid = nil
        isRunning = false
        bgLog.info("恢复等待中的下载队列")
        processQueue()
    }

    // MARK: - 队列处理

    private func processQueue() {
        guard activeTask == nil else { return }

        // 找到下一个等待中的任务 —— 按「加入时间」取最早的一个（先加入先下载）。
        // ★ 不能用数组下标：数组是展示顺序，会被用户拖动改变；下载顺序永远按加入时间。
        guard let nextIndex = DownloadOrdering.nextWaitingIndex(in: downloadQueue) else {
            isRunning = false
            runningGid = nil
            return
        }

        isRunning = true
        downloadQueue[nextIndex].state = Self.stateDownload
        activeTask = downloadQueue[nextIndex]

        // ★ 只向下传递 gid，绝不传递数组索引:
        //   executeDownload 内部有多个 await 挂起点，挂起期间 deleteDownload /
        //   pauseAllDownloads 会修改 downloadQueue，旧索引会越界或指向别的任务
        //   (对应 issue #8 问题四: 下载管理删除/恢复任务时闪退)
        let gid = downloadQueue[nextIndex].gallery.gid
        runningGid = gid

        diag("processQueue: 调度 gid=\(gid)")
        Task {
            await executeDownload(gid: gid)
        }
    }

    // MARK: - 后台任务句柄 (iOS: 申请后台执行时间; 其他平台 no-op)

    /// iOS: 申请后台执行时间 —— 只为抢下「切后台头 ~30 秒」的全速下载窗口。
    ///
    /// ★ 过期处理器里**绝不能再暂停下载**：
    ///   ~30 秒到期只意味着进程即将被系统挂起，而传输是由
    ///   `URLSessionConfiguration.background`（系统进程 nsurlsessiond）托管的，
    ///   挂起 / 锁屏后照样继续传；任务完成时系统会唤醒 App 推进下一批，
    ///   这个「唤醒 → 发一批 → 再挂起」的循环可以一直自我维持。
    ///   以前这里调 pauseActiveIfNeeded()，等于在挂起前亲手取消全部在途传输
    ///   并把状态刷成「等待中」，用户看到的就是「切后台几秒后下载停了」。
    private func beginBackgroundTask() async -> Int {
        #if canImport(UIKit)
        let identifier = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "EhGalleryDownload") {
                // 什么都不做，让进程正常挂起，交给后台会话 + 系统唤醒循环接力。
                bgLog.info("后台执行时间到期，进程即将挂起；传输交由 URLSession background 继续")
            }
        }
        return identifier.rawValue
        #else
        return 0
        #endif
    }

    private func endBackgroundTask(_ token: Int) async {
        #if canImport(UIKit)
        guard token != UIBackgroundTaskIdentifier.invalid.rawValue else { return }
        await MainActor.run {
            UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
        }
        #endif
    }

    /// 取出某个任务正在使用的 SpiderQueen
    /// ⚠️ 必须从 downloadQueue 取: activeTask 是 processQueue 时的**值拷贝**,
    ///    spider 是之后才写进 downloadQueue 的, activeTask?.spider 永远是 nil ——
    ///    以前 pause/delete 都是对着 nil 调 cancelAll, 暂停/删除根本停不下正在跑的下载
    private func spider(forGid gid: Int64) -> SpiderQueen? {
        downloadQueue.first(where: { $0.gallery.gid == gid })?.spider
    }

    /// 当前任务收尾 — 仅当 gid 仍是活跃任务时才清理并继续队列
    /// (防止已被 pause/delete 取代的旧任务把新任务的 activeTask 清空)
    private func finishRunning(gid: Int64) {
        guard runningGid == gid else { return }
        runningGid = nil
        activeTask = nil
        processQueue()
    }

    private func executeDownload(gid: Int64) async {
        diag("executeDownload: 进入 gid=\(gid)")
        // iOS: 申请后台执行时间, 防止进入后台后 ~30 秒被系统杀死
        let bgToken = await beginBackgroundTask()
        diag("executeDownload: 已申请后台时间 gid=\(gid)")

        // ★ 每个 await 挂起点之后都必须按 gid 重新定位任务，并确认自己仍是活跃任务
        guard let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }),
              runningGid == gid else {
            await endBackgroundTask(bgToken)
            finishRunning(gid: gid)
            return
        }

        let gallery = downloadQueue[index].gallery
        let dir = galleryDirectory(gid: gallery.gid, title: gallery.bestTitle)

        // 通知监听器下载开始
        await listener?.onDownloadStart(gid: gallery.gid, title: gallery.bestTitle)

        // 尝试从 .ehviewer 文件读取已有的 SpiderInfo
        var spiderInfo: SpiderInfo
        if let existing = SpiderInfoFile.read(from: dir) {
            spiderInfo = existing
        } else {
            spiderInfo = SpiderInfo(
                startPage: 0,
                gid: gallery.gid,
                token: gallery.token,
                pages: gallery.pages
            )
            // 保存初始 .ehviewer 文件
            try? SpiderInfoFile.write(spiderInfo, to: dir)
        }

        // 创建 SpiderQueen
        let spider = SpiderQueen(galleryInfo: gallery, spiderInfo: spiderInfo, mode: .download)

        // 统计磁盘上已有的页（返回页索引集合，用于对进度判重）
        let alreadyOnDisk = SpiderInfoFile.getDownloadedPages(in: dir, totalPages: gallery.pages)

        // onDownloadStart 是 await — 队列可能已在此期间变化，重新定位
        guard let setupIndex = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }),
              runningGid == gid else {
            await endBackgroundTask(bgToken)
            finishRunning(gid: gid)
            return
        }
        downloadQueue[setupIndex].spider = spider
        downloadQueue[setupIndex].downloadedPages = alreadyOnDisk.count
        downloadQueue[setupIndex].speed = 0   // 续传前清掉上一轮残留的速度，避免展示旧值

        // 设置代理以便更新 .ehviewer 文件和进度通知
        let updater = SpiderInfoUpdater(
            directory: dir,
            gid: gallery.gid,
            title: gallery.bestTitle,
            total: gallery.pages,
            listener: listener,
            alreadyOnDisk: alreadyOnDisk
        )
        await spider.setDelegate(updater)

        // 开始下载所有页面 (startDownload() 是真正的 async，会等待全部页面完成)
        bgLog.info("管线启动 gid=\(gid) 待下载=\(gallery.pages - alreadyOnDisk.count)/\(gallery.pages) 页")
        diag("executeDownload: 即将 spider.startDownload() gid=\(gid) 待下载=\(gallery.pages - alreadyOnDisk.count) 页")
        await spider.startDownload()
        diag("executeDownload: spider.startDownload() 返回 gid=\(gid)")

        // 下载完成后更新 .ehviewer 文件
        let finalInfo = await spider.getSpiderInfo()
        try? SpiderInfoFile.write(finalInfo, to: dir)

        // 统计下载结果 (对齐 Android DownloadManager.onFinished)
        var finishedCount = 0
        for i in 0..<gallery.pages {
            if await spider.getPageState(i) == SpiderQueen.stateFinish {
                finishedCount += 1
            }
        }

        // ★ 长时间 await 之后任务可能已被删除或暂停 —— 此时不得再写回状态，
        //   否则会数组越界崩溃 (旧索引失效) 或把状态写到别的画廊头上
        guard let finalIndex = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }),
              runningGid == gid else {
            await endBackgroundTask(bgToken)
            finishRunning(gid: gid)
            return
        }

        // 下载完成
        let success = finishedCount == gallery.pages
        downloadQueue[finalIndex].state = success ? Self.stateFinish : Self.stateFailed
        downloadQueue[finalIndex].downloadedPages = finishedCount
        downloadQueue[finalIndex].speed = 0     // 收尾清速度，否则 UI 会一直停在上一次的非零值
        downloadQueue[finalIndex].spider = nil  // 释放 spider 引用
        try? EhDatabase.shared.updateDownloadState(gid: gallery.gid, state: downloadQueue[finalIndex].state)
        if success {
            bgLog.info("管线结束 gid=\(gid) 全部完成 \(finishedCount)/\(gallery.pages) 页")
        } else {
            bgLog.error("管线结束 gid=\(gid) 未完成 \(finishedCount)/\(gallery.pages) 页")
        }

        // 通知监听器下载完成
        await listener?.onDownloadFinish(gid: gallery.gid, title: gallery.bestTitle, success: success)

        // iOS: 释放后台执行时间
        await endBackgroundTask(bgToken)

        diag("executeDownload: 完成 gid=\(gid) finished=\(finishedCount)/\(gallery.pages)")
        finishRunning(gid: gid)
    }

    // MARK: - 文件管理

    // MARK: - 路径统一 (Fix D-1, A-3: 全局唯一的目录命名算法)

    /// 文件名清理 (移除非法字符) — 公开静态方法，保证所有组件使用同一逻辑
    public nonisolated static func sanitizeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = name.components(separatedBy: illegal).joined(separator: "_")
        let trimmed = sanitized.prefix(128)
        return String(trimmed).trimmingCharacters(in: .whitespaces)
    }

    /// 画廊目录名 — 唯一真相源 (所有路径引用必须通过此方法)
    /// 格式: `{gid}-{sanitizeFilename(title).prefix(128)}`
    public nonisolated static func galleryDirectoryName(gid: Int64, title: String) -> String {
        let sanitized = sanitizeFilename(title)
        return "\(gid)-\(sanitized)"
    }

    /// 画廊下载目录 (对应 Android: gid-sanitized_title)
    public nonisolated func galleryDirectory(gid: Int64, title: String) -> URL {
        let dirName = Self.galleryDirectoryName(gid: gid, title: title)
        return downloadDirectory.appendingPathComponent(dirName)
    }

    /// 图片文件名 (对应 Android: String.format("%08d%s", index+1, ext))
    public nonisolated func imageFilename(index: Int, ext: String = ".jpg") -> String {
        String(format: "%08d%@", index + 1, ext)
    }

    // MARK: - 下载状态真实检查 (Fix D-2, B-1)

    /// 检查画廊是否已完整下载 — 验证数据库状态 AND 磁盘上每一页都存在
    /// (仅目录存在不足以判定完成: 下载中断后目录同样存在, 会被误判为"已下载")
    public func isGalleryFullyDownloaded(gid: Int64) -> Bool {
        guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }),
              task.state == Self.stateFinish else { return false }
        let dir = galleryDirectory(gid: gid, title: task.gallery.bestTitle)
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        let pages = task.gallery.pages
        guard pages > 0 else { return false }
        return SpiderInfoFile.getDownloadedPages(in: dir, totalPages: pages).count >= pages
    }

    /// 已下载的页数 (磁盘真实文件数, 与下载状态无关)
    public func getDownloadedPageCount(gid: Int64) -> Int {
        guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }),
              task.gallery.pages > 0 else { return 0 }
        let dir = galleryDirectory(gid: gid, title: task.gallery.bestTitle)
        return SpiderInfoFile.getDownloadedPages(in: dir, totalPages: task.gallery.pages).count
    }

    // MARK: - 阅读时同步下载 (对齐 Android 上游 sync_download_while_reading)

    /// 阅读时把看过的图片顺手存进下载目录
    ///
    /// 对应 Android SpiderDen.shouldSyncDownloadWhileReading(): 阅读模式 + 设置开启时，
    /// 写图片的管道从"只写缓存"变成"也写下载目录"。
    /// Apple 端阅读器没走 SpiderDen（自己下图），所以由阅读器下载成功后回调到这里。
    ///
    /// - Returns: 真正写入磁盘了才返回 true (已存在同页 / 磁盘空间不足 → false)
    @discardableResult
    public func saveWhileReading(
        gallery: GalleryInfo, pageIndex: Int, data: Data, extension ext: String
    ) -> Bool {
        guard pageIndex >= 0, !data.isEmpty else { return false }

        let dir = galleryDirectory(gid: gallery.gid, title: gallery.bestTitle)
        // 已经有这一页就不重复写 (可能是之前下载过的)
        if SpiderInfoFile.getLocalImageURL(in: dir, pageIndex: pageIndex) != nil { return false }

        // 磁盘空间兜底 —— 与正式下载同一套判断
        guard SpiderDen.hasSufficientDiskSpace(bytes: Int64(data.count) + 10 * 1024 * 1024) else {
            return false
        }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let filename = imageFilename(index: pageIndex, ext: ext)
            try data.write(to: dir.appendingPathComponent(filename))
        } catch {
            print("[DownloadManager] 阅读时同步下载失败 p\(pageIndex): \(error)")
            return false
        }

        // 首次写入时补一份 .ehviewer + 数据库记录，
        // 这样这本画廊会出现在下载列表里，也能被"扫描下载目录恢复任务"认出来
        registerReadingSyncTaskIfNeeded(gallery: gallery, directory: dir)

        // 刷新进度，让下载列表显示"已存 N 页"
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gallery.gid }),
           gallery.pages > 0 {
            let saved = SpiderInfoFile.getDownloadedPages(in: dir, totalPages: gallery.pages).count
            downloadQueue[index].downloadedPages = saved

            // 整本都看完 = 整本都存下来了 → 标记为已完成
            // (否则列表会一直显示"已暂停"，但 4/4 页其实都在盘上)
            if saved >= gallery.pages, downloadQueue[index].state != Self.stateFinish {
                downloadQueue[index].state = Self.stateFinish
                try? EhDatabase.shared.updateDownloadState(gid: gallery.gid, state: Self.stateFinish)
            }
        }
        return true
    }

    /// 同步下载首次落盘时登记任务 (状态设为 stateNone = 已暂停，不会抢占下载队列)
    private func registerReadingSyncTaskIfNeeded(gallery: GalleryInfo, directory: URL) {
        guard !downloadQueue.contains(where: { $0.gallery.gid == gallery.gid }) else { return }

        if SpiderInfoFile.read(from: directory) == nil {
            let info = SpiderInfo(
                startPage: 0, gid: gallery.gid, token: gallery.token, pages: gallery.pages
            )
            try? SpiderInfoFile.write(info, to: directory)
        }

        // ⚠️ stateNone 而不是 stateWait: 这是"顺手存的"，不应该自己启动整本下载
        // 同样插入到列表最前面（新加入的显示在最上）
        let nextSortOrder = DownloadOrdering.insertionSortOrderForTop(
            existing: downloadQueue.map(\.sortOrder))
        let addedDate = Date()
        var task = DownloadTask(gallery: gallery, label: nil, state: Self.stateNone,
                                addedDate: addedDate, sortOrder: nextSortOrder)
        task.downloadedPages = SpiderInfoFile.getDownloadedPages(
            in: directory, totalPages: max(gallery.pages, 1)
        ).count
        downloadQueue.insert(task, at: 0)

        let record = DownloadRecord(
            gid: gallery.gid, token: gallery.token,
            title: gallery.bestTitle, titleJpn: gallery.titleJpn,
            thumb: gallery.thumb, category: gallery.category.rawValue,
            posted: gallery.posted, uploader: gallery.uploader,
            rating: gallery.rating, simpleLanguage: gallery.simpleLanguage,
            pages: gallery.pages, state: Self.stateNone,
            sortOrder: nextSortOrder, date: addedDate
        )
        try? EhDatabase.shared.insertDownload(record)
    }

    /// 获取已下载画廊的目录路径 (由 ReaderViewModel 调用，替代硬编码路径)
    public func getDownloadedGalleryDirectory(gid: Int64) -> URL? {
        guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }) else { return nil }
        return galleryDirectory(gid: gid, title: task.gallery.bestTitle)
    }

    /// 本地画廊目录 — 只要有下载记录且目录里至少有一张图就返回
    /// (对齐 Android SpiderDen: 逐页判断本地是否存在，而不是整本"全有或全无")
    /// 这样部分下载 / 下载中断的画廊也能优先读本地，缺失的页再回退网络
    public func localGalleryDirectory(gid: Int64) -> URL? {
        guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }) else { return nil }
        let dir = galleryDirectory(gid: gid, title: task.gallery.bestTitle)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        let pages = task.gallery.pages
        guard pages > 0,
              !SpiderInfoFile.getDownloadedPages(in: dir, totalPages: pages).isEmpty else { return nil }
        return dir
    }
}

// MARK: - DownloadTask

public struct DownloadTask: Sendable {
    public let gallery: GalleryInfo
    public var label: String?
    public var state: Int
    public var downloadedPages: Int
    /// 下载速度 (字节/秒)
    public var speed: Int64
    public var spider: SpiderQueen?
    /// 加入下载的时间 —— 决定下载顺序（先加入先下载）。
    public var addedDate: Date
    /// 下载列表的显示顺序 —— 仅用于列表展示（用户可拖动改变），不参与下载调度。
    public var sortOrder: Int

    public init(gallery: GalleryInfo, label: String? = nil, state: Int = DownloadManager.stateWait,
                addedDate: Date = Date(), sortOrder: Int = 0) {
        self.gallery = gallery
        self.label = label
        self.state = state
        self.downloadedPages = 0
        self.speed = 0
        self.addedDate = addedDate
        self.sortOrder = sortOrder
    }
}

// MARK: - SpiderInfo 扩展 (简化构造)

extension SpiderInfo {
    init(startPage: Int, gid: Int64, token: String, pages: Int) {
        self.init()
        self.startPage = startPage
        self.gid = gid
        self.token = token
        self.pages = pages
    }
}

// MARK: - SpiderInfoUpdater (用于下载时更新 .ehviewer 文件)

actor SpiderInfoUpdater: SpiderDelegate {
    private let directory: URL
    private let gid: Int64
    private let title: String
    private let totalPages: Int
    private weak var listener: DownloadListener?

    /// 已计入进度的页索引。
    ///
    /// 以「本次运行开始前磁盘上已有的页」为种子，之后只有**真正新下载**的页才计入。
    /// 否则续传时必现两个 bug（1.4.2 日志已证实）：
    ///   1. 已存在的页在 SpiderQueen 里走「本地已有」快速路径时同样会回调 onPageLoaded，
    ///      于是被重复计数 → 进度假前进一大截，甚至超过 100%；
    ///   2. 这些页的字节也被累加进"已下载字节"，再除以「运行开始后极短的耗时」，
    ///      得到几百 MB/s 的荒谬速度。
    private var countedIndices: Set<Int>
    /// 进度（= 已计入的页数，恒 ≤ totalPages）
    private var downloadedCount: Int
    /// 本次运行真正新下载的字节数（不含磁盘上已有的页，也不含任何本地读取）
    private var networkBytes: Int64 = 0

    private var lastNotifyTime: Date = .distantPast
    private let notifyInterval: TimeInterval = 1.0 // 每秒最多通知一次
    /// 速度滑动窗口：两次采样至少间隔这么久，避免把抖动放大成天文数字
    private var speedSampleAt: Date = Date()
    private var speedSampleBytes: Int64 = 0
    private var currentSpeed: Int64 = 0
    private let speedSampleInterval: TimeInterval = 0.5

    init(
        directory: URL,
        gid: Int64,
        title: String,
        total: Int,
        listener: DownloadListener?,
        alreadyOnDisk: Set<Int> = []
    ) {
        self.directory = directory
        self.gid = gid
        self.title = title
        self.totalPages = total
        self.listener = listener
        self.countedIndices = alreadyOnDisk
        self.downloadedCount = alreadyOnDisk.count
        self.speedSampleAt = Date()
        diag("updater: 初始化 gid=\(gid) 已在磁盘=\(alreadyOnDisk.count)/\(total) 页(这些不再重复计数)")
    }

    /// 获取指定页面的实际文件大小
    private func getPageFileSize(index: Int) -> Int64 {
        let prefix = String(format: "%08d", index + 1)
        for ext in [".jpg", ".png", ".gif", ".webp"] {
            let fileURL = directory.appendingPathComponent("\(prefix)\(ext)")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? UInt64 {
                return Int64(size)
            }
        }
        return 0
    }

    func onPageLoaded(index: Int, imageUrl: String) async {
        // ★ 本次运行开始前就已在磁盘上的页（SpiderQueen 走「本地已有」快速路径）：
        //   不重复计进度、不计字节 —— 它们既不是这次下载的成果，也没有产生任何网络流量。
        guard !countedIndices.contains(index) else { return }
        countedIndices.insert(index)
        downloadedCount = min(countedIndices.count, totalPages)

        // 只累计本次真正新下载的字节
        networkBytes += getPageFileSize(index: index)

        // 同步更新 DownloadManager 队列中的进度 (便于 UI 读取)
        await DownloadManager.shared.updateDownloadedPages(gid: gid, count: downloadedCount)

        // 速度 = 滑动窗口内的 Δ字节 / Δ时间。
        // 不用「累计字节 / 自运行开始的耗时」—— 后者是平均速度且会被磁盘已有页污染，
        // 续传时首屏就能爆出几百 MB/s。
        let now = Date()
        let dt = now.timeIntervalSince(speedSampleAt)
        if dt >= speedSampleInterval {
            currentSpeed = Int64(Double(networkBytes - speedSampleBytes) / dt)
            speedSampleAt = now
            speedSampleBytes = networkBytes
        }

        // 同步速度到 DownloadManager 队列 (便于 UI 读取)
        await DownloadManager.shared.updateDownloadSpeed(gid: gid, speed: currentSpeed)

        // 节流通知
        if now.timeIntervalSince(lastNotifyTime) >= notifyInterval {
            lastNotifyTime = now
            await listener?.onDownloadProgress(
                gid: gid,
                title: title,
                downloaded: downloadedCount,
                total: totalPages,
                speed: currentSpeed
            )
        }
    }

    func onPageFailed(index: Int, error: Error) async {
        print("[SpiderInfoUpdater] Page \(index) failed: \(error)")
    }

    func onImageLimitReached() async {
        print("[SpiderInfoUpdater] Image limit (509) reached")
        await listener?.on509Error()
    }

    func onDiskFull() async {
        print("[SpiderInfoUpdater] ⚠️ 磁盘空间不足，暂停所有下载")
        await DownloadManager.shared.pauseAllDownloads()
        await listener?.onDiskFull()
    }

    func onDownloadProgress(downloaded: Int, total: Int) async {
        // SpiderQueen 目前不会调用它；保留协议实现，并按总量夹取，避免进度越界
        downloadedCount = min(max(0, downloaded), totalPages)
    }
}

// MARK: - DownloadListener (下载事件监听器)

public protocol DownloadListener: AnyObject, Sendable {
    /// 下载开始
    func onDownloadStart(gid: Int64, title: String) async

    /// 下载进度更新
    func onDownloadProgress(gid: Int64, title: String, downloaded: Int, total: Int, speed: Int64) async

    /// 下载完成
    func onDownloadFinish(gid: Int64, title: String, success: Bool) async

    /// 509错误
    func on509Error() async

    /// 磁盘空间不足
    func onDiskFull() async
}
