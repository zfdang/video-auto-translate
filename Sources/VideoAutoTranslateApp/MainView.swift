import SwiftUI
import UniformTypeIdentifiers
import VideoAutoTranslateCore

public struct MainView: View {
    @StateObject private var appState = AppState()
    @State private var isTargetedForDrop: Bool = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部一体化工作流工具栏
            topWorkflowBar

            Divider()

            // 主工作区（左侧播放器 + 右侧字幕时间轴）
            HSplitView {
                // 左侧视频区
                VStack(spacing: 0) {
                    if appState.project.videoURL != nil {
                        VideoPlayerView(appState: appState)
                    } else {
                        dropVideoPromptView
                    }
                }
                .frame(minWidth: 400, idealWidth: 600)

                // 右侧字幕时间轴列表
                SubtitleListView(appState: appState)
                    .frame(minWidth: 320, idealWidth: 420)
            }

            Divider()

            // 底部状态栏与进度
            bottomStatusBar
        }
        .sheet(isPresented: $appState.showSettings) {
            SettingsView(appState: appState)
        }
        .sheet(isPresented: $appState.showHelp) {
            HelpView(appState: appState)
        }
        .sheet(isPresented: $appState.showExportSheet) {
            ExportView(appState: appState)
        }
        .focusedSceneObject(appState)
        .focusedSceneObject(appState)
        .alert("提示", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            if let msg = appState.errorMessage, msg.contains("设置") || msg.contains("下载") {
                Button("打开设置") {
                    appState.errorMessage = nil
                    appState.showSettings = true
                }
                Button("我知道了", role: .cancel) {
                    appState.errorMessage = nil
                }
            } else {
                Button("确定", role: .cancel) { appState.errorMessage = nil }
            }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargetedForDrop) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let fileURL = url {
                    Task { @MainActor in
                        appState.openVideo(url: fileURL)
                    }
                }
            }
            return true
        }
    }

    // MARK: - 顶部一体化工作流工具栏
    private var topWorkflowBar: some View {
        HStack(spacing: 6) {
            // 步骤 1: 导入视频
            HStack(spacing: 6) {
                StepBadge(
                    step: 1,
                    isCompleted: appState.project.videoURL != nil,
                    isActive: appState.project.videoURL == nil
                )

                if appState.project.videoURL == nil {
                    Button(action: openVideoFilePicker) {
                        Label("打开视频", systemImage: "folder.fill")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .help("打开本地待处理视频文件")
                } else {
                    Button(action: openVideoFilePicker) {
                        Label("更换视频", systemImage: "folder.fill")
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .help("更换当前本地待处理视频文件")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
            .fixedSize()
            .layoutPriority(1)

            workflowArrow

            // 步骤 2: 语音转录
            HStack(spacing: 4) {
                StepBadge(
                    step: 2,
                    isCompleted: !appState.project.subtitles.isEmpty,
                    isActive: isStep2Active
                )

                Menu {
                    ForEach(ASRLanguagePreset.presets) { preset in
                        Button(action: {
                            appState.project.asrConfig.language = preset.code
                        }) {
                            HStack {
                                Text(preset.displayName)
                                if appState.project.asrConfig.language == preset.code {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "globe")
                        Text(currentASRLanguageName)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .help("指定待识别音视频的原语言 (默认自动检测)")

                if isStep2Active {
                    Button(action: {
                        Task {
                            await appState.runTranscription()
                        }
                    }) {
                        Label("语音转录", systemImage: "waveform.and.mic")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .disabled(appState.project.videoURL == nil || appState.project.isProcessing)
                    .help("使用本地 Qwen3-ASR 提取毫秒级逐词时间戳，并自动调用大模型进行智能语义断句规整")
                } else {
                    Button(action: {
                        Task {
                            await appState.runTranscription()
                        }
                    }) {
                        Label("语音转录", systemImage: "waveform.and.mic")
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .disabled(appState.project.videoURL == nil || appState.project.isProcessing)
                    .help("使用本地 Qwen3-ASR 提取毫秒级逐词时间戳，并自动调用大模型进行智能语义断句规整")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
            .fixedSize()
            .layoutPriority(1)

            workflowArrow

            // 步骤 3: 字幕翻译
            HStack(spacing: 4) {
                StepBadge(
                    step: 3,
                    isCompleted: hasTranslations,
                    isActive: isStep3Active
                )

                Menu {
                    ForEach(TargetLanguagePreset.defaultPresets) { preset in
                        Button(action: {
                            appState.project.llmConfig.targetLanguage = preset.name
                        }) {
                            HStack {
                                Text(preset.name)
                                if appState.project.llmConfig.targetLanguage == preset.name {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "character.bubble")
                        Text(shortTargetLanguageName)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .help("选择字幕翻译的目标语言")

                if isStep3Active {
                    Button(action: {
                        Task {
                            await appState.runTranslation()
                        }
                    }) {
                        Label("字幕翻译", systemImage: "character.book.closed.fill")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .disabled(appState.project.subtitles.isEmpty || appState.project.isProcessing)
                    .help("使用本地大模型生成精准口语化双语字幕")
                } else {
                    Button(action: {
                        Task {
                            await appState.runTranslation()
                        }
                    }) {
                        Label("字幕翻译", systemImage: "character.book.closed.fill")
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .disabled(appState.project.subtitles.isEmpty || appState.project.isProcessing)
                    .help("使用本地大模型生成精准口语化双语字幕")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
            .fixedSize()
            .layoutPriority(1)

            workflowArrow

            // 步骤 4: 自动配音 (可选步骤，用括号括起来表示可跳过)
            HStack(spacing: 3) {
                Text("(")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.6))

                StepBadge(
                    step: 4,
                    isCompleted: hasDubbing,
                    isActive: hasTranslations && !hasDubbing,
                    isOptional: true
                )

                Button(action: {
                    Task {
                        await appState.runFullDubbing()
                    }
                }) {
                    Label("自动配音", systemImage: "speaker.wave.2.fill")
                }
                .buttonStyle(.bordered)
                .fixedSize()
                .disabled(!hasTranslations || appState.project.isProcessing)
                .help("可选步骤：合成新语言配音，并执行自适应语速对齐与背景音自动闪避混音（可跳过直接进入第5步导出成片）")

                Text(")")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
            .fixedSize()
            .layoutPriority(1)

            workflowArrow

            // 步骤 5: 导出成品
            HStack(spacing: 4) {
                StepBadge(
                    step: 5,
                    isCompleted: false,
                    isActive: !appState.project.subtitles.isEmpty
                )

                Button(action: {
                    appState.showExportSheet = true
                }) {
                    Label("导出成片", systemImage: "square.and.arrow.up.fill")
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(appState.project.subtitles.isEmpty)
                .help("导出双语字幕文件 (SRT/VTT) 或全新压制音画同步视频")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
            .fixedSize()
            .layoutPriority(1)

            Spacer()

            // 帮助按钮
            Button(action: {
                appState.showHelp = true
            }) {
                Image(systemName: "questionmark.circle")
                    .font(.body)
            }
            .buttonStyle(.bordered)
            .help("使用帮助与快捷键指南 (⌘?)")
            .keyboardShortcut("?", modifiers: .command)

            // 设置按钮
            Button(action: {
                appState.showSettings = true
            }) {
                Image(systemName: "gearshape.fill")
                    .font(.body)
            }
            .buttonStyle(.bordered)
            .help("偏好设置 (模型下载与存储、Ollama 与 ASR 引擎托管)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var workflowArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.secondary.opacity(0.45))
            .padding(.horizontal, 2)
    }

    private var isStep2Active: Bool {
        appState.project.videoURL != nil && appState.project.subtitles.isEmpty
    }

    private var isStep3Active: Bool {
        !appState.project.subtitles.isEmpty && !hasTranslations
    }

    private var hasTranslations: Bool {
        !appState.project.subtitles.isEmpty &&
        appState.project.subtitles.contains(where: { !$0.translatedText.isEmpty })
    }

    private var hasDubbing: Bool {
        !appState.project.subtitles.isEmpty &&
        appState.project.subtitles.contains(where: { $0.dubbedAudioURL != nil })
    }

    private var currentASRLanguageName: String {
        let code = appState.project.asrConfig.language
        if code == "auto" { return "自动检测" }
        if code == "zh" { return "中文" }
        if code == "en" { return "英语" }
        if code == "ja" { return "日语" }
        if code == "ko" { return "韩语" }
        if code == "yue" { return "粤语" }
        return ASRLanguagePreset.presets.first(where: { $0.code == code })?.displayName.components(separatedBy: " ").first ?? "自动检测"
    }

    private var shortTargetLanguageName: String {
        let full = appState.project.llmConfig.targetLanguage
        if full.contains(" (") {
            return full.components(separatedBy: " (").first ?? full
        }
        return full
    }

    // MARK: - 视频拖拽指引视图
    private var dropVideoPromptView: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 16) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 48))
                    .foregroundColor(isTargetedForDrop ? .accentColor : .secondary)

                Text("拖拽本地视频文件到此处")
                    .font(.title3)
                    .fontWeight(.medium)

                Text("支持 MP4, MOV, MKV, WebM 等常见视频格式")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("选择本地视频...") {
                    openVideoFilePicker()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(40)
        }
    }

    // MARK: - 底部状态栏
    private var bottomStatusBar: some View {
        HStack(spacing: 12) {
            if appState.project.isProcessing {
                ProgressView(value: appState.project.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 140)

                Text(appState.project.currentStepName)
                    .font(.caption)
                    .foregroundColor(.accentColor)

                Button(action: {
                    appState.cancelAllTasks()
                }) {
                    Text("取消")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("取消当前任务并释放模型资源")
            } else {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text(appState.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // 当前翻译引擎标识
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.caption2)
                Text(appState.project.llmConfig.providerType == .localOllama ? "Ollama: \(appState.project.llmConfig.ollamaModel)" : "API: \(appState.project.llmConfig.onlineModel)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func openVideoFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType.movie,
            UTType.video,
            UTType.quickTimeMovie,
            UTType.mpeg4Movie
        ]

        if panel.runModal() == .OK, let url = panel.url {
            appState.openVideo(url: url)
        }
    }
}

// MARK: - 工作流步骤指示徽标
struct StepBadge: View {
    let step: Int
    let isCompleted: Bool
    let isActive: Bool
    var isOptional: Bool = false

    var body: some View {
        ZStack {
            if isCompleted {
                Circle()
                    .fill(Color.green)
                    .frame(width: 18, height: 18)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            } else if isActive {
                Circle()
                    .fill(isOptional ? Color.accentColor.opacity(0.85) : Color.accentColor)
                    .frame(width: 18, height: 18)
                Text("\(step)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 18, height: 18)
                Text("\(step)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
    }
}
