//
//  MangaTranslationSettingsView.swift
//  ehviewer apple
//
//  漫画翻译设置界面
//

import SwiftUI

struct MangaTranslationSettingsView: View {
    @State private var enabled = MangaTranslationSettings.shared.enabled
    @State private var provider = MangaTranslationSettings.shared.provider
    @State private var source = MangaTranslationSettings.shared.sourceLanguage
    @State private var target = MangaTranslationSettings.shared.targetLanguage
    @State private var sampledBackground = MangaTranslationSettings.shared.useSampledBackground
    @State private var showOriginalText = MangaTranslationSettings.shared.showOriginalText
    @State private var fontScale = MangaTranslationSettings.shared.fontScale
    @State private var baseURL = MangaTranslationSettings.shared.deepSeekBaseURL
    @State private var model = MangaTranslationSettings.shared.deepSeekModel
    @State private var apiKey = MangaTranslationSettings.shared.deepSeekAPIKey
    @State private var lineDropFallback = MangaTranslationSettings.shared.usesLineDropFallback
    @State private var cacheBytes: Int64 = 0

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var body: some View {
        Form {
            Section {
                Toggle("在阅读器中启用翻译", isOn: Binding(
                    get: { enabled },
                    set: { enabled = $0; MangaTranslationSettings.shared.enabled = $0 }
                ))
            } footer: {
                Text("开启后，阅读漫画时可在顶部工具栏点「翻译本页」，直接把当前页的日文/外文替换成译文。")
            }

            Section("翻译后端") {
                Picker("后端", selection: Binding(
                    get: { provider },
                    set: { provider = $0; MangaTranslationSettings.shared.provider = $0 }
                )) {
                    ForEach(MangaTranslationProvider.allCases, id: \.rawValue) { p in
                        Text(p.label).tag(p)
                    }
                }
                .pickerStyle(.inline)
            }

            Section("语言") {
                Picker("源语言", selection: Binding(
                    get: { source },
                    set: { source = $0; MangaTranslationSettings.shared.sourceLanguage = $0 }
                )) {
                    ForEach(MangaTranslationSource.allCases, id: \.rawValue) { s in
                        Text(s.label).tag(s)
                    }
                }
                Picker("目标语言", selection: Binding(
                    get: { target },
                    set: { target = $0; MangaTranslationSettings.shared.targetLanguage = $0 }
                )) {
                    ForEach(MangaTranslationTarget.allCases, id: \.rawValue) { t in
                        Text(t.label).tag(t)
                    }
                }
            }

            Section {
                Toggle("漏行兜底（iOS 27 兼容）", isOn: Binding(
                    get: { lineDropFallback },
                    set: { lineDropFallback = $0; MangaTranslationSettings.shared.usesLineDropFallback = $0 }
                ))
            } header: {
                Text("识别")
            } footer: {
                Text("识别始终按「原图直接识别」进行，不做放大/分块。iOS 27 的 Vision 存在已知的整页漏行回归，开启此项后，当直接识别命中过少时会用横向压扁重试并合并结果（只会增加识别内容）。")
            }

            if provider == .deepSeek {
                Section {
                    TextField("Base URL", text: Binding(
                        get: { baseURL },
                        set: { baseURL = $0; MangaTranslationSettings.shared.deepSeekBaseURL = $0 }
                    ))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif
                    TextField("模型", text: Binding(
                        get: { model },
                        set: { model = $0; MangaTranslationSettings.shared.deepSeekModel = $0 }
                    ))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    SecureField("API Key", text: Binding(
                        get: { apiKey },
                        set: { apiKey = $0; MangaTranslationSettings.shared.deepSeekAPIKey = $0 }
                    ))
                } header: {
                    Text("DeepSeek（OpenAI 兼容）")
                } footer: {
                    Text("API Key 存于 Keychain（失败时回退到本机存储）。也可把 Base URL 指向任意 OpenAI 兼容服务。")
                }
            } else {
                Section {
                    Text("端上翻译由系统「翻译」框架完成，首次使用某语言对时可能需要联网下载语言包。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("排版") {
                Toggle("底色取样（关闭则用纯白）", isOn: Binding(
                    get: { sampledBackground },
                    set: { sampledBackground = $0; MangaTranslationSettings.shared.useSampledBackground = $0 }
                ))
                Toggle("额外标注原文", isOn: Binding(
                    get: { showOriginalText },
                    set: { showOriginalText = $0; MangaTranslationSettings.shared.showOriginalText = $0 }
                ))
                HStack {
                    Text("字号缩放")
                    Slider(value: Binding(
                        get: { fontScale },
                        set: { fontScale = $0; MangaTranslationSettings.shared.fontScale = $0 }
                    ), in: 0.6...1.4)
                    Text(String(format: "%.2f", fontScale))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Section {
                HStack {
                    Text("占用空间")
                    Spacer()
                    Text(cacheBytes > 0 ? Self.byteFormatter.string(fromByteCount: cacheBytes) : "无")
                        .foregroundStyle(.secondary)
                }
                Button("清除译文缓存", role: .destructive) {
                    MangaTranslationCache.shared.clearAll()
                    cacheBytes = 0
                }
            } header: {
                Text("译文缓存")
            } footer: {
                Text("翻译结果会**持久化保存在本机**：切到「显示原文」再切回来、退出阅读器重新进入、甚至重启 App 都直接复用，不会重复翻译。下载页长按「一键翻译」翻出的结果与阅读器共用同一份缓存。字号等排版设置的变化只重新排版，不重新翻译。")
            }
        }
        .navigationTitle("漫画翻译")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            cacheBytes = MangaTranslationCache.shared.totalBytes
        }
    }
}
