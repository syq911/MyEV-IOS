# 更新日志

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/) 规范。

## [1.4.2-custom] - 2026-10-02 · 诊断版

> ⚠️ 这是**诊断版**，不是功能版。目的只有一个：定位 1.4.1「一打开就闪退」的根因。
> 装回 1.4.0 可正常使用；本版用完即可被后续正式版替换。

### 🔍 新增：启动断点日志 + 崩溃捕获

- 新增 `LaunchDiagnostics`（`EhModels`，App 与各包共用）：把启动 / 下载 / 阅读关键步骤
  **同步写入** `Documents/EhViewerDiagnostics.log`，每条写完立即 flush ——
  崩溃前最后一条一定落盘，据此即可看出崩溃发生在哪一步。
- 安装 `NSSetUncaughtExceptionHandler`（记录异常名 / 原因 / 调用栈）与常见信号处理器
  （`SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGTRAP/SIGFPE`，记录一行标记）。
- 日志文件通过 `UIFileSharingEnabled` 暴露：可在「文件」App → 我的 iPhone → ehviewer apple
  直接取出，也可连电脑后用 Finder / iTunes 的「文件共享」拖出。
- 日志超过 512KB 会在下次启动时轮转，避免无限增长。

## [1.4.1-custom] - 2026-10-02

> 修两个用户实测反馈的问题：**后台下载几秒后自己停了**、**已下载的漫画每页还要转圈加载**。
> 仍是基于上游 v1.3.1 的定制分支，不含 v1.3.2 的任何改动。

### 🐞 修复：切后台几秒后下载变回「等待中」

根因不在系统，而在我们自己的代码：`beginBackgroundTask` 申请的 ~30 秒后台时间窗到期时，
过期处理器调用了 `pauseActiveIfNeeded()` —— 它会取消整条管线、**取消 nsurlsessiond 里正在跑的
后台传输**，并把状态刷成「等待中」。等于每次切后台，我们都在系统挂起进程的前一刻亲手掐断了下载。

- 后台时间窗到期不再暂停任何东西，只让进程正常挂起；传输继续由系统进程托管。
- 移除 `pauseActiveIfNeeded()`（手动暂停/删除的取消链路不受影响，仍按 gid 精确取消）。
- `BGProcessingTask` 从「申请了就 sleep 2 秒还回去」改成**持有式运行**：只要队列里还有任务就不下班，
  把系统给的几分钟真正用在下载上；过期只结束该任务，不暂停下载。
- 补 `setTaskCompleted` 一次性闸门，避免过期与正常收尾重复调用。

**从此后台下载的机制**：nsurlsessiond 托管传输 → 一批任务完成时系统唤醒 App → App 发起下一批 → 再次挂起。
这个循环可以一直自我维持，不需要 App 常驻运行（iOS 上也不可能）。

### 🐞 修复：下载管线的低概率假死

下载模式改用 GET 页面请求取图片地址（原先用 POST `showpage`）。POST 带 body，后台会话不支持，
只能回落到**前台**会话；若挂起瞬间所有 worker 恰好都在等 POST，就没有任何在途后台任务，
系统失去唤醒理由，管线会假死到用户手动打开 App。GET 走后台会话，下载模式从此 100% 由系统托管。
代价是每页多下载一个页面 HTML（几 KB~十几 KB）。

### ⚡ 优化：已下载漫画打开即读、翻页秒开

原先本地 `file://` 图片和网络图片走的是同一条管线：塞进 `URLSession.bytes` 逐字节迭代，
还要等「下载图片中 xx%」的伪进度跑完才解码。加上 iPhone 上预取窗口只有 **6 页**，
翻页稍快就超过了预取，于是每幅画都要先转圈。

- **本地文件走 ImageIO 直读**：`CGImageSourceCreateWithURL` 映射读取 + 降采样，不经 URLSession。
  没有进度圈、没有 Referer/UA/H@H 换节点/EhAPI 回退那套网络逻辑（本地文件用不上）。
