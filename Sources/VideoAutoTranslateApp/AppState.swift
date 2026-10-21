import Foundation
import SwiftUI
import AVFoundation
import AppKit
import VideoAutoTranslateCore

@MainActor
public final class AppState: ObservableObject {
    @Published public var project: ProjectState = ProjectState() {
        didSet {
            bindProjectSubtitles()
        }
    }
    public let player: AVPlayer = AVPlayer()
    @Published public var isPlaying: Bool = false
    @Published public var currentTime: CMTime = .zero

    // 引擎与管理实例
    public let audioExtractor = AudioExtractor()
    public var asrEngine = LocalASRService()
    public let translator = SubtitleTranslator()
    public let subtitleManager = SubtitleManager()
    public let audioMixer = AudioMixer()
    public let videoComposer = VideoComposer()
    public let ttsService = SystemTTSService()
    public let ollamaProbe = OllamaProbe()
    public let llmSegmenter = LLMSegmenter()
    @Published public var modelStorageManager = ModelStorageManager()
    @Published public var sidecarManager = ASRSidecarManager.shared

    // 设置与探测
    @Published public var availableOllamaModels: [String] = []
    @Published public var isASRServerOnline: Bool = false
    @Published public var showSettings: Bool = false
    @Published public var showHelp: Bool = false
    @Published public var showExportSheet: Bool = false
    @Published public var statusMessage: String = "就绪"
    @Published public var errorMessage: String? = nil

    // R20: 持有试听播放器实例，防止局部变量析构导致播放被打断
    public var auditionPlayer: AVPlayer?

    // R03 & FU05: 任务代际与句柄持有，防止更换视频或取消后旧任务写入新项目
    private var projectGeneration: Int = 0
    private var transcriptionTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var dubbingTask: Task<Void, Never>?
    private var activeTranscriptionTask: Task<Void, Never>?
    private var activeTranslationTask: Task<Void, Error>?
    private var activeDubbingTask: Task<Void, Error>?

    // 撤销 / 重做历史状态堆栈
    private var undoStack: [[SubtitleItem]] = []
    private var redoStack: [[SubtitleItem]] = []
    @Published public var canUndo: Bool = false
    @Published public var canRedo: Bool = false
    private let maxUndoHistory: Int = 40
    private var lastTextEditSnapshotTime: Date = .distantPast

    private var timeObserverToken: Any?

    private func bindProjectSubtitles() {
        for item in project.subtitles {
            item.onModified = { [weak self] in
                guard let self = self else { return }
                if Date().timeIntervalSince(self.lastTextEditSnapshotTime) > 1.2 {
                    self.recordUndoSnapshot()
                    self.lastTextEditSnapshotTime = Date()
                }
                if !self.project.isDirty {
                    self.project.isDirty = true
                }
            }
        }
    }

    public init() {
        setupTimeObserver()
        bindProjectSubtitles()
        Task {
            await sidecarManager.probeExistingStatus()
            await probeLocalOllama()
            await probeLocalASR()
        }

        // 监听外部打开视频文件事件
        NotificationCenter.default.addObserver(
            forName: Notification.Name("com.videoautotranslate.openVideoFile"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let url = note.object as? URL {
                Task { @MainActor in
                    self?.openVideo(url: url)
                }
            }
        }

        // 自动检测命令行传入的视频路径参数
        for arg in CommandLine.arguments.dropFirst() {
            if !arg.hasPrefix("-") && FileManager.default.fileExists(atPath: arg) {
                let ext = (arg as NSString).pathExtension.lowercased()
                if ["mp4", "mov", "m4v", "mkv", "avi", "webm"].contains(ext) {
                    openVideo(url: URL(fileURLWithPath: arg))
                    break
                }
            }
        }
    }

    /// 探测本地 ASR 服务
    public func probeLocalASR() async {
        let (online, _) = await LocalASRService.testConnection(urlString: project.asrConfig.serviceURL)
        await MainActor.run {
            self.isASRServerOnline = online
            if online && !self.sidecarManager.status.isRunning {
                self.sidecarManager.status = .running(pid: 0, port: self.sidecarManager.defaultPort)
            }
        }
    }

    /// 详细测试当前 ASR 配置 URL 连通性
    public func testASRConnection() async -> (success: Bool, message: String) {
        return await LocalASRService.testConnection(urlString: project.asrConfig.serviceURL)
    }

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
    }

