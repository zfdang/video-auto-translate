import SwiftUI
import AppKit
import VideoAutoTranslateCore

public struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var modelStorageManager: ModelStorageManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab = .asrModels
    @State private var isTestingASR: Bool = false
    @State private var asrTestFeedback: (isSuccess: Bool, message: String)? = nil
    @State private var selectedLanguageOption: String = "简体中文 (Simplified Chinese)"
    private let customLanguageTag: String = "__custom__"

    public init(appState: AppState) {
        self.appState = appState
        self.modelStorageManager = appState.modelStorageManager
    }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case asrModels = "ASR 模型"
        case asrService = "ASR 服务"
        case translation = "大语言模型 (LLM)"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .asrModels: return "waveform.circle"
            case .asrService: return "server.rack"
            case .translation: return "brain"
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
                .frame(width: 380)

                Spacer()

                Button("完成") {
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
                }
            }
            .padding()
        }
        .frame(width: 680, height: 560)
        .onAppear {
            appState.modelStorageManager.config = appState.project.modelStorageConfig
            appState.modelStorageManager.refreshAll()
            if TargetLanguagePreset.defaultPresets.contains(where: { $0.name == appState.project.llmConfig.targetLanguage }) {
                selectedLanguageOption = appState.project.llmConfig.targetLanguage
            } else {
                selectedLanguageOption = customLanguageTag
            }
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
                        TextField("自定义保存路径", text: $appState.project.modelStorageConfig.customDirectoryPath)
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
                    ForEach(ModelDownloadMirror.allCases) { mirror in
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
                TextField("默认 ASR 模型标识", text: $appState.project.asrConfig.model)

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
                        HStack {
                            TextField("Ollama 服务地址", text: $appState.project.llmConfig.ollamaBaseURL)
                            Button("刷新探测") {
                                Task {
                                    await appState.probeLocalOllama()
                                }
                            }
                        }

                        if !appState.availableOllamaModels.isEmpty {
                            Picker("当前生效模型", selection: $appState.project.llmConfig.ollamaModel) {
                                ForEach(appState.availableOllamaModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 8) {
                                Text("推荐模型与一键安装")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                ForEach(OllamaModelPreset.recommended) { preset in
                                    ollamaPresetRow(preset)
                                }

                                Text("💡 提示：您也可以在 macOS 终端随时执行 `ollama run qwen2.5:latest` 命令行拉取模型。")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 4)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text("未检测到运行中的 Ollama 服务 (http://localhost:11434)")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                }

                                Text("Ollama 是本地开源大模型运行时。如需完全离线运行：\n1. 访问 ollama.com 下载安装 Ollama 应用\n2. 打开终端执行 `ollama serve` 启动服务\n3. 执行 `ollama run qwen2.5:latest` 安装推荐模型\n4. 返回此处点击「刷新探测」即可自动绑定\n\n您也可以直接切换为上方「在线 API (兼容 OpenAI)」模式，免去本地显存负担。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineSpacing(3)
                            }
                            .padding(8)
                            .background(Color.orange.opacity(0.08))
                            .cornerRadius(6)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("API Base URL (如 https://api.deepseek.com/v1)", text: $appState.project.llmConfig.onlineBaseURL)
                        SecureField("API Key", text: $appState.project.llmConfig.onlineAPIKey)
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

                Stepper("最大并发请求数: \(appState.project.llmConfig.maxConcurrency)", value: $appState.project.llmConfig.maxConcurrency, in: 1...8)
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
            $0 == preset.name || $0.hasPrefix(preset.name.split(separator: ":").first.map(String.init) ?? preset.name)
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
