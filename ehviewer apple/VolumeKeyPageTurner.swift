//
//  VolumeKeyPageTurner.swift
//  ehviewer apple
//
//  音量键 / 外置翻页器翻页 — 对齐 Android GalleryActivity 的 `volume_page` 设置
//
//  背景 (issue #4「无法使用外置翻页器翻页」):
//  蓝牙翻页器有两类工作模式 —
//    1. 键盘模式: 发送 ←/→ ↑/↓ PageUp/PageDown Space/Enter → 由 ImageReaderView 的
//       `.onKeyPress` 处理 (需要视图处于 focus 状态, 见 ImageReaderView.focusable)
//    2. 媒体模式: 发送音量加/减 → 由本文件处理
//
//  实现方式: KVO 监听 AVAudioSession.outputVolume, 触发翻页后立刻把系统音量复位到基准值,
//  这样用户可以连续按。视图层内嵌一个离屏 MPVolumeView, 同时用于复位音量和抑制系统音量 HUD。
//
//  1.4.0 重写要点 (修复「按键迟钝 / 丢按」):
//    旧实现用一个 `isResetting` 标志 + `asyncAfter(0.25s)` 复位, 这构成 250ms「聋窗」——
//    窗口内所有音量事件被直接吞掉, 快速连按必然丢按。
//    新实现改用「按值过滤回声」: 只忽略「值等于我们自己刚写入的复位值」的那一次回调,
//    用户在任何时刻的按键 (值必然偏离基准) 都会被立即受理, 不再有任何时间盲区。
//    同时复位改为「按键后立即同步复位」, 音量永远不会累积漂移到 0/1 端点, 保证按住连翻不卡死。
//

#if os(iOS)

import AVFoundation
import MediaPlayer
import QuartzCore
import UIKit
import EhSettings

@MainActor
final class VolumeKeyPageTurner {

    /// 复位基准音量 — 保持在中间位置，上下都有余量
    private static let baseVolume: Float = 0.5
    /// 与基准的差异小于该幅度 → 视为环境噪声 / 非用户操作，忽略。
    /// iOS 音量步长为 1/16 = 0.0625，此阈值与步长之间有 ~10 倍安全边际。
    private static let noiseThreshold: Float = 0.006
    /// 判定「这是我们自己写入的复位回声」的值容差
    private static let echoTolerance: Float = 0.006
    /// 同一次物理按键偶尔产生两个事件时的合并窗口
    private static let coalesceWindow: TimeInterval = 0.04

    private var observation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    /// 我们自己刚写入系统的音量值 —— 用于把复位回声和用户按键区分开
    private var expectedEcho: Float?
    private var lastAcceptedAt: TimeInterval = 0
    /// 进入时的真实音量，退出时还原给用户
    private var userVolume: Float = 0.5
    private var onNext: () -> Void = {}
    private var onPrevious: () -> Void = {}

    var isRunning: Bool { observation != nil }

    // MARK: - 生命周期

    /// 开始监听
    /// - Parameters:
    ///   - onNext: 下一页回调
    ///   - onPrevious: 上一页回调
    func start(onNext: @escaping () -> Void, onPrevious: @escaping () -> Void) {
        guard observation == nil else { return }
        self.onNext = onNext
        self.onPrevious = onPrevious

        let session = AVAudioSession.sharedInstance()
        // .ambient + .mixWithOthers: 不打断用户正在播放的音乐/播客
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)

        // 记住用户进入阅读器前的真实音量，退出时还原（旧实现会停在 50%）
        userVolume = session.outputVolume

        attachVolumeView()
        // 先复位到基准，上下都留出余量。这次写入的回声由 expectedEcho 标记并忽略。
        writeSystemVolume(Self.baseVolume)

        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let newValue = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.handleVolumeChange(newValue)
            }
        }
    }

    /// 停止监听并还原
    func stop() {
        observation?.invalidate()
        observation = nil
        expectedEcho = nil
        // ★ 还原用户进入前的真实音量
        writeSystemVolume(userVolume)
        expectedEcho = nil
        volumeView?.removeFromSuperview()
        volumeView = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    deinit {
        observation?.invalidate()
    }

    // MARK: - 内部实现

    private func handleVolumeChange(_ newVolume: Float) {
        // ① 复位回声：值等于我们自己刚写入的复位值 → 忽略（替代旧实现的 250ms 聋窗）
        if let expected = expectedEcho, abs(newVolume - expected) <= Self.echoTolerance {
            expectedEcho = nil
            return
        }
        expectedEcho = nil

        let delta = newVolume - Self.baseVolume
        // ② 非用户操作（外部 App / 环境噪声导致的微小变化）→ 忽略
        guard abs(delta) > Self.noiseThreshold else { return }

        // ③ 单次物理按键偶发两个事件 → 40ms 内合并，避免翻两页
        let now = CACurrentMediaTime()
        guard now - lastAcceptedAt >= Self.coalesceWindow else { return }
        lastAcceptedAt = now

        // ④ 方向 → 立即翻页
        //    默认: 音量+ = 上一页, 音量- = 下一页 (对齐 Android VOLUME_PAGE 默认方向)
        let reverse = AppSettings.shared.reverseVolumePage
        let goForward = reverse ? (delta > 0) : (delta < 0)
        if goForward { onNext() } else { onPrevious() }

        // ⑤ 立即同步复位：保证下一次按键上下都有余量，按多久都不会漂到端点
        writeSystemVolume(Self.baseVolume)
    }

    /// 程序化写系统音量，并登记「这次写入的回声值」以便忽略随之而来的 KVO 回调
    private func writeSystemVolume(_ value: Float) {
        guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        expectedEcho = value
        slider.setValue(value, animated: false)
        slider.sendActions(for: .valueChanged)
    }

    /// 把离屏 MPVolumeView 挂到当前窗口上
    /// (MPVolumeView 必须在视图层级里 slider 才存在；同时它会抑制系统音量 HUD)
    private func attachVolumeView() {
        guard volumeView == nil else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        guard let window else { return }

        let view = MPVolumeView(frame: CGRect(x: -4000, y: -4000, width: 1, height: 1))
        view.alpha = 0.0001
        view.isUserInteractionEnabled = false
        view.showsRouteButton = false
        window.addSubview(view)
        volumeView = view
    }
}

#endif