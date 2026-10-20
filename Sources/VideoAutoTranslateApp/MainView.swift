import SwiftUI
import UniformTypeIdentifiers
import VideoAutoTranslateCore

public struct MainView: View {
    @StateObject private var appState = AppState()
    @State private var isTargetedForDrop: Bool = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
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
        .toolbar {
            toolbarItems
        }
        .sheet(isPresented: $appState.showSettings) {
            SettingsView(appState: appState)
        }
        .sheet(isPresented: $appState.showExportSheet) {
            ExportView(appState: appState)
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

    // MARK: - 顶部工具栏
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: openVideoFilePicker) {
                Label("打开视频", systemImage: "folder")
            }
            .help("打开本地视频文件")
        }

        ToolbarItemGroup(placement: .principal) {
            Button(action: {
                Task {
                    await appState.runTranscription()
                }
            }) {
                Label("语音转录", systemImage: "waveform.and.mic")
            }
            .disabled(appState.project.videoURL == nil || appState.project.isProcessing)
            .help("使用 Qwen 本地模型进行毫秒级语音识别与断句")

            Button(action: {
                Task {
                    await appState.runTranslation()
                }
            }) {
                Label("智能翻译", systemImage: "character.book.closed")
            }
            .disabled(appState.project.subtitles.isEmpty || appState.project.isProcessing)
            .help("使用本地 Qwen 或在线大模型翻译字幕")

            Button(action: {
                Task {
                    await appState.runFullDubbing()
                }
            }) {
                Label("自动配音", systemImage: "speaker.wave.2")
            }
            .disabled(appState.project.subtitles.isEmpty || appState.project.isProcessing)
            .help("合成新语言配音，并执行自适应语速对齐与闪避混音")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: {
                appState.showExportSheet = true
            }) {
                Label("导出成片", systemImage: "square.and.arrow.up")
            }
            .disabled(appState.project.subtitles.isEmpty)
            .help("导出 SRT/VTT 字幕或全新合成视频")

            Button(action: {
                appState.showSettings = true
            }) {
                Label("设置", systemImage: "gear")
            }
            .help("配置本地 Ollama 或在线大模型参数")
        }
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
