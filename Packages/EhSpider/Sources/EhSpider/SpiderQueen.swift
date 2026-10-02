import Foundation
import EhModels
import EhSettings
import EhParser
import EhBackgroundTransport

// MARK: - SpiderQueen (对应 Android SpiderQueen.java)
// 画廊图片加载引擎核心，使用 Swift Actor 保证线程安全
// 原始 Android 版本使用 AsyncTask + Thread 池，此处使用 structured concurrency

public actor SpiderQueen {

    // MARK: - 状态常量 (与 Android 保持一致)

    public static let stateNone    = 0
    public static let stateLoading = 1
    public static let stateFinish  = 2
    public static let stateFailed  = 3

    public enum Mode: Sendable {
        case read      // 阅读模式 (顺序预加载)
        case download  // 下载模式 (全量下载)
    }

    // MARK: - 属性

    public let galleryInfo: GalleryInfo
    public private(set) var spiderInfo: SpiderInfo
    private var mode: Mode
    private var pageStates: [Int]       // 每页的加载状态
    private var imageUrls: [String?]    // 每页的图片 URL
    private var showKey: String?        // showpage API 的 showKey
    private var activeTasks: [Int: Task<Void, Never>] = [:]

    /// 并发下载数 — 从 AppSettings 读取用户设置 (对齐 Android SpiderQueen.mWorkerPool 大小)
    /// 上限与 EhRateLimiter 的全局图片并发上限 (5) 保持一致：超出的话多出来的 worker 会挂在
    /// acquireImageSlot 的 continuation 上，而该等待不支持取消 —— 暂停时整条下载链会卡住。
    private var maxConcurrent: Int {
        min(AppSettings.shared.multiThreadDownload, 5)
    }

    /// 传输层 —— 走 URLSession background (由系统进程 nsurlsessiond 托管)，
    /// 锁屏 / 切后台 / App 挂起时传输继续进行。详见 EhBackgroundTransport。
    /// POST 等带 body 的请求由传输层内部自动回落到前台会话。
    private var transport: EhBackgroundTransport { EhBackgroundTransport.shared }

    /// 是否已请求停止 (暂停 / 删除下载 / 退出阅读器)。
    /// startDownload 的 TaskGroup 子任务不在 activeTasks 里，只能靠它 + 传输层的
    /// 按 gid 取消来真正掐断在途下载。
    private var isStopped = false

    /// 在全局速率限制下发起网络请求 — 防止跨实例并发失控 (V-09)
    /// 所有 SpiderQueen 实例共享同一个 EhRateLimiter，全局最多 5 个并发图片请求
    private func rateLimitedData(
        for request: URLRequest,
        context: EhBackgroundTransport.TaskContext? = nil
    ) async throws -> (Data, URLResponse) {
        await EhRateLimiter.shared.acquireImageSlot()
        do {
            let result = try await transport.data(for: request, context: context)
            await EhRateLimiter.shared.releaseImageSlot()
            return result
        } catch {
            await EhRateLimiter.shared.releaseImageSlot()
            throw error
        }
    }

    /// 图片存储管理器 (对应 Android SpiderDen)
    private let spiderDen: SpiderDen

    /// 回调通知
    public weak var delegate: SpiderDelegate?

    // MARK: - 生命周期

    public init(galleryInfo: GalleryInfo, spiderInfo: SpiderInfo, mode: Mode = .read) {
        self.galleryInfo = galleryInfo
        self.spiderInfo = spiderInfo
        self.mode = mode
        self.spiderDen = SpiderDen(galleryInfo: galleryInfo)

        let pageCount = galleryInfo.pages
        self.pageStates = Array(repeating: Self.stateNone, count: pageCount)
        self.imageUrls = Array(repeating: nil, count: pageCount)

        // 设置 SpiderDen 模式
        Task {
            await spiderDen.setMode(mode == .download ? .download : .read)
        }
    }

    // MARK: - 公共接口

    /// 请求加载指定页面 (对应 Android request)
    public func request(index: Int, force: Bool = false) {
        guard index >= 0 && index < pageStates.count else { return }

        if !force && (pageStates[index] == Self.stateLoading || pageStates[index] == Self.stateFinish) {
            return
        }

        pageStates[index] = Self.stateLoading

        // 取消旧任务
        activeTasks[index]?.cancel()

        // 启动新任务
        let task = Task { [weak self] in
            guard let self = self else { return }
            await self.loadPage(index: index)
        }
        activeTasks[index] = task
    }

    /// 批量预加载 (对应 Android preloadPages)
    public func preload(around index: Int, range: Int = 5) {
        let start = max(0, index - 1)
        let end = min(pageStates.count, index + range)

        for i in start..<end {
            request(index: i)
        }
    }

    /// 开始下载模式 (对应 Android setMode(MODE_DOWNLOAD))
    /// 使用 TaskGroup 实现并发控制，等待所有页面下载完成后再返回
    public func startDownload() async {
        mode = .download
        diag("SpiderQueen.startDownload: 进入 gid=\(galleryInfo.gid) 页数=\(pageStates.count)")

        // 收集需要下载的页面索引
        var pagesToDownload: [Int] = []
        for i in 0..<pageStates.count {
            if pageStates[i] != Self.stateFinish {
                pagesToDownload.append(i)
            }
        }

        guard !pagesToDownload.isEmpty else {
            diag("SpiderQueen.startDownload: 无待下载页，返回")
            return
        }
        diag("SpiderQueen.startDownload: 待下载 \(pagesToDownload.count) 页")

        // 使用 TaskGroup 配合信号量控制并发数 (对齐 Android SpiderQueen.mWorkerPool)
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            var index = 0

            while index < pagesToDownload.count {
                // ★ 暂停 / 删除后立刻停止派发新页面，并取消组内在途任务
                if isStopped {
                    group.cancelAll()
                    break
                }
                if inFlight < maxConcurrent {
                    let pageIndex = pagesToDownload[index]
                    pageStates[pageIndex] = Self.stateLoading
                    group.addTask { [weak self] in
                        guard let self = self else { return }
                        await self.loadPage(index: pageIndex)
                    }
                    inFlight += 1
                    index += 1
                } else {
                    // 等待一个任务完成再继续
                    await group.next()
                    inFlight -= 1
                }
            }

            // 等待剩余任务完成
            await group.waitForAll()
        }
        diag("SpiderQueen.startDownload: 全部结束 gid=\(galleryInfo.gid)")
    }

    /// 获取页面状态
    public func getPageState(_ index: Int) -> Int {
        guard index >= 0 && index < pageStates.count else { return Self.stateNone }
        return pageStates[index]
    }

    /// 获取页面图片 URL (远程或本地)
    public func getImageUrl(_ index: Int) -> String? {
        guard index >= 0 && index < imageUrls.count else { return nil }
        return imageUrls[index]
    }

    /// 获取本地图片文件 URL (用于显示已下载的图片)
    public func getLocalImageUrl(_ index: Int) async -> URL? {
        return await spiderDen.getImageFileURL(index: index)
    }

    /// 读取图片数据 (从缓存或下载目录)
    public func getImageData(_ index: Int) async -> Data? {
        return await spiderDen.read(index: index)
    }

    /// 取消所有任务（暂停 / 删除下载 / 退出阅读器）
    /// ★ 必须同时掐断传输层的在途请求：startDownload 的 TaskGroup 子任务不在
    ///   activeTasks 中，仅靠 task.cancel() 停不下已经在跑的下载。
    public func cancelAll() {
        isStopped = true
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
        transport.cancelTasks(gid: galleryInfo.gid)
    }

    /// 设置回调代理
    public func setDelegate(_ delegate: SpiderDelegate?) {
        self.delegate = delegate
    }

    /// 获取当前 SpiderInfo (包含已更新的 pTokenMap)
    public func getSpiderInfo() -> SpiderInfo {
        return spiderInfo
    }

    /// 更新 pToken (用于外部添加)
    public func updatePToken(index: Int, token: String) {
        spiderInfo.pTokenMap[index] = token
    }

    // MARK: - 核心加载管线 (对应 Android SpiderQueen.run)

    /// 加载单页图片 (对齐 Android SpiderWorker.downloadImage 最多重试 5 次)
    /// 管线: 检查缓存 → 获取 pToken → 构建页面 URL → 获取图片 URL → 下载图片 → 存储
    private func loadPage(index: Int) async {
        let maxRetries = 5
        var lastError: Error?
        diag("loadPage[\(index)]: 开始")

        // 已被暂停 / 删除 → 直接放弃这一页（保持 stateNone，恢复时重下）
        if isStopped {
            pageStates[index] = Self.stateNone
            activeTasks.removeValue(forKey: index)
            return
        }

        for attempt in 0..<maxRetries {
            if isStopped {
                pageStates[index] = Self.stateNone
                activeTasks.removeValue(forKey: index)
                return
            }
            do {
                // 0. 检查是否已在缓存/下载目录中 (快速路径)
                if await spiderDen.contain(index: index) {
                    diag("loadPage[\(index)]: 本地已有，跳过")
                    pageStates[index] = Self.stateFinish
                    if let fileUrl = await spiderDen.getImageFileURL(index: index) {
                        imageUrls[index] = fileUrl.absoluteString
                        await delegate?.onPageLoaded(index: index, imageUrl: fileUrl.absoluteString)
                    }
                    activeTasks.removeValue(forKey: index)
                    return
                }

                // 1. 获取 pToken
                let pToken = try await getPToken(for: index)

                // 2. 获取图片 URL
                let imageUrl: String
                let originImageUrl: String?
                // ★ 下载模式统一走 GET 页面请求（对齐 1.4.1 计划 P1-C）：
                //   POST showpage 在 EhBackgroundTransport 里只能回落到**前台**会话
                //   （后台会话的 downloadTask 不支持 request body），App 挂起时若所有
                //   worker 恰好都卡在 POST 上就没有任何在途后台任务，系统失去唤醒理由，
                //   整条下载管线会假死到用户手动打开 App。GET 走后台会话（nsurlsessiond），
                //   随挂起继续传输，从此下载模式 100% 由系统进程托管。
                //   阅读模式保持原有 showpage API：前台交互，省一次 HTML 下载。
                if mode == .download || showKey == nil {
                    let result = try await fetchPageHtml(gid: galleryInfo.gid, index: index, pToken: pToken)
                    if let newShowKey = result.showKey { showKey = newShowKey }
                    imageUrl = result.imageUrl
                    originImageUrl = result.originImageUrl
                } else {
                    let currentShowKey = showKey ?? ""
                    let result = try await fetchPageApi(
                        gid: galleryInfo.gid,
                        index: index,
                        pToken: pToken,
                        showKey: currentShowKey
                    )
                    if let newShowKey = result.showKey {
                        showKey = newShowKey
                    }
                    imageUrl = result.imageUrl
                    originImageUrl = result.originImageUrl
                }

                // 2.5 如果用户启用了"下载原始图片"且有原图 URL，优先使用 (对齐 Android downloadOriginImage)
                let finalImageUrl: String
                if AppSettings.shared.downloadOriginImage,
                   let origin = originImageUrl, !origin.isEmpty {
                    finalImageUrl = origin
                } else {
                    finalImageUrl = imageUrl
                }

                // 3. URL 有效性
                guard !finalImageUrl.isEmpty else {
                    throw SpiderError.emptyImageUrl
                }
                diag("loadPage[\(index)]: 取得图片URL \(finalImageUrl.prefix(72))")

                // 4. 509 检测
                if finalImageUrl.contains("509.gif") || finalImageUrl.contains("509s.gif") {
                    pageStates[index] = Self.stateFailed
                    await delegate?.onImageLimitReached()
                    activeTasks.removeValue(forKey: index)
                    return
                }

                // 5. 下载图片并存储
                diag("loadPage[\(index)]: 开始下载图片")
                try await downloadAndStore(imageUrl: finalImageUrl, index: index)
                diag("loadPage[\(index)]: 图片下载完成")

                // 6. 保存结果
                imageUrls[index] = finalImageUrl
                pageStates[index] = Self.stateFinish
                await delegate?.onPageLoaded(index: index, imageUrl: finalImageUrl)
                activeTasks.removeValue(forKey: index)
                return

            } catch is CancellationError {
                pageStates[index] = Self.stateNone
                activeTasks.removeValue(forKey: index)
                return
            } catch {
                lastError = error
                diag("loadPage[\(index)]: 第\(attempt + 1)次失败 \(error)")
                // showKey 可能过期，清除后下次使用 HTML 方式
                if attempt > 0 { showKey = nil }
                // 使用用户配置的下载延迟 (downloadDelay, 毫秒) 作为基础，
                // 结合指数退避: base * 2^attempt (对齐 Android SpiderQueen 重试策略)
                if attempt < maxRetries - 1 {
                    let userDelay = max(500, AppSettings.shared.downloadDelay)
                    let delay = UInt64(userDelay) * UInt64(pow(2.0, Double(attempt))) * 1_000_000
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }

        // 所有重试失败
        diag("loadPage[\(index)]: 重试耗尽，标记失败")
        pageStates[index] = Self.stateFailed
        await delegate?.onPageFailed(index: index, error: lastError ?? SpiderError.networkError)
        activeTasks.removeValue(forKey: index)
    }

    /// 下载图片并存储到 SpiderDen (对齐 Android: 共享 session 保持 cookies)
    private func downloadAndStore(imageUrl: String, index: Int) async throws {
        guard let url = URL(string: imageUrl) else {
            throw SpiderError.invalidUrl
        }

        // 使用带 cookies 的 session 下载图片
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await rateLimitedData(
            for: request,
            context: .init(gid: galleryInfo.gid, page: index)
        )

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SpiderError.networkError
        }

        // 检查数据有效性 (反劫持检测 - 纯文本响应)
        if data.count < 1000 {
            // 检查是否为纯文本（可能被劫持）
            if let text = String(data: data, encoding: .utf8),
               text.contains("<html") || text.contains("<!DOCTYPE") {
                throw SpiderError.antiHijackDetected
            }
        }

        // 从 URL 或 Content-Type 获取扩展名
        let ext = getImageExtension(from: imageUrl, response: httpResponse)

        // 存储到 SpiderDen（先检查磁盘空间）
        if !SpiderDen.hasSufficientDiskSpace(bytes: Int64(data.count) + 10 * 1024 * 1024) {
            // 磁盘满: 通知代理暂停所有下载，不再重试当前页
            await delegate?.onDiskFull()
            throw SpiderError.diskFull
        }

        let success = await spiderDen.write(data: data, index: index, extension: ext)
        if !success {
            throw SpiderError.storageFailed
        }
    }

    /// 获取图片扩展名
    private func getImageExtension(from url: String, response: HTTPURLResponse) -> String {
        // 从 URL 提取
        if let urlObj = URL(string: url) {
            let ext = urlObj.pathExtension.lowercased()
            if !ext.isEmpty && SpiderDen.supportedExtensions.contains(".\(ext)") {
                return ".\(ext)"
            }
        }

        // 从 Content-Type 推断
        if let contentType = response.value(forHTTPHeaderField: "Content-Type") {
            if contentType.contains("jpeg") || contentType.contains("jpg") {
                return ".jpg"
            } else if contentType.contains("png") {
                return ".png"
            } else if contentType.contains("gif") {
                return ".gif"
            } else if contentType.contains("webp") {
                return ".webp"
            }
        }

        return ".jpg" // 默认
    }

    // MARK: - pToken 管理

    /// 获取指定页面的 pToken (对齐 Android SpiderQueen.getPTokenFromInternet)
    private func getPToken(for index: Int) async throws -> String {
        // 优先从 SpiderInfo 缓存获取
        if let token = spiderInfo.pTokenMap[index] {
            return token
        }

        // 从网络获取: 请求画廊详情页对应的分页来获取 pToken
        // 每页详情页显示 20 个预览缩略图，pToken 包含在预览链接中
        let detailPage = index / 20
        let site = AppSettings.shared.gallerySite
        let siteUrl = EhURL.host(for: site)
        let urlStr = "\(siteUrl)g/\(galleryInfo.gid)/\(galleryInfo.token)/\(detailPage > 0 ? "?p=\(detailPage)" : "")"
        guard let url = URL(string: urlStr) else {
            throw SpiderError.invalidUrl
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue(EhURL.referer(for: site), forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        let (data, _) = try await rateLimitedData(
            for: request,
            context: .init(gid: galleryInfo.gid, page: index)
        )
        let html = String(data: data, encoding: .utf8) ?? ""

        // 从预览链接中提取 pTokens: /s/PTOKEN/GID-PAGE
        let pattern = try! NSRegularExpression(pattern: #"/s/([0-9a-f]+)/\d+-(\d+)"#)
        let matches = pattern.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for m in matches {
            guard let ptRange = Range(m.range(at: 1), in: html),
                  let pnRange = Range(m.range(at: 2), in: html) else { continue }
            let pt = String(html[ptRange])
            let pn = Int(html[pnRange]) ?? 0
            spiderInfo.pTokenMap[pn - 1] = pt  // 1-based → 0-based
        }

        // 再次检查
        if let token = spiderInfo.pTokenMap[index] {
            return token
        }

        throw SpiderError.pTokenNotFound
    }

    // MARK: - 网络请求

    /// 通过 GET 获取页面 HTML (首次, 获取 showKey)
    private func fetchPageHtml(gid: Int64, index: Int, pToken: String) async throws -> PageResult {
        let site = AppSettings.shared.gallerySite
        let urlString = EhURL.pageUrl(gid: gid, index: index, pToken: pToken, site: site)
        guard let url = URL(string: urlString) else {
            throw SpiderError.invalidUrl
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(EhURL.referer(for: site), forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await rateLimitedData(
            for: request,
            context: .init(gid: galleryInfo.gid, page: index)
        )

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SpiderError.networkError
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw SpiderError.invalidResponseData
        }

        let result = try GalleryPageParser.parse(html)
        return PageResult(
            imageUrl: result.imageUrl,
            showKey: result.showKey,
            skipHathKey: result.skipHathKey,
            originImageUrl: result.originImageUrl
        )
    }

    /// 通过 POST API 获取图片 URL (showpage)
    private func fetchPageApi(gid: Int64, index: Int, pToken: String, showKey: String) async throws -> PageResult {
        let site = AppSettings.shared.gallerySite
        guard let url = URL(string: EhURL.apiUrl(for: site)) else {
            throw SpiderError.invalidUrl
        }

        let jsonBody: [String: Any] = [
            "method": "showpage",
            "gid": gid,
            "page": index + 1,   // 服务端 1-based
            "imgkey": pToken,
            "showkey": showKey
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: jsonBody)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(EhURL.referer(for: site), forHTTPHeaderField: "Referer")
        request.setValue(EhURL.origin(for: site), forHTTPHeaderField: "Origin")
        request.httpBody = jsonData
        request.timeoutInterval = 15

        let (data, response) = try await rateLimitedData(
            for: request,
            context: .init(gid: galleryInfo.gid, page: index)
        )

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SpiderError.networkError
        }

        let result = try GalleryPageApiParser.parse(data)
        return PageResult(
            imageUrl: result.imageUrl,
            showKey: result.showKey,
            skipHathKey: result.skipHathKey,
            originImageUrl: result.originImageUrl
        )
    }

    private struct PageResult {
        var imageUrl: String
        var showKey: String?
        var skipHathKey: String?
        var originImageUrl: String?
    }
}

// MARK: - SpiderDelegate

public protocol SpiderDelegate: AnyObject, Sendable {
    func onPageLoaded(index: Int, imageUrl: String) async
    func onPageFailed(index: Int, error: Error) async
    func onImageLimitReached() async
    func onDownloadProgress(downloaded: Int, total: Int) async
    func onDiskFull() async
}

// MARK: - 错误

public enum SpiderError: LocalizedError, Sendable {
    case pTokenNotFound
    case emptyImageUrl
    case imageLimitReached
    case antiHijackDetected
    case invalidUrl
    case networkError
    case invalidResponseData
    case notImplemented
    case storageFailed
    case diskFull

    public var errorDescription: String? {
        switch self {
        case .pTokenNotFound: return "pToken not found"
        case .emptyImageUrl: return "Empty image URL"
        case .imageLimitReached: return "509 Image limit reached"
        case .antiHijackDetected: return "Anti-hijack: pure text response"
        case .invalidUrl: return "Invalid URL"
        case .networkError: return "Network request failed"
        case .invalidResponseData: return "Invalid response data"
        case .notImplemented: return "Not implemented"
        case .storageFailed: return "Failed to save image to disk"
        case .diskFull: return "磁盘空间不足，无法保存图片"
        }
    }
}
