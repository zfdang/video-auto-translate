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
        .sheet(isPresented: $appState.showExportSheet) {
            ExportView(appState: appState)
        }
        .alert("提示", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { appState.errorMessage = nil }
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
        HStack(spacing: 10) {
            // 1. 打开视频
            Button(action: openVideoFilePicker) {
                Label("打开视频", systemImage: "folder.fill")
            }
            .buttonStyle(.bordered)
            .help("打开本地视频文件")

            Divider().frame(height: 20)

            // 2. ASR 语音识别 (原语言选择 + 转录按钮)
            HStack(spacing: 4) {
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
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                        Text(currentASRLanguageName)
                            .font(.subheadline)
                    }
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .help("指定待识别音视频的原语言 (有助于消除误判并提升识别准确率)")

                Button(action: {
                    Task {
                        await appState.runTranscription()
                    }
                }) {
                    Label("一键转录", systemImage: "waveform.and.mic")
                }
                .buttonStyle(.bordered)
                .disabled(appState.project.videoURL == nil || appState.project.isProcessing)
                .help("使用本地 Qwen3-ASR 提取毫秒级逐词时间戳并智能断句")
            }

            // 3. 智能翻译 (目标语言选择 + 翻译按钮)
            HStack(spacing: 4) {
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
                    HStack(spacing: 4) {
                        Image(systemName: "character.bubble")
                        Text(shortTargetLanguageName)
                            .font(.subheadline)
                    }
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .help("选择字幕翻译的目标语言")

                Button(action: {
                    Task {
                        await appState.runTranslation()
                    }
                }) {
                    Label("智能翻译", systemImage: "character.book.closed.fill")
                }
                .buttonStyle(.bordered)
                .disabled(appState.project.subtitles.isEmpty || appState.project.isProcessing)
                .help("使用本地 Qwen 或在线大模型生成精准口语化双语字幕")
            }

            // 4. 自动配音
            Button(action: {
                Task {
                    await appState.runFullDubbing()
                }
            }) {
                Label("自动配音", systemImage: "speaker.wave.2.fill")
            }
            .buttonStyle(.bordered)
            .disabled(appState.project.subtitles.isEmpty || appState.project.isProcessing)
            .help("合成新语言配音，并执行自适应语速对齐与背景音自动闪避混音")

            Spacer()

            // 5. 导出成片与设置
            HStack(spacing: 8) {
                Button(action: {
                    appState.showExportSheet = true
                }) {
                    Label("导出成片", systemImage: "square.and.arrow.up.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.project.subtitles.isEmpty)
                .help("导出双语字幕文件 (SRT/VTT) 或全新压制音画同步视频")

                Button(action: {
                    appState.showSettings = true
                }) {
                    Image(systemName: "gearshape.fill")
                        .font(.body)
                }
                .buttonStyle(.bordered)
                .help("偏好设置 (模型下载与存储、Ollama 与 ASR 引擎托管)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
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
