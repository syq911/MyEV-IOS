//
//  BackgroundDownloadBridge.swift
//  EhDownload
//
//  App target 没有直接依赖 EhBackgroundTransport 这个 SPM product（新增 product 需要改
//  project.pbxproj，本工程明令禁止）。这里用 EhDownload 作为中转，把后台会话的入口
//  暴露给 App 层，避免动工程文件。
//

import Foundation
import EhBackgroundTransport

public enum BackgroundDownloadBridge {

    /// 转发 `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    public static func handleBackgroundSessionCompletion(_ handler: @escaping () -> Void) {
        EhBackgroundTransport.shared.handleBackgroundSessionCompletion(handler)
    }

    /// 取消所有在途的后台下载任务（暂停 / 删除下载时调用）
    public static func cancelAllInFlightTasks() {
        EhBackgroundTransport.shared.cancelAllTasks()
    }

    /// 冷启动对账：清掉上一条进程残留的孤儿后台任务。
    /// 真正的续传由磁盘 .ehviewer 记录驱动（DownloadManager.resumeAllWaiting）。
    public static func reconcileOrphanTasks() {
        EhBackgroundTransport.shared.reconcileOrphanTasks()
    }
}