- **本地画廊一次预取 20 页**（网络画廊仍守设备预算 4~6 页，不去锤服务器）。
- **常驻窗口跟着放大**（5 → 24 页），否则预取的页会被立刻淘汰、来回空转。
- **新增解码字节预算**（350MB）：长条漫单页降采样后仍可达几十 MB，只按页数淘汰守不住内存，
  超限时从离当前页最远的开始逐出（保住当前页 ±2）。
- 下载目录改为一次性枚举建立「页码 → 文件 URL」映射，省掉每页最多 4 次 `fileExists` 的 stat 开销。

### 🔍 诊断

新增统一日志（Console.app 连 iPhone，过滤 subsystem `Stellatrix.ehviewer-apple`）：

| Category | 看什么 |
|---|---|
| `BgTransport` | 「系统唤醒 App 处理后台会话事件」「后台传输完成 gid/page/bytes」→ 证明后台在传 |
| `BGTask` | BGProcessingTask 何时启动/收尾 |
| `Download` | 管线启动/结束、后台时间窗到期 |

### ⚠️ 已知限制（iOS 平台边界，非缺陷）

- **上划强杀 App / 重启手机**：系统会取消全部后台传输（Apple 限制，无法绕过）。
  重新打开 App 会自动从缺页续传，不重复下载已完成页。
- 后台/锁屏期间下载列表与灵动岛的进度是**跳变式**刷新（每次系统唤醒一批），不是平滑增长。
- 后台吞吐略低于前台（每批任务之间有系统唤醒间隔）。
- 部分蓝牙音频设备的音量键不改变系统音量，音量键翻页可能失效。
- 手机设置里开启「通用 → 后台 App 刷新 → EhViewer」可显著提升 BGProcessingTask 被调度的概率，
  让后台下载更快（不开也能靠后台会话继续，只是每批之间的唤醒间隔更长）。

## [1.4.0-custom] - 2026-10-02

