//
//  BackgroundKeepAlive.swift
//  ehviewer apple
//
//  【对照实验用】静音音频保活。
//
//  原理：加 UIBackgroundModes: audio，用 AVAudioSession(.playback) + 无限循环播放一段
//  全 0 的静音音频（volume=0）。系统会认为 App 正在播放音频，从而**不让进程挂起**，
//  下载流水线就能像前台一样持续跑。
//
//  ⚠️ 这是非官方做法：Apple 明确要求后台音频必须播放「可听见」的内容，静音保活违反该条款，
//  且更耗电、被系统回收后不会再自动拉起。仅用于和官方 BGContinuedProcessingTask 做效果对比。
//

#if os(iOS)
import Foundation
import AVFoundation
import EhModels
import EhSettings
import EhDownload
#if canImport(os)
import os
#endif

/// 静音音频保活器（单例，主线程使用）
@MainActor
final class BackgroundKeepAlive {

    static let shared = BackgroundKeepAlive()

    private var player: AVAudioPlayer?
    private var monitor: Task<Void, Never>?
    private var isActive = false

    private init() {}

    /// 当前是否处于保活状态（供诊断/UI 读取）
    var active: Bool { isActive }

    /// 开始保活（下载开始时调用；重复调用无副作用）
    func start(reason: String) {
        guard !isActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // .mixWithOthers：不打断用户正在听的音乐；.playback 才能拿到后台运行权
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let player = try AVAudioPlayer(data: Self.silentWavData())
            player.numberOfLoops = -1      // 无限循环
            player.volume = 0              // 静音（数据本身就是全 0）
            player.prepareToPlay()
            player.play()
            self.player = player
            isActive = true
            diag("KeepAlive: 静音音频保活已开启 (\(reason))")
        } catch {
            debugLog("[KeepAlive] 开启失败: \(error)")
            diag("KeepAlive: 开启失败 \(error)")
        }

        // 监控：队列空闲或策略被切走时自动停止，避免一直占着音频会话
        monitor?.cancel()
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                let strategy = AppSettings.shared.backgroundKeepAliveStrategy
                if strategy != 1 && strategy != 2 {
                    self.stop(reason: "策略已切换")
                    return
                }
                let tasks = await DownloadManager.shared.getAllTasks()
                let busy = tasks.contains {
                    $0.state == DownloadManager.stateDownload || $0.state == DownloadManager.stateWait
                }
                if !busy {
                    self.stop(reason: "队列空闲")
                    return
                }
            }
        }
    }

    /// 停止保活（下载结束 / 用户关闭该策略 / 切换策略时调用）
    func stop(reason: String) {
        monitor?.cancel()
        monitor = nil
        guard isActive else { return }
        player?.stop()
        player = nil
        isActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            debugLog("[KeepAlive] 关闭 audio session 失败: \(error)")
        }
        diag("KeepAlive: 静音音频保活已停止 (\(reason))")
    }

    /// 生成一段 1 秒的静音 WAV（44.1kHz / 16bit / 单声道 / PCM）
    private static func silentWavData() -> Data {
        let sampleRate = 44_100
        let seconds = 1
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = sampleRate * seconds * blockAlign

        var data = Data()
        func put(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func put32(_ v: UInt32) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        }
        func put16(_ v: UInt16) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        }

        put("RIFF")
        put32(UInt32(36 + dataSize))
        put("WAVE")
        put("fmt ")
        put32(16)                          // PCM fmt chunk 大小
        put16(1)                           // PCM
        put16(UInt16(channels))
        put32(UInt32(sampleRate))
        put32(UInt32(byteRate))
        put16(UInt16(blockAlign))
        put16(UInt16(bitsPerSample))
        put("data")
        put32(UInt32(dataSize))
        data.append(Data(count: dataSize)) // 全 0 = 静音
        return data
    }
}
#endif