    /// 监听播放器时间，实时联动高亮字幕
    private func setupTimeObserver() {
        let interval = CMTime(value: 100, timescale: 1000) // 100ms
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.currentTime = time
                self.updateSelectedSubtitle(for: time)
            }
        }
    }

    /// 自动根据时间高亮当前发音字幕 (R30: 仅更新 playingSubtitleID，不抢占用户的 selectedSubtitleID)
    private func updateSelectedSubtitle(for time: CMTime) {
        if let current = project.subtitles.first(where: { time >= $0.startTime && time <= $0.endTime }) {
            if project.playingSubtitleID != current.id {
                project.playingSubtitleID = current.id
            }
        } else {
            project.playingSubtitleID = nil
        }
    }

    /// 探测本地 Ollama
    public func probeLocalOllama() async {
        let models = await ollamaProbe.fetchLocalModels(baseURL: project.llmConfig.ollamaBaseURL)
        await MainActor.run {
            self.availableOllamaModels = models
            if let preferred = self.ollamaProbe.findPreferredQwenModel(in: models) {
                self.project.llmConfig.ollamaModel = preferred
                self.project.llmConfig.providerType = .localOllama
            }
        }
    }

    /// 取消所有正在执行的后台任务 (R03 & FU05)
    public func cancelAllTasks() {
        projectGeneration += 1
        activeTranscriptionTask?.cancel()
        activeTranscriptionTask = nil
        activeTranslationTask?.cancel()
        activeTranslationTask = nil
        activeDubbingTask?.cancel()
        activeDubbingTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        translationTask?.cancel()
        translationTask = nil
        dubbingTask?.cancel()
        dubbingTask = nil
        project.isProcessing = false
        statusMessage = "任务已取消"
    }

    /// 打开本地视频文件 (R03: 递增代际，终止旧任务)
    public func openVideo(url: URL) {
        cancelAllTasks()
        projectGeneration += 1

        undoStack.removeAll()
        redoStack.removeAll()
        canUndo = false
        canRedo = false

        project.reset()
        project.videoURL = url

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        statusMessage = "已加载视频: \(url.lastPathComponent)"
    }

    /// 跳转视频到指定时间
    public func seek(to time: CMTime) {
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 执行本地音频提取与语音转录 (R03 & FU05: 严格代际校验与取消保护)
    public func runTranscription() async {
        guard let videoURL = project.videoURL else { return }

        transcriptionTask?.cancel()
        activeTranscriptionTask?.cancel()
        let currentGen = projectGeneration

        project.isProcessing = true
        project.currentStepName = "正在提取音频..."
        project.progress = 0.1
        statusMessage = "正在提取音频..."

        let worker = Task { () -> [SubtitleItem] in
            let tempDir = FileManager.default.temporaryDirectory
            let wavURL = tempDir.appendingPathComponent("extracted_\(UUID().uuidString).wav")
            try await audioExtractor.extract16kMonoWav(from: videoURL, to: wavURL)
            guard currentGen == self.projectGeneration, !Task.isCancelled else { throw CancellationError() }
            await MainActor.run {
                if currentGen == self.projectGeneration && !Task.isCancelled {
                    self.project.audioURL = wavURL
                    self.project.currentStepName = "正在按需准备本地 ASR 推理引擎..."
                    self.project.progress = 0.25
                    self.statusMessage = "正在按需准备本地 ASR 推理引擎..."
                }
            }
            _ = await sidecarManager.ensureRunning()
            await probeLocalASR()

            guard currentGen == self.projectGeneration, !Task.isCancelled else { throw CancellationError() }

            await MainActor.run {
                if currentGen == self.projectGeneration && !Task.isCancelled {
                    self.project.currentStepName = "正在调用 Qwen3-ASR 执行转录与词级对齐..."
                    self.project.progress = 0.4
                    self.statusMessage = "正在识别语音并生成逐词时间戳..."
                }
            }

            let asrService = LocalASRService(config: project.asrConfig)
            return try await asrService.transcribe(audioURL: wavURL) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self = self, self.projectGeneration == currentGen, !Task.isCancelled else { return }
                    self.project.progress = 0.4 + progress * 0.5
                }
            }
        }
        self.activeTranscriptionTask = Task { _ = try? await worker.value }

        do {
            let items = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard currentGen == projectGeneration, !Task.isCancelled else { return }

            var finalItems = items
            var usedLLMSegmentation = false
            // 若大模型可用，进一步执行大模型智能语义断句规整
            let allTokens = items.flatMap { $0.words }
            if !allTokens.isEmpty && (project.llmConfig.providerType == .localOllama || !project.llmConfig.onlineAPIKey.isEmpty) {
                let modelName = project.llmConfig.effectiveModel
                project.currentStepName = "正在调用大模型 (\(modelName)) 执行智能语义断句规整..."
                statusMessage = "正在调用大模型 (\(modelName)) 执行智能语义断句规整..."
                project.progress = 0.92
                if let smartItems = try? await llmSegmenter.segment(tokens: allTokens, config: project.llmConfig), !smartItems.isEmpty {
                    finalItems = smartItems
                    usedLLMSegmentation = true
                }
            }

            guard currentGen == projectGeneration, !Task.isCancelled else { return }
            project.subtitles = finalItems
            undoStack.removeAll()
            redoStack.removeAll()
            canUndo = false
            canRedo = false
            project.isProcessing = false
            project.progress = 1.0
            project.isDirty = true
            if usedLLMSegmentation {
                statusMessage = "转录与智能断句完成，已由大模型规整为 \(finalItems.count) 行字幕"
            } else {
                statusMessage = "转录完成，共生成 \(finalItems.count) 行字幕"
            }
        } catch {
            guard currentGen == projectGeneration, !Task.isCancelled else { return }
            project.isProcessing = false
            statusMessage = "识别失败: \(error.localizedDescription)"
            errorMessage = "转录识别失败: \(error.localizedDescription)"
        }
    }

    /// 执行字幕翻译 (R03, R07 & FU05: 任务防交叉、取消传递与脏状态标记)
    public func runTranslation() async {
        guard !project.subtitles.isEmpty else { return }

        translationTask?.cancel()
        activeTranslationTask?.cancel()
        let currentGen = projectGeneration

        project.isProcessing = true
        project.currentStepName = "正在使用 \(project.llmConfig.effectiveModel) 翻译字幕..."
        project.progress = 0.0

        let worker = Task { () -> Void in
            try await translator.translate(
                items: project.subtitles,
                config: project.llmConfig
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self = self, self.projectGeneration == currentGen, !Task.isCancelled else { return }
                    self.project.progress = progress
                }
            }
        }
        self.activeTranslationTask = worker

        do {
            try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard currentGen == projectGeneration, !Task.isCancelled else { return }
            project.subtitles = Array(project.subtitles)
            project.isProcessing = false
            project.progress = 1.0
            project.isDirty = true
            statusMessage = "翻译完成，已为 \(project.subtitles.count) 行字幕生成译文"
        } catch {
            guard currentGen == projectGeneration, !Task.isCancelled else { return }
            project.isProcessing = false
            statusMessage = "翻译失败: \(error.localizedDescription)"
            errorMessage = "翻译失败: \(error.localizedDescription)"
        }
    }

    /// 执行多语言配音与混音 (R19 & FU05: 传入所选目标语言音色代码，await 前后严格代际校验)
    public func runFullDubbing() async {
        guard !project.subtitles.isEmpty else { return }

        dubbingTask?.cancel()
        activeDubbingTask?.cancel()
        let currentGen = projectGeneration

        project.isProcessing = true
        project.currentStepName = "正在合成新语言配音片段..."
        project.progress = 0.0

        let voice = project.llmConfig.targetLanguageVoiceCode

        let worker = Task { () -> Void in
            let total = Double(project.subtitles.count)
            for (idx, item) in project.subtitles.enumerated() {
                guard currentGen == self.projectGeneration, !Task.isCancelled else { return }
                try await subtitleManager.reDub(item: item, ttsService: ttsService, voice: voice)
                guard currentGen == self.projectGeneration, !Task.isCancelled else { return }
                await MainActor.run {
                    if currentGen == self.projectGeneration && !Task.isCancelled {
                        self.project.progress = Double(idx + 1) / total
                    }
                }
            }

            guard currentGen == self.projectGeneration, !Task.isCancelled else { return }

            await MainActor.run {
                if currentGen == self.projectGeneration && !Task.isCancelled {
                    self.project.currentStepName = "正在执行音频无损伸缩与闪避混音..."
                }
            }
            let tempDir = FileManager.default.temporaryDirectory
            let mixedAudioURL = tempDir.appendingPathComponent("mixed_dubbed_\(UUID().uuidString).m4a")

            try await audioMixer.mix(
                backgroundAudioURL: project.audioURL,
                subtitles: project.subtitles,
                to: mixedAudioURL
            )
        }
        self.activeDubbingTask = worker

        do {
            try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard currentGen == projectGeneration, !Task.isCancelled else { return }
            project.isProcessing = false
            project.isDirty = true
            statusMessage = "配音合成完成！可导出新视频"
        } catch {
            guard currentGen == projectGeneration, !Task.isCancelled else { return }
            project.isProcessing = false
            statusMessage = "配音生成失败: \(error.localizedDescription)"
        }
    }

    /// 试听单句配音音频 (R19: 传入对应目标语言音色; R20: 持有 player 实例)
    public func auditionSubtitle(_ item: SubtitleItem) async {
        do {
            let voice = project.llmConfig.targetLanguageVoiceCode
            if item.dubbedAudioURL == nil || !FileManager.default.fileExists(atPath: item.dubbedAudioURL!.path) {
                try await subtitleManager.reDub(item: item, ttsService: ttsService, voice: voice)
            }
            if let audioURL = item.dubbedAudioURL {
                let p = AVPlayer(url: audioURL)
                self.auditionPlayer = p
                p.play()
            }
        } catch {
            statusMessage = "试听生成失败: \(error.localizedDescription)"
        }
    }

    // MARK: - 撤销与重做支持

    /// 创建当前字幕列表的独立深拷贝快照
    public func createSubtitlesSnapshot() -> [SubtitleItem] {
        return project.subtitles.map { item in
            SubtitleItem(
                id: item.id,
                startTime: item.startTime,
                endTime: item.endTime,
                originalText: item.originalText,
                translatedText: item.translatedText,
                words: item.words,
                dubbedAudioURL: item.dubbedAudioURL
            )
        }
    }

    /// 记录当前状态至撤销历史堆栈
    public func recordUndoSnapshot() {
        let snapshot = createSubtitlesSnapshot()
        undoStack.append(snapshot)
        if undoStack.count > maxUndoHistory {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    /// 撤销上一步操作 (Cmd+Z)
    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        let current = createSubtitlesSnapshot()
        redoStack.append(current)
        project.subtitles = previous
        canUndo = !undoStack.isEmpty
        canRedo = true
        project.isDirty = true
        statusMessage = "已撤销上一步操作"
    }

    /// 恢复上一步被撤销的操作 (Cmd+Shift+Z)
    public func redo() {
        guard let next = redoStack.popLast() else { return }
        let current = createSubtitlesSnapshot()
        undoStack.append(current)
        project.subtitles = next
        canUndo = true
        canRedo = !redoStack.isEmpty
        project.isDirty = true
        statusMessage = "已重做操作"
    }

    /// 校验是否满足合并条件：至少选中 2 行且必须在时间轴上相邻连续
    public func canMerge(ids: Set<UUID>) -> Bool {
        guard ids.count >= 2 else { return false }
        let indices = project.subtitles.enumerated()
            .filter { ids.contains($1.id) }
            .map { $0.offset }
            .sorted()
        guard indices.count == ids.count else { return false }
        for i in 0..<(indices.count - 1) {
            if indices[i+1] != indices[i] + 1 {
                return false
            }
        }
        return true
    }

    /// 拆分指定字幕 (R14: 绑定确切行 ID，防止错位拆分)
    public func splitSubtitle(id: UUID, atCharIndex: Int) {
        guard let index = project.subtitles.firstIndex(where: { $0.id == id }) else { return }
        let target = project.subtitles[index]
        if let (part1, part2) = subtitleManager.split(item: target, atCharIndex: atCharIndex) {
            recordUndoSnapshot()
            project.subtitles.remove(at: index)
            project.subtitles.insert(part2, at: index)
            project.subtitles.insert(part1, at: index)
            project.selectedSubtitleID = part1.id
            project.isDirty = true
            statusMessage = "已成功拆分字幕"
        }
    }

    /// 拆分当前选中的字幕 (Cmd+B: 严格在光标所在字词位置切开)
    public func splitCurrentSubtitle(atCharIndex: Int? = nil) {
        guard let selectedID = project.selectedSubtitleID,
              let item = project.subtitles.first(where: { $0.id == selectedID }) else {
            errorMessage = "请先选择需要拆分的字幕行"
            return
        }

        var charIndex = atCharIndex
        if charIndex == nil {
            if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
               textView.string == item.originalText {
                let loc = textView.selectedRange().location
                if loc != NSNotFound {
                    charIndex = loc
                }
            }
        }

        guard let targetIndex = charIndex, targetIndex > 0, targetIndex < item.originalText.count else {
            errorMessage = "请先在文本框中将光标放置在想要拆分的字词之间"
            statusMessage = "拆分提示：请先在字幕文本中放置光标"
            NSSound.beep()
            return
        }

        splitSubtitle(id: selectedID, atCharIndex: targetIndex)
    }

    /// 执行大模型语义智能分句规整 (将每个词的精确定位发给大模型重构断句时间轴)
    public func runSmartSegmentation() async {
        guard !project.subtitles.isEmpty else { return }

        // 收集全部物理 WordTokens
        var allTokens: [WordToken] = []
        for item in project.subtitles {
            if !item.words.isEmpty {
                allTokens.append(contentsOf: item.words)
            } else {
                allTokens.append(WordToken(text: item.originalText, startTime: item.startTime, endTime: item.endTime))
            }
        }

        guard !allTokens.isEmpty else { return }

        recordUndoSnapshot()
        project.isProcessing = true
        project.currentStepName = "正在调用大模型执行智能语义断句规整..."
        project.progress = 0.3
        statusMessage = "正在结合字词精确时间戳进行 AI 智能语义分句..."

        do {
            let smartItems = try await llmSegmenter.segment(tokens: allTokens, config: project.llmConfig)
            guard !smartItems.isEmpty else {
                project.isProcessing = false
                statusMessage = "智能分句未能生成有效结果，保留原有字幕"
                return
            }

            project.subtitles = smartItems
            project.selectedSubtitleID = smartItems.first?.id
            project.isProcessing = false
            project.progress = 1.0
            project.isDirty = true
            statusMessage = "AI 智能分句完成！已规整为 \(smartItems.count) 行自然字幕"
        } catch {
            project.isProcessing = false
            statusMessage = "智能分句失败: \(error.localizedDescription)"
            errorMessage = "智能分句失败: \(error.localizedDescription)"
        }
    }

    /// 合并选中的字幕 (Cmd+J) (R15: 严格连续性校验)
    public func mergeSubtitles(ids: Set<UUID>) {
        guard ids.count >= 2 else {
            errorMessage = "请先选中至少两行相邻字幕进行合并"
            statusMessage = "合并失败：需选中至少两行字幕"
            return
        }

        // 获取被选中的索引并排序
        let indices = project.subtitles.enumerated()
            .filter { ids.contains($1.id) }
            .map { $0.offset }
            .sorted()

        guard indices.count >= 2 else { return }

        // 校验连续性：不允许跨越未选中项合并
        for i in 0..<(indices.count - 1) {
            if indices[i+1] != indices[i] + 1 {
                errorMessage = "只能合并相邻连续的字幕项"
                statusMessage = "合并失败：所选字幕不连续"
                return
            }
        }

        recordUndoSnapshot()

        let selectedItems = indices.map { project.subtitles[$0] }
        if let merged = subtitleManager.merge(items: selectedItems) {
            let firstIndex = indices.first!
            project.subtitles.removeAll(where: { ids.contains($0.id) })
            project.subtitles.insert(merged, at: firstIndex)
            project.selectedSubtitleID = merged.id
            project.isDirty = true
            statusMessage = "已合并 \(selectedItems.count) 条字幕"
        }
    }

    // MARK: - 工程持久化与存取 (R04)

    /// 保存当前工程 (Cmd+S)
    public func saveProject(to url: URL) throws {
        let data = try project.encodeDocument()
        try data.write(to: url, options: .atomic)
        project.isDirty = false
        statusMessage = "工程已保存: \(url.lastPathComponent)"
    }

    /// 从文件加载工程
    public func loadProject(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let doc = try decoder.decode(ProjectDocument.self, from: data)
        cancelAllTasks()
        projectGeneration += 1
        project.reset()
        project.restore(from: doc)
        if let video = project.videoURL {
            let item = AVPlayerItem(url: video)
            player.replaceCurrentItem(with: item)
        }
        statusMessage = "已加载工程: \(url.lastPathComponent)"
    }

    // MARK: - 模型存储与下载管理

    /// 同步当前存储配置到服务端
    public func syncModelStorageToServer() async {
        guard let url = URL(string: "http://127.0.0.1:8765/v1/models/storage") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let path = modelStorageManager.resolvedStorageDirectory().path
        let body = ["storage_dir": path]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    /// 打开系统目录选择器，选择自定义模型保存路径
    public func chooseCustomModelDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择模型存放目录"
        if panel.runModal() == .OK, let selected = panel.url {
            project.modelStorageConfig.customDirectoryPath = selected.path
            project.modelStorageConfig.locationType = .custom
            modelStorageManager.config = project.modelStorageConfig
            modelStorageManager.refreshAll()
            Task {
                await syncModelStorageToServer()
            }
        }
    }

    /// 在访达中打开当前生效的模型目录
    public func revealCurrentModelDirectoryInFinder() {
        let dir = modelStorageManager.resolvedStorageDirectory()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
    }

    /// 触发指定模型的下载 (R23: 首次下载先准备 sidecar 服务，避免连接失败或遗留下载中状态)
    public func downloadModel(preset: ASRModelPreset) {
        Task {
            if preset.isRepo {
                _ = await sidecarManager.ensureRunning()
                do {
                    try await modelStorageManager.triggerServerRepoDownload(preset: preset)
                } catch {
                    await MainActor.run {
                        self.errorMessage = "启动模型下载失败: \(error.localizedDescription)"
                        self.statusMessage = "模型下载启动失败"
                    }
                }
            } else {
                modelStorageManager.startDirectDownload(for: preset)
            }
        }
    }
}
