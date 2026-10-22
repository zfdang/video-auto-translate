import SwiftUI
import AppKit
import AVFoundation
import VideoAutoTranslateCore

public struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var modelStorageManager: ModelStorageManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab = .tts
    @State private var isTestingASR: Bool = false
    @State private var asrTestFeedback: (isSuccess: Bool, message: String)? = nil
    @State private var isProbingOllama: Bool = false
    @State private var ollamaProbeFeedback: (isSuccess: Bool, message: String)? = nil
    @State private var selectedLanguageOption: String = "简体中文 (Simplified Chinese)"
    @State private var onlineURLDraft = ""
    private let customLanguageTag: String = "__custom__"

    // 语音合成 (TTS) 试听与环境状态
    @State private var previewText: String = "你好，这是微软 Edge 语音合成的测试效果，发音自然生动。"
    @State private var isSynthesizingPreview: Bool = false
    @State private var isPlayingPreview: Bool = false
    @State private var previewPlayer: AVPlayer? = nil
    @State private var ttsFeedbackMessage: String? = nil
    @State private var edgeTTSStatus: (installed: Bool, version: String, pythonPath: String) = (false, "检测中...", "")
    @State private var isInstallingEdgeTTS: Bool = false
    @State private var edgeTTSInstallMessage: String? = nil

    public init(appState: AppState) {
        self.appState = appState
        self.modelStorageManager = appState.modelStorageManager
    }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case asrModels = "ASR 模型"
        case asrService = "ASR 服务"
        case translation = "大语言模型 (LLM)"
        case tts = "语音合成 (TTS)"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .asrModels: return "waveform.circle"
            case .asrService: return "server.rack"
            case .translation: return "brain"
            case .tts: return "speaker.wave.3"
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶栏与标签切换
            HStack {
                Text("偏好设置")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Picker("", selection: $selectedTab) {
                    ForEach(SettingsTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 480)

                Spacer()

                Button("完成") {
                    if !onlineURLDraft.isEmpty { appState.useOnlineEndpoint(onlineURLDraft) }
                    appState.applyStorageSettings()
                    appState.flushPreferences()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            // 主内容区
            Group {
                switch selectedTab {
                case .asrModels:
                    modelStorageSettingsView
                case .asrService:
                    asrServiceSettingsView
                case .translation:
                    translationSettingsView
                case .tts:
                    ttsSettingsView
                }
            }
            .padding()
        }
        .frame(width: 680, height: 560)
        .onAppear {
            onlineURLDraft = appState.project.llmConfig.onlineBaseURL
            appState.modelStorageManager.config = appState.project.modelStorageConfig
            appState.modelStorageManager.refreshAll()
            if let canonical = TargetLanguagePreset.defaultPresets.first(where: { $0.name == appState.project.llmConfig.targetLanguage || $0.name.hasPrefix(appState.project.llmConfig.targetLanguage + " (") }) {
                appState.project.llmConfig.targetLanguage = canonical.name
            }
            if TargetLanguagePreset.defaultPresets.contains(where: { $0.name == appState.project.llmConfig.targetLanguage }) {
                selectedLanguageOption = appState.project.llmConfig.targetLanguage
            } else {
                selectedLanguageOption = customLanguageTag
            }
            checkEdgeTTS()
        }
        .onDisappear {
            previewPlayer?.pause()
            previewPlayer = nil
            isPlayingPreview = false
        }
    }

    // MARK: - 模型存储与下载管理 Tab

    private var modelStorageSettingsView: some View {
        Form {
            Section(header: Text("模型存放位置").font(.headline)) {
                Picker("存储方式", selection: $appState.project.modelStorageConfig.locationType) {
                    ForEach(ModelStorageLocationType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .onChange(of: appState.project.modelStorageConfig.locationType) {
                    let newType = appState.project.modelStorageConfig.locationType
                    appState.modelStorageManager.config.locationType = newType
                    appState.modelStorageManager.refreshAll()
                    Task {
                        await appState.syncModelStorageToServer()
                    }
                }

                if appState.project.modelStorageConfig.locationType == .custom {
                    HStack {
                        TextField("自定义保存路径（回车应用）", text: $appState.project.modelStorageConfig.customDirectoryPath)
                            .onSubmit { appState.applyStorageSettings() }
                        Button("浏览选择...") {
                            appState.chooseCustomModelDirectory()
                        }
                    }
                }

                HStack {
                    Image(systemName: "folder")
                        .foregroundColor(.secondary)
                    Text("当前路径: \(appState.modelStorageManager.resolvedStorageDirectory().path)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("可用空间: \(appState.modelStorageManager.availableDiskSpaceString)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("在访达中显示") {
                        appState.revealCurrentModelDirectoryInFinder()
                    }
                    .font(.caption)
                }
            }

            Section(header: Text("模型下载镜像源").font(.headline)) {
                Picker("下载镜像源", selection: $appState.project.modelStorageConfig.selectedMirror) {
                    ForEach(ModelDownloadMirror.allCases.filter { $0 != .modelScope }) { mirror in
                        Text(mirror.displayName).tag(mirror)
                    }
                }
                .onChange(of: appState.project.modelStorageConfig.selectedMirror) {
                    let newMirror = appState.project.modelStorageConfig.selectedMirror
                    appState.modelStorageManager.config.selectedMirror = newMirror
                }
            }

            Section(header: Text("ASR 语音识别模型库").font(.headline)) {
                ForEach(ASRModelPreset.allPresets) { preset in
                    ASRModelPresetRowView(
                        modelStorageManager: modelStorageManager,
                        preset: preset,
                        onDownload: {
                            appState.downloadModel(preset: preset)
                        },
                        onCancel: {
                            appState.cancelDownload(preset: preset)
                        }
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - ASR 服务 Tab

    private var asrServiceSettingsView: some View {
        Form {
            Section("Python 运行环境与诊断") {
                if appState.sidecarManager.isUsingEmbeddedRuntime {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("已启用 App 内置独立 Portable Python 运行环境")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("完全隔离自包含，ASR 转录与 Edge TTS 配音均由内置环境统一提供支持，免去系统环境配置。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text("当前使用外部环境：\(appState.sidecarManager.runtimeDescription)")
                        .font(.caption)
                    Text(appState.sidecarManager.runtimeMessage).font(.caption).textSelection(.enabled)
                }

                HStack {
                    if !appState.sidecarManager.isUsingEmbeddedRuntime {
                        if appState.sidecarManager.isPreparingRuntime {
                            ProgressView().controlSize(.small)
                            Button("取消准备") { appState.sidecarManager.cancelRuntimePreparation() }
                        } else {
                            Button("准备识别环境（需联网）") { Task { await appState.sidecarManager.prepareManagedRuntime() } }
                            Button("选择 Python…") {
                                let panel = NSOpenPanel()
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK { appState.sidecarManager.bootstrapPythonPath = panel.url?.path }
                            }
                        }
                    }
                    Button("查看准备日志") { NSWorkspace.shared.open(appState.sidecarManager.runtimeLogURL) }
                    Button("查看引擎日志") { NSWorkspace.shared.open(appState.sidecarManager.diagnosticLogURL) }
                }
            }
            Section(header: Text("本地 ASR 语音识别引擎托管").font(.headline)) {
                HStack {
                    Circle()
                        .fill(appState.sidecarManager.status.isRunning ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(appState.sidecarManager.status.displayString)
                        .font(.subheadline)
                    Spacer()
                    if !appState.sidecarManager.status.isRunning {
                        Button("预先唤醒引擎") {
                            Task {
                                await appState.sidecarManager.ensureRunning()
                                await appState.probeLocalASR()
                            }
                        }
                        .font(.caption)
                    } else {
                        Button("重启引擎") {
                            Task {
                                appState.sidecarManager.stop()
                                await appState.sidecarManager.ensureRunning()
                                await appState.probeLocalASR()
                            }
                        }
                        .font(.caption)
                    }
                }
                .padding(.vertical, 4)

                Text("运行机制：本应用采用按需延迟静默托管模式。启动 App 时不预先占用显存；当您开始首个转录任务时，应用会自动唤醒推理引擎并保持热驻留，后续任务秒级响应，并在完全退出应用时自动释放销毁。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("ASR 接口 URL", text: $appState.project.asrConfig.serviceURL)
                        Button(action: {
                            Task {
                                isTestingASR = true
                                asrTestFeedback = nil
                                let res = await appState.testASRConnection()
                                await MainActor.run {
                                    self.isTestingASR = false
                                    self.asrTestFeedback = (res.success, res.message)
                                    self.appState.isASRServerOnline = res.success
                                }
                            }
                        }) {
                            HStack(spacing: 4) {
                                if isTestingASR {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text("测试连通")
                            }
                        }
                        .disabled(isTestingASR)
                    }

                    if let feedback = asrTestFeedback {
                        HStack(spacing: 6) {
                            Image(systemName: feedback.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(feedback.isSuccess ? .green : .red)
                            Text(feedback.message)
                                .font(.caption)
                                .foregroundColor(feedback.isSuccess ? .green : .red)
                        }
                        .padding(.top, 2)
                    }
                }
                TextField("服务模型标识", text: $appState.project.asrConfig.model).disabled(appState.usesManagedASR)
                if appState.usesManagedASR { Text("内置引擎使用 Qwen3-ASR 1.7B；自定义服务可指定其支持的模型标识。").font(.caption) }

                Picker("默认原语言策略", selection: $appState.project.asrConfig.language) {
                    ForEach(ASRLanguagePreset.presets) { preset in
                        Text(preset.displayName).tag(preset.code)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 大语言模型 (LLM) Tab

    private var translationSettingsView: some View {
        Form {
            Section(header: Text("大语言模型 (LLM) 底层支持").font(.headline)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("用途说明：大语言模型（LLM）不仅用于第 3 步「字幕翻译」，同时在第 2 步语音转录完成后负责「智能语义断句规整」，将零散的音频时间戳智能重组为断句通顺、长短适中的自然字幕。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)

                Picker("服务模式", selection: $appState.project.llmConfig.providerType) {
                    ForEach(LLMProviderType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 4)

                if appState.project.llmConfig.providerType == .localOllama {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("Ollama 服务地址", text: $appState.project.llmConfig.ollamaBaseURL)
                                Button(action: {
                                    Task {
                                        isProbingOllama = true
                                        ollamaProbeFeedback = nil
                                        let res = await appState.probeLocalOllamaDetailed()
                                        await MainActor.run {
                                            self.isProbingOllama = false
                                            self.ollamaProbeFeedback = (res.success, res.message)
                                        }
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        if isProbingOllama {
                                            ProgressView()
                                                .controlSize(.small)
                                        }
                                        Text("刷新探测")
                                    }
                                }
                                .disabled(isProbingOllama)
                            }

                            if let feedback = ollamaProbeFeedback {
                                HStack(spacing: 6) {
                                    Image(systemName: feedback.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(feedback.isSuccess ? .green : .red)
                                    Text(feedback.message)
                                        .font(.caption)
                                        .foregroundColor(feedback.isSuccess ? .green : .red)
                                }
                                .padding(.top, 2)
                            }
                        }

                        if !appState.availableOllamaModels.isEmpty {
                            Picker("当前模型", selection: $appState.project.llmConfig.ollamaModel) {
                                ForEach(appState.availableOllamaModels, id: \.self) { Text($0).tag($0) }
                            }
                        } else {
                            Text(ollamaProbeFeedback?.isSuccess == true ? "服务在线，尚未安装模型；可在下方下载。" : "请先安装并打开 Ollama，再测试连接。推荐模型始终显示在下方。")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("推荐模型").font(.headline)
                            ForEach(OllamaModelPreset.recommended) { preset in ollamaPresetRow(preset) }
                        }

                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("API Base URL（回车应用地址）", text: $onlineURLDraft)
                            .onSubmit { appState.useOnlineEndpoint(onlineURLDraft) }
                        SecureField("API Key", text: $appState.project.llmConfig.onlineAPIKey)
                            .disabled(onlineURLDraft != appState.project.llmConfig.onlineBaseURL)
                        if onlineURLDraft != appState.project.llmConfig.onlineBaseURL {
                            Text("请先按回车应用新地址，再输入该服务的密钥。").font(.caption)
                        }
                        Button("忘记该服务的密钥") {
                            ServiceCredentials.remove(account: appState.project.llmConfig.onlineBaseURL)
                            appState.project.llmConfig.onlineAPIKey = ""
                        }.font(.caption)
                        TextField("模型 ID (如 deepseek-chat)", text: $appState.project.llmConfig.onlineModel)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section(header: Text("字幕翻译目标语言与推理参数").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("目标语言", selection: $selectedLanguageOption) {
                        ForEach(TargetLanguagePreset.defaultPresets) { preset in
                            Text(preset.name).tag(preset.name)
                        }
                        Divider()
                        Text("自定义语言...").tag(customLanguageTag)
                    }
                    .onChange(of: selectedLanguageOption) {
                        if selectedLanguageOption != customLanguageTag {
                            appState.project.llmConfig.targetLanguage = selectedLanguageOption
                        }
                    }

                    if selectedLanguageOption == customLanguageTag {
                        HStack {
                            Image(systemName: "pencil")
                                .foregroundColor(.secondary)
                            TextField("输入自定义目标语言 (如: 广东话/粤语、文言文等)", text: $appState.project.llmConfig.targetLanguage)
                        }
                        .padding(.top, 2)
                    }
                }

                Text("按批翻译，每批最多 10 句；修改设置对后续任务生效。凭据保存到本机钥匙串，不写入工程。")
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    Text("采样温度: \(String(format: "%.1f", appState.project.llmConfig.temperature))")
                    Slider(value: $appState.project.llmConfig.temperature, in: 0.0...1.0, step: 0.1)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func ollamaPresetRow(_ preset: OllamaModelPreset) -> some View {
        let isInstalled = appState.availableOllamaModels.contains(where: {
            $0 == preset.name
        })
        let isCurrent = appState.project.llmConfig.ollamaModel == preset.name
        let pullState = appState.ollamaPullStates[preset.name]

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(preset.displayName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(preset.sizeDescription)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(4)
                    }
                    Text(preset.note)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let pullState = pullState, case .downloading(let progress, let speed) = pullState {
                    VStack(alignment: .trailing, spacing: 2) {
                        ProgressView(value: progress)
                            .frame(width: 90)
                        Text("\(Int(progress * 100))% · \(speed)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else if isInstalled {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("已就绪")
                            .font(.caption)
                            .foregroundColor(.green)

                        if isCurrent {
                            Text("（当前生效）")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Button("设为当前") {
                                appState.project.llmConfig.ollamaModel = preset.name
                            }
                            .font(.caption)
                        }
                    }
                } else {
                    Button("一键下载到 Ollama") {
                        appState.pullOllamaModel(name: preset.name)
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 语音合成 (TTS) Tab

    private var ttsSettingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 1. 引擎选择卡片
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "cpu")
                            .foregroundColor(.accentColor)
                        Text("语音合成 (TTS) 引擎")
                            .font(.headline)
                    }

                    Picker("合成引擎", selection: $appState.project.ttsConfig.engineType) {
                        ForEach(TTSEngineType.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: appState.project.ttsConfig.engineType) {
                        appState.flushPreferences()
                    }

                    if appState.project.ttsConfig.engineType == .edgeTTS {
                        Text("采用微软 Azure 神经网络拟真模型，语调抑扬顿挫极其自然生动，影视解说与视频配音行业首选标准（免 API Key 免费调用）。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("基于 macOS 内置系统原生引擎，完全离线运行。但机械感稍强，推荐优先选用 Edge 拟真引擎。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // 环境依赖状态指示条
                    HStack(spacing: 8) {
                        Circle()
                            .fill(edgeTTSStatus.installed ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)

                        if edgeTTSStatus.installed {
                            let source = appState.sidecarManager.isUsingEmbeddedRuntime ? "内置独立环境" : "外部环境"
                            Text("Edge TTS 依赖已就绪 (\(source) · \(edgeTTSStatus.version))")
                                .font(.caption)
                                .foregroundColor(.primary)
                        } else {
                            Text("未检测到 edge-tts 依赖（当前环境: \(edgeTTSStatus.pythonPath)）")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }

                        Spacer()

                        if !edgeTTSStatus.installed {
                            Button(action: installEdgeTTSAction) {
                                HStack(spacing: 4) {
                                    if isInstallingEdgeTTS {
                                        ProgressView().controlSize(.small)
                                        Text("正在安装...")
                                    } else {
                                        Image(systemName: "arrow.down.circle")
                                        Text("一键安装 edge-tts")
                                    }
                                }
                            }
                            .font(.caption)
                            .buttonStyle(.borderedProminent)
                            .disabled(isInstallingEdgeTTS)
                        } else {
                            Button("重新检测") {
                                checkEdgeTTS()
                            }
                            .font(.caption)
                        }
                    }

                    if let msg = edgeTTSInstallMessage {
                        Text(msg)
                            .font(.caption2)
                            .foregroundColor(msg.contains("成功") ? .green : .red)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                // 2. 音色选择卡片
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "person.wave.2")
                            .foregroundColor(.accentColor)
                        Text("配音音色")
                            .font(.headline)
                    }

                    let availableVoices = TTSVoiceOption.voices(
                        for: appState.project.llmConfig.targetLanguage,
                        engine: appState.project.ttsConfig.engineType
                    )

                    Picker("当前音色", selection: $appState.project.ttsConfig.selectedVoice) {
                        ForEach(availableVoices) { voice in
                            HStack {
                                Text(voice.name)
                                if voice.isRecommended {
                                    Text("推荐")
                                        .font(.caption2)
                                        .foregroundColor(.green)
                                }
                            }
                            .tag(voice.id)
                        }
                    }
                    .onChange(of: appState.project.ttsConfig.selectedVoice) {
                        appState.flushPreferences()
                    }

                    HStack(spacing: 8) {
                        Text("目标语言关联:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(appState.project.llmConfig.targetLanguage)
                            .font(.caption)
                            .fontWeight(.medium)
                        Spacer()
                        Text("生效音色代码: \(appState.project.effectiveVoiceCode)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                // 3. 音色试听卡片
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "headphones")
                            .foregroundColor(.accentColor)
                        Text("音色效果试听")
                            .font(.headline)
                    }

                    TextField("试听文本", text: $previewText)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 12) {
                        Button(action: togglePreviewSpeech) {
                            HStack(spacing: 6) {
                                if isSynthesizingPreview {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("正在生成语音...")
                                } else if isPlayingPreview {
                                    Image(systemName: "stop.fill")
                                    Text("停止播放")
                                } else {
                                    Image(systemName: "play.fill")
                                    Text("试听声音")
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSynthesizingPreview || previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if let feedback = ttsFeedbackMessage {
                            Text(feedback)
                                .font(.caption)
                                .foregroundColor(feedback.contains("失败") ? .red : .secondary)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                Spacer()
            }
            .padding()
        }
    }

    private func togglePreviewSpeech() {
        if isPlayingPreview {
            previewPlayer?.pause()
            previewPlayer = nil
            isPlayingPreview = false
            return
        }

        let text = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isSynthesizingPreview = true
        ttsFeedbackMessage = nil

        let voice = appState.project.effectiveVoiceCode
        let service = appState.ttsService
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("tts_preview_\(UUID().uuidString).wav")

        Task {
            do {
                _ = try await service.synthesize(text: text, voice: voice, outputURL: tempURL)
                await MainActor.run {
                    isSynthesizingPreview = false
                    isPlayingPreview = true
                    ttsFeedbackMessage = "播放中 (音色: \(voice))"

                    let item = AVPlayerItem(url: tempURL)
                    let p = AVPlayer(playerItem: item)
                    previewPlayer = p
                    p.play()

                    NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemDidPlayToEndTime,
                        object: item,
                        queue: .main
                    ) { _ in
                        isPlayingPreview = false
                        ttsFeedbackMessage = "试听完成"
                    }
                }
            } catch {
                await MainActor.run {
                    isSynthesizingPreview = false
                    isPlayingPreview = false
                    ttsFeedbackMessage = "试听合成失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func checkEdgeTTS() {
        DispatchQueue.global(qos: .userInitiated).async {
            let res = EdgeTTSService.probeEdgeTTS()
            DispatchQueue.main.async {
                self.edgeTTSStatus = res
            }
        }
    }

    private func installEdgeTTSAction() {
        isInstallingEdgeTTS = true
        edgeTTSInstallMessage = "正在连接 PyPI 自动安装 edge-tts..."
        Task.detached {
            do {
                try await EdgeTTSService.installEdgeTTS()
                await MainActor.run {
                    self.isInstallingEdgeTTS = false
                    self.edgeTTSInstallMessage = "安装成功！已可直接使用微软 Edge 拟真配音。"
                    self.checkEdgeTTS()
                }
            } catch {
                await MainActor.run {
                    self.isInstallingEdgeTTS = false
                    self.edgeTTSInstallMessage = "安装失败: \(error.localizedDescription)。您也可以在终端执行: pip install edge-tts"
                }
            }
        }
    }
}

/// 单个 ASR 模型预设行视图，独立以 @ObservedObject 订阅 ModelStorageManager
/// 保证点击“立即下载”瞬间在第 0 毫秒由 SwiftUI 立即重绘，切换为“取消”和 0% 进度条
struct ASRModelPresetRowView: View {
    @ObservedObject var modelStorageManager: ModelStorageManager
    let preset: ASRModelPreset
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let state = modelStorageManager.modelStates[preset.id] ?? .notDownloaded

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(preset.displayName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(preset.sizeDescription)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(4)
                    }
                    Text(preset.note)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                switch state {
                case .ready(let path, _):
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("已就绪")
                                .font(.caption)
                                .foregroundColor(.green)
                        }

                        Button("在访达定位") {
                            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
                        }
                        .font(.caption)
                    }

                case .downloading(let progress, let speed):
                    HStack(spacing: 8) {
                        VStack(alignment: .trailing, spacing: 2) {
                            ProgressView(value: progress)
                                .frame(width: 100)
                            Text("\(Int(progress * 100))% · \(speed)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Button("取消") {
                            onCancel()
                        }
                        .font(.caption)
                    }

                case .failed(let err):
                    HStack(spacing: 8) {
                        Text("失败: \(err)")
                            .font(.caption2)
                            .foregroundColor(.red)
                            .lineLimit(1)
                        Button("重试") {
                            onDownload()
                        }
                        .font(.caption)
                    }

                case .notDownloaded:
                    Button("立即下载") {
                        onDownload()
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
