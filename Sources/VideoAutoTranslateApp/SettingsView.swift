import SwiftUI
import AppKit
import VideoAutoTranslateCore

public struct SettingsView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab = .asrModels

    enum SettingsTab: String, CaseIterable, Identifiable {
        case asrModels = "模型与存储"
        case asrService = "ASR 服务"
        case translation = "翻译引擎"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .asrModels: return "externaldrive.fill.badge.icloud"
            case .asrService: return "waveform"
            case .translation: return "character.bubble"
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
                .frame(width: 320)

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

            Section(header: Text("网络下载源加速 (针对新设备部署)").font(.headline)) {
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
                    modelPresetRow(preset)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func modelPresetRow(_ preset: ASRModelPreset) -> some View {
        let state = appState.modelStorageManager.modelStates[preset.id] ?? .notDownloaded

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
                            appState.modelStorageManager.cancelDownload(for: preset.id)
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
                            appState.downloadModel(preset: preset)
                        }
                        .font(.caption)
                    }

                case .notDownloaded:
                    Button("立即下载") {
                        appState.downloadModel(preset: preset)
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 4)
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

                HStack {
                    TextField("ASR 接口 URL", text: $appState.project.asrConfig.serviceURL)
                    Button("测试连通") {
                        Task {
                            await appState.probeLocalASR()
                        }
                    }
                }
                TextField("默认 ASR 模型标识", text: $appState.project.asrConfig.model)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 翻译引擎 Tab

    private var translationSettingsView: some View {
        Form {
            Section(header: Text("大语言模型翻译引擎").font(.headline)) {
                Picker("模式选择", selection: $appState.project.llmConfig.providerType) {
                    ForEach(LLMProviderType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 4)

                if appState.project.llmConfig.providerType == .localOllama {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("Ollama 服务地址", text: $appState.project.llmConfig.ollamaBaseURL)
                            Button("刷新探测") {
                                Task {
                                    await appState.probeLocalOllama()
                                }
                            }
                        }

                        if !appState.availableOllamaModels.isEmpty {
                            Picker("选择本地已安装模型", selection: $appState.project.llmConfig.ollamaModel) {
                                ForEach(appState.availableOllamaModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                        } else {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundColor(.orange)
                                Text("未检测到运行中的 Ollama 服务，请确认终端已执行 `ollama serve`")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("API Base URL", text: $appState.project.llmConfig.onlineBaseURL)
                        SecureField("API Key", text: $appState.project.llmConfig.onlineAPIKey)
                        TextField("模型 ID (如 deepseek-chat)", text: $appState.project.llmConfig.onlineModel)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section(header: Text("翻译目标语言与参数").font(.headline)) {
                TextField("目标语言", text: $appState.project.llmConfig.targetLanguage)
                Stepper("最大并发请求数: \(appState.project.llmConfig.maxConcurrency)", value: $appState.project.llmConfig.maxConcurrency, in: 1...8)
                HStack {
                    Text("采样温度: \(String(format: "%.1f", appState.project.llmConfig.temperature))")
                    Slider(value: $appState.project.llmConfig.temperature, in: 0.0...1.0, step: 0.1)
                }
            }
        }
        .formStyle(.grouped)
    }
}