> 本 fork 基于上游 [felixchaos/EhViewer-Apple](https://github.com/felixchaos/EhViewer-Apple) **v1.3.1** 定制开发，不是上游官方版本。
> 不含 v1.3.2 的任何改动——v1.3.2 引入的「首页/搜索触底闪退」在本版不存在。

### ✨ 新增与改进

#### 后台下载不中断（URLSession background）

- 下载链路从进程内 `URLSessionConfiguration.default` 改走 `URLSessionConfiguration.background`，
  传输由系统进程 `nsurlsessiond` 托管：**锁屏、切到其它 App、App 被挂起时下载继续进行**。
- 新增 `EhBackgroundTransport`（EhNetwork 包）桥接后台会话，对外仍是
  `async -> (Data, URLResponse)`，抓取引擎、限流、断点记录逻辑保持不变。
- 暂停 / 删除下载时真正取消对应的后台任务（不再只是停住界面进度）。
- 冷启动对账：取消孤儿任务后按磁盘记录续传——强杀 App 再打开会自动从缺失页继续，
  不重复下载已完成页。
- 不需要任何 entitlement 或 `UIBackgroundModes`，免费 Apple ID 签名不受影响。

#### 音量键翻页（重写）

- 旧实现用 250ms 时间窗区分「复位回声」与「用户按键」，导致必须按住更久才翻页、连按还会丢按；
  改为**按音量值过滤回声**，任何时刻的按键都立即受理。
- 入口移到「阅读器 → 齿轮 → 阅读设置 → 行为」，正式包可见
  （旧版被 `#if DEBUG` 编译剔除，用户根本找不到入口）。
- 支持「反转音量键方向」；在阅读设置里开关当场生效，无需退出重进。
- 退出阅读器时把系统音量还原为进入前的真实音量（修复旧版停在 50% 的问题）。
- 已知限制：部分蓝牙音频设备的音量键不改变系统音量，翻页可能失效。

#### 阅读器进度条拖动实时翻页

- 拖动过程中**每逢整数页码变化立即跳页**（垂直模式滚动到目标页、横向模式翻到目标页），
  不再等松手才提交；页码标签实时跟随。
- 仅在跨整数页时写 `@Observable` 状态，保留了 v1.3.1 的性能优化（本地 state、取消上一轮预加载），
  拖动全程保持流畅。

#### 搜索界面重做（对齐安卓 FooIbar 版）

- 搜索框聚焦后弹出面板：第一行 10 个分类 chips（选中的排前、使用分类色），
  第二行 语言 / 最低评分 / 页数 / 已删除 / 有种子 / 三个禁用过滤 chips。
- 语言不是独立 URL 参数，而是以 `language:xxx` 前缀并入 `f_search`（对齐安卓）；
  关键词已含 `language:` / `l:` / `gid:` 时不重复注入，避免双重过滤。
- 页数弹窗：输入 clamp（下限 0–1000，上限 0–2000）；校验失败
  （范围差 < 20、只填上限且 < 10）时提示错误且不关闭弹窗。
- 搜索记录一行一条：点击即搜（携带当前面板筛选）、`×` 删单条、「清除」全清。
- 详情页 / 列表的上传者名可点击 → `/uploader/<name>` 列表。
- 移除旧的高级搜索 sheet，其分类 / 语言 / 评分 / 页数能力全部并入新面板。

#### 列表触底加载

- v1.3.1 基线本身不含触底闪退 bug（该 bug 由 v1.3.2 引入，本分支禁止移植相关代码）。
- 触底去重逻辑抽成纯函数并补回归测试，防止未来复刻闪退。

### ⚠️ 已知行为与限制

- **上划强杀 App**：系统会取消后台传输（Apple 限制，无法绕过）；重新打开 App 会自动续传。
- 手机重启同理：重启后打开 App 续传。
- 音量键翻页期间系统音量会被暂时吸附到 50% 作为基准（退出阅读器时还原），期间听音乐不会被打断。
- 语言筛选混在关键词里，从快速搜索 / 历史还原时无法反解语言选项（与安卓行为一致）。
- 分应用代理（非系统级 VPN）若未包含本 App，后台下载可能失败；系统级代理不受影响。

### 🏗️ 构建与分发

- 新增 GitHub Actions `Build IPA` 流水线：macOS 云构建产出**无签名 ipa**，
  用户用 AltStore / Sideloadly 自签安装（免费账号 7 天重签一次，数据不丢）。
- 推送 `v*` tag 时自动创建 GitHub Release 并上传 ipa。

## [1.3.1] - 2026-08-28

### ⚡ 性能优化

#### 预览页（查看全部预览）

- **精灵图不再重复解码** — E-Hentai 的普通预览是一张大图里排 ~20 个缩略图。
  原实现每个格子各自把**整张**精灵图解码一遍，20 个格子就是 20 次全图解码、20 份内存。
  新增 `SpriteSheetCache`：按 URL 只解码一次，并发请求自动合并
- **裁剪结果缓存** — 原先 `cropSprite` 写在 `body` 里，SwiftUI 每次重新求值都要重做一次
  CoreGraphics 裁剪；现在裁剪结果按「URL + 区域」缓存，`body` 只做一次查找
- **解码移出主线程** — 精灵图解码原本在 `onAppear` 里同步执行，直接掉帧
- **分页触发改为哨兵** — 原先每个格子都挂 `onAppear` 比较尾部位置并可能起 Task，
  改为仅在触底哨兵出现时拉取下一页

#### 图片加载（列表 / 预览 / 封面通用）

- **`CachedAsyncImage` 解码移出主线程并降采样** — 它是 View，`load()` 天然跑在 MainActor 上，
  三处 `PlatformImage(data:)` 全是主线程全尺寸解码。改用 ImageIO 在 detached 任务里
  直接解出目标尺寸缩略图，既不占主线程，也不会把 4000px 原图整张位图留在内存

#### 阅读器

- **拖动进度条不再卡顿** — `currentPage` 是 `@Observable`，原先滑块每移动一像素就写一次，
  导致整个阅读器（ScrollView + 全部页视图）重新求值。改为拖动期间只更新本地 state，
  松手才提交；页码标签实时显示拖动目标页
- **翻页不再等待预加载** — `onPageChange` 原先 `await preload(...)`，
  而预加载会把整个 TaskGroup 等完（默认 5 页 = 6 次网络往返），翻页手势要等它结束才算完成。
  改为后台推进，并在下次翻页时取消上一轮
- **淘汰不再整份拷贝字典** — `evictDistantPages` 每次翻页都拷贝一遍 `cachedImages`，
  大画廊里几十项白拷；改为原地删除

#### 动态预加载

- **方向感知** — 顺着翻页方向多铺，逆向只留少量回看余量
- **由近及远分批** — 原先一次性全丢进 TaskGroup，第 6 页可能比第 1 页先回来；
  改为按距离排序分批发出，并在批次间检查取消
- **分平台预算** — macOS 12 页、iPad 7~10 页、iPhone 4~6 页（按物理内存分档）；
  淘汰保留半径跟随预加载窗口，避免刚预取的页被立刻扔掉

## [1.3.0] - 2026-08-27

### 🐛 修复线上 issue

- **下载管理删除/恢复任务闪退** (#8 问题四) — `executeDownload` 跨 `await` 持有数组索引，挂起期间删除任务导致越界；改为全程按 gid 定位 + `runningGid` 令牌校验
- **暂停/删除停不下正在跑的下载** — `activeTask` 是值拷贝，`spider` 是之后才写进队列的，`activeTask?.spider` 恒为 nil，`cancelAll()` 一直调在空值上
- **最低评分过滤失效** (#8 问题三) — 首页模式构建 URL 时丢掉了 `advanceSearch/minRating/pageFrom/pageTo`，无关键字时评分过滤静默失效
- **画廊列表循环** (#8 问题一) — 缓存命中未恢复分页游标、缓存 key 未含筛选条件、ptt 末页回绕的 `nextHref` 未丢弃、快速搜索未记录游标
- **下载完成仍无法离线阅读** (#8 问题二) — `downloadQueue` 改为 lazy 同步加载（消除启动竞态）；本地读取由"整本完成"放宽为逐页判断
- **阅读时 TLS 错误 / 加载不出图片** (#6) — 阅读器不再用裸 `URLSession` 直连，页面请求走 `EhAPI`（含域名前置回退）；新增 H@H 节点切换重试（`?nl=`）
- **外置翻页器无法翻页** (#4) — 阅读器补上 `focusable`（iOS 上 `onKeyPress` 依赖焦点）、PageUp/PageDown/Home/End 不再限 macOS、实现音量键翻页

### ✨ 收尾补齐

- **IP 封禁提示** (#1) — 服务端返回封禁页时是正常 200，解析出 0 条画廊，界面此前是一片空白；
  新增 `EhError.ipBanned` 检测并带出解封倒计时，错误页给出「换节点」这一唯一有效动作
- **分享已下载画廊** (#2) — 下载列表长按「分享 (打包为 zip)」，用 `NSFileCoordinator`
  的 `.forUploading` 生成 zip 后唤起系统分享，无需引入第三方压缩库
- **账号资料与配额** — 头像 / UID / 图片配额进度条 / 花 GP 重置；
  `getHomeDetail` 与 `resetLimit` 此前从无调用方
- **自定义 Hosts** — 对齐 Android HostsActivity；顺带补上持久化（原来只在内存里，重启即丢）

### 🐛 阅读器按键回归修复

- **切换阅读方向弹出软键盘** — 上一版为支持外置翻页器给阅读器加了 SwiftUI `.focusable()`，
  但在 iOS 上程序化聚焦一个普通视图会让它成为文本输入目标；打开 Picker / Menu 时
  UIKit 为"输入首字母跳选"开文本输入会话，就把软键盘调了出来。
  改为走 UIKit responder chain (`KeyCommandCatcher`)，并给它一个零高度 `inputView`：
  按键照收，键盘不再出现。
- **方向键含义与点击区域不一致** — 左方向键原本等同"右侧点击区"，和 `handleTapZone`
  以及 Android 的 `KEYCODE_DPAD_LEFT` 都相反，现已对齐

### 🔄 对齐 Android 上游 (2026-02-12 → 2026-08-21)

- **种子解析重写** — 按 `<form>` 分块解析，新增上传时间 `TorrentInfo.posted`，正则容忍 EH 的换行排版
- **可编辑评论接口** — 新增 `geteditcomment` API + `GetEditCommentParser`，取回评论原始 BBCode
- **搜索词换行过滤** — 粘贴带 `\r\n` 的标签不再拆断 `artist:foo` 语法
- **SpiderInfo 头部读取** — 新增 `readHeader`，扫描下载目录时不再逐本解析上万条 pToken；补文件体积上限防 OOM
- **阅读时同步下载** — 新增设置项，浏览未下载画廊时把看过的图片存进下载目录

### ✨ 登录页重做

- **网页登录提升为主操作** — 账号密码登录经常被 Cloudflare 人机验证拦下，却一直占着主位；现在主推内嵌浏览器登录，三种方式各带一句说明
- **Cookie 支持整段粘贴** — 不再要求手工拆成三个字段，分号分隔 / 请求头 / Cookie 导出插件的 JSON 都能识别，实时显示识别结果（值做掩码）
- **访客入口改为正式按钮** — 原来是灰色小字，看起来不像能点；并说明访客的功能限制
- iOS 用系统 `PasteButton`，避免每次粘贴都弹授权框

### 🚀 功能补齐 (按审查排期)

- **归档 / H@H 下载界面** (issue #3) — 详情页新增入口，H@H 规格派发 + 归档直链下载
- **种子列表** — 文件名、上传时间、下载 / 分享 / 复制链接
- **15 个空转的设置项全部接上逻辑** — 其中 5 项靠新增的 `EhConfigSync` 写入 uconfig Cookie（`EhConfig` 序列化器早就写好但从没被调用）；`mediaScan` 是 Android 概念，直接删除
- **评论发表 / 编辑** — 编辑先经 `geteditcomment` 取回原始 BBCode，避免把自己的排版改没
- **下载列表按标签搜索** — 详情加载时把标签写入 `galleryTags` 表（建了表但从没写过），搜索按空格拆词做 AND 匹配
- **标签选择器** — 按命名空间分组浏览，点选自动拼成 `f:xxx$` 语法
- **我的标签 / 站内公告** — 原生页面，替掉设置页里"打开网页"的临时做法
- **订阅列表独立入口** — 新增底部标签页，走 `/watched`

### 🧪 测试

- 新增 19 个单元测试（分页游标解析、高级搜索 URL、种子解析、可编辑评论、搜索词清洗）
- 修复 `ehviewer apple` scheme 缺少 TestAction、测试文件被编进 App target 两个工程配置问题

---

## [1.2.1] - 2026-02-20

### 🔧 阅读器体验优化 + ExHentai 修复

#### Bug 修复
- **修复搜索失效** — `@Observable` 宏使 `didSet` 在 `init()` 中也会触发，导致 `siteChangedNotification` 误刷新列表覆盖搜索结果
- **修复切换 ExHentai 后重启回退** — 移除 `validateExHentaiAccess()` 对 igneous Cookie 的错误检查，已登录用户可自由切换站点（对齐 Android）
- **修复 ExHentai 站点切换无效** — `siteBaseURL` 不再依赖 igneous Cookie（鸡生蛋死循环），改为检查登录 Cookie
- **修复下载进度卡在 0%** — `URLSession.download(for:delegate:)` 不转发进度回调，改用 `bytes(for:)` 流式下载 + 16KB 分块写入
- **修复纵向滚动阅读器卡顿** — 轻量化图片预处理、100ms 滚动去抖、节流进度更新

#### 新功能
- **GIF 动图支持** — 阅读器和缩略图支持 GIF 动画播放
- **应用内检查更新** — 设置页新增「检查更新」，自动/手动检查 GitHub Releases 最新版本
- **纯黑阅读器背景** — 阅读器背景改为纯黑色，移除 CIAreaAverage 计算
- **默认纵向滚动** — 阅读方向默认改为从上到下纵向滚动

#### 改进
- 站点切换后列表自动刷新（对齐 Android 行为）
- ExHentai 可用提示不再重复弹出（已在 ExHentai 时跳过）

---

## [1.2.0] - 2026-02-18

### 🔧 阅读器手势与导航全面修复

#### Bug 修复
- **修复图片加载后手势失效** — SwiftUI ScrollView 不走 UIKit failure chain，改用 `panGestureRecognizer.isEnabled` 彻底禁用内层手势竞争
- **修复缩略图预览进入阅读器页面错位** — `lazyCurrentPage` 未同步 `initialPage`，`.onChange` 不触发初始值导致 ScrollView 始终显示第 0 页
- **修复多层手势冲突** — 重写 `gestureRecognizerShouldBegin()` 为三级优先级逻辑：边缘返回 > 无滚动透传 > 边缘翻页
- **修复翻页手势只触发一次** — 移除错误的 `panGestureRecognizer.isEnabled = false` 设置
- **修复 FaceID 认证无限循环** — SecurityView 认证状态机修复
- **修复阅读器四个关键问题** — 滑动手势冲突、垂直模式点击区域、页码重复显示、FaceID 崩溃

#### 性能优化
- `@ObservationIgnored` 标记非 UI 属性，减少不必要的视图重绘
- 批量驱逐远距离页面缓存
- 翻页去抖 80ms debounce

---

## [1.1.0] - 2026-02-18

### 🚀 首个正式 Release

提供 iPhone / iPad / Mac 多平台安装包。

#### Bug 修复
- 修复左右翻页手势丢失 — ZoomableScrollView 初始化正确禁用内层滚动
- 修复标签搜索列表点击画廊导航循环和错乱
- 修复启动页面设置无法反映到 iPhone 底部导航栏
- 修复热门列表点击画廊报错
- 修复启动页面 Picker 下拉菜单无法点击
- 修复 HistoryView 重复注册 navigationDestination 警告
- 修复 ReaderViewModel Main actor isolation 构建错误

#### 架构改进
- NavigationLink 统一采用 value-based API
- Tab.bottomTabs 改为动态计算属性
- maxDecodePixelSize 使用固定值避免 actor isolation 问题

#### 并发安全
- SpiderDen 静态可变状态 NSLock 保护
- DownloadManager.SpiderInfoUpdater 迁移为 actor
- GalleryDetailViewModel 标注 @MainActor
- AppSettings UI 属性支持 @Observable

#### 内存优化
- NSCache 容量自适应设备内存 (80–400 MB)
- 翻页时主动驱逐远距离页面

---

## [0.1.0] - 2026-02-15

### 🎉 首次发布

#### 新功能
- **画廊浏览** — 支持 E-Hentai / ExHentai 画廊列表、热门、最新
- **排行榜** — TopList 排行榜浏览
- **高级搜索** — 分类筛选、关键词、标签搜索
- **快速搜索** — 搜索条件收藏与快速调用
- **收藏管理** — 多文件夹云端收藏同步
- **浏览历史** — 本地浏览记录管理
- **画廊详情** — 标签、评论、预览图、元数据展示
- **图片阅读器** — 横向翻页 / 纵向滚动双模式
  - 缩放手势支持（水平/纵向模式）
  - 滑动返回手势
  - HUD 叠加层（电量、时间、进度）
- **下载管理** — 后台下载、断点续传、进度通知
- **多种登录方式** — 账号密码、网页登录、Cookie 导入、跳过登录
- **安全保护** — Face ID / Touch ID / 密码锁
- **站点切换** — E-Hentai / ExHentai 一键切换
- **设置中心** — 阅读器偏好、网络配置、数据管理

#### 网络
- Domain Fronting 回退机制
- DNS over HTTPS 支持
- Cloudflare 403 检测与友好提示
- WebView 原生 UA 登录（兼容 Cloudflare Turnstile）

#### 平台支持
- iOS 17+ / iPadOS 17+
- macOS 14+ (Sonoma)

#### 架构
- Swift Package Manager 模块化架构（EhCore、EhNetwork、EhParser、EhSpider、EhDownload、EhUI）
- Swift 6 严格并发安全
- SwiftUI 原生构建
