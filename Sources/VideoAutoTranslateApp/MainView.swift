import SwiftUI
import UniformTypeIdentifiers
import VideoAutoTranslateCore

public struct MainView: View {
    @StateObject private var appState = AppState()
    @State private var isTargetedForDrop: Bool = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu("工程") {
                    Button("打开工程…") { appState.openProjectInteractively() }
                    Button("保存工程") { appState.saveProjectInteractively() }
                    Button("另存为…") { appState.saveProjectInteractively(chooseNewURL: true) }
                    Button("重新定位媒体…") { appState.relinkMedia() }
                }
                Text(appState.documentURL?.lastPathComponent ?? appState.project.videoURL?.lastPathComponent ?? "未命名工程")
                    .lineLimit(1)
                Text(appState.project.isDirty ? "有未保存修改 · \(appState.saveStatus)" : appState.saveStatus)
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }.padding(.horizontal, 12).padding(.vertical, 6)
            if appState.recoveryAvailable {
                HStack {
                    Text("发现上次编辑的恢复副本")
                    Button("恢复") { appState.restoreRecovery() }
                    Button("暂不恢复") { appState.recoveryAvailable = false }
                }.padding(8)
            }
            // 顶部一体化工作流工具栏
            topWorkflowBar

            Divider()

            if let text = appState.project.unalignedTranscript {
                DisclosureGroup("已识别文字，尚无时间对齐；请准备对齐模型后重试") {
                    ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
                    Button("打开模型设置") { appState.showSettings = true }
                }.padding(8)
            }
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
        .focusedSceneObject(appState)
        .background(WindowCloseGuard(appState: appState).frame(width: 0, height: 0))
        .sheet(item: $appState.editProposal) { proposal in EditProposalView(appState: appState, proposal: proposal) }
        .sheet(item: $appState.splitDraft) { draft in SplitReviewView(appState: appState, draft: draft) }
        .sheet(isPresented: $appState.showSettings) {
            SettingsView(appState: appState)
        }
        .sheet(isPresented: $appState.showHelp) {
            HelpView(appState: appState)
        }
        .sheet(isPresented: $appState.showExportSheet) {
            ExportView(appState: appState)
        }
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
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                workflowControls(compact: false).fixedSize(horizontal: true, vertical: false)
                workflowControls(compact: true)
            }
            Text("字幕 \(appState.project.subtitles.count) · 翻译 \(translatedCount)/\(appState.project.subtitles.count) · 配音 \(dubbedCount)/\(appState.project.subtitles.count) · 待复核 \(appState.project.subtitles.filter { $0.translationNeedsReview }.count)")
                .font(.caption).foregroundColor(.secondary)
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func workflowControls(compact: Bool) -> some View {
        HStack(spacing: 6) {
            Button(action: openVideoFilePicker) { workflowLabel("打开视频", image: "folder", compact: compact) }
                .help("打开或更换视频；先处理未保存修改")
            Menu {
                ForEach(ASRLanguagePreset.presets) { preset in
                    Button(preset.displayName) { appState.project.asrConfig.language = preset.code }
                }
            } label: { Text(compact ? "原语言" : currentASRLanguageName) }
                .disabled(appState.project.isProcessing)
            Button { Task { await appState.runTranscription() } } label: { workflowLabel("语音转录", image: "waveform.and.mic", compact: compact) }
                .disabled(appState.project.videoURL == nil || appState.project.isProcessing)
                .help("识别语音；已有字幕时会先确认替换")
            Menu {
                ForEach(TargetLanguagePreset.defaultPresets) { preset in
                    Button(preset.name) { appState.project.llmConfig.targetLanguage = preset.name }
                }
            } label: { Text(compact ? "译语言" : shortTargetLanguageName) }
                .disabled(appState.project.isProcessing)
            Button { Task { await appState.runTranslation() } } label: { workflowLabel("字幕翻译", image: "character.book.closed", compact: compact) }
                .disabled(appState.project.subtitles.isEmpty || appState.project.isProcessing)
                .help("翻译字幕；人工校对内容请先保存")
            Button { Task { await appState.runFullDubbing() } } label: { workflowLabel("生成配音", image: "speaker.wave.2", compact: compact) }
                .disabled(!hasTranslations || appState.project.isProcessing)
                .help("按当前译文生成配音；缺译或超时会明确报告")
            Button { appState.showExportSheet = true } label: { workflowLabel("导出", image: "square.and.arrow.up", compact: compact) }
                .disabled(appState.project.videoURL == nil || appState.project.isProcessing)
            Spacer(minLength: 0)
            Button { appState.showHelp = true } label: { Image(systemName: "questionmark.circle") }
                .accessibilityLabel("使用帮助").help("使用帮助").keyboardShortcut("?", modifiers: .command)
            Button { appState.showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("偏好设置").help("偏好设置").disabled(appState.project.isProcessing)
        }.buttonStyle(.bordered)
    }

    private func workflowLabel(_ title: String, image: String, compact: Bool) -> some View {
        HStack(spacing: 4) { Image(systemName: image); if !compact { Text(title).lineLimit(1) } }
            .accessibilityLabel(title)
    }

    private var translatedCount: Int { appState.project.subtitles.filter { !$0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.translationNeedsReview }.count }
    private var dubbedCount: Int { appState.project.subtitles.filter { $0.hasCurrentAudio(voice: appState.project.llmConfig.targetLanguageVoiceCode) }.count }

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
        appState.project.subtitles.allSatisfy { !$0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.translationNeedsReview }
    }

    private var hasDubbing: Bool {
        !appState.project.subtitles.isEmpty &&
        appState.project.subtitles.allSatisfy { $0.hasCurrentAudio(voice: appState.project.llmConfig.targetLanguageVoiceCode) }
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
            if appState.exportJob.isRunning {
                ProgressView(value: appState.exportJob.progress).frame(width: 120)
                Text(appState.exportJob.message).font(.caption)
                Button("取消导出") { appState.exportJob.cancel() }
            } else if appState.project.isProcessing {
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
                Image(systemName: appState.feedbackKind == .failure ? "exclamationmark.triangle.fill" : appState.feedbackKind == .success ? "checkmark.circle.fill" : "info.circle")
                    .foregroundColor(appState.feedbackKind == .failure ? .red : appState.feedbackKind == .success ? .green : .secondary)
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
