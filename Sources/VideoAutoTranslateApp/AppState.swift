import Foundation
import SwiftUI
import AVFoundation
import AppKit
import Combine
import VideoAutoTranslateCore

@MainActor
public final class AppState: ObservableObject {
    public static weak var current: AppState?
    @Published public var documentURL: URL?
    @Published public var saveStatus = "尚未保存"
    @Published public var recoveryAvailable = false
    private var recoveryTask: Task<Void, Never>?
    private var recoveryWrite: Task<Void, Error>?
    private let persistsRecovery: Bool
    private let recoveryURL: URL

    @Published public var project: ProjectState = ProjectState() {
        didSet {
            bindProjectSubtitles()
            if project.isDirty && (!oldValue.isDirty || oldValue.subtitles.map(\.id) != project.subtitles.map(\.id)) { scheduleRecovery() }
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
    public let timelineAligner = TimelineAligner()
    public let audioMixer = AudioMixer()
    public let videoComposer = VideoComposer()
    public let ttsService = SystemTTSService()
    public let ollamaProbe = OllamaProbe()
    public let llmSegmenter = LLMSegmenter()
    @Published public var modelStorageManager = ModelStorageManager()
    @Published public var sidecarManager = ASRSidecarManager.shared

    // 设置与探测
    @Published public var availableOllamaModels: [String] = []
    @Published public var ollamaPullStates: [String: ModelState] = [:]
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
    private var editingTask: Task<[SubtitleItem], Error>?

    // 撤销 / 重做历史状态堆栈
    private var undoStack: [[SubtitleItem]] = []
    private var redoStack: [[SubtitleItem]] = []
    @Published public var canUndo: Bool = false
    @Published public var canRedo: Bool = false
    private let maxUndoHistory: Int = 40
    private var lastTextEditID: UUID?
    private var lastTextEditSnapshotTime: Date = .distantPast

    private var timeObserverToken: Any?
    private var cancellables = Set<AnyCancellable>()
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    private func bindProjectSubtitles() {
        for item in project.subtitles {
            let itemID = item.id
            item.onModified = { [weak self] in
                guard let self = self else { return }
                if !self.project.isProcessing && (self.lastTextEditID != itemID || Date().timeIntervalSince(self.lastTextEditSnapshotTime) > 1.2) {
                    self.recordUndoSnapshot()
                    self.lastTextEditSnapshotTime = Date()
                    self.lastTextEditID = itemID
                }
                if !self.project.isDirty { self.project.isDirty = true }
                self.scheduleRecovery()
            }
        }
    }

    public init(probeServices: Bool = true, recoveryURL: URL? = nil) {
        self.persistsRecovery = probeServices || recoveryURL != nil
        self.recoveryURL = recoveryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VideoAutoTranslate/Recovery.vatproject")
        self.recoveryAvailable = probeServices && FileManager.default.fileExists(atPath: self.recoveryURL.path)
        AppState.current = self
        setupTimeObserver()
        bindProjectSubtitles()

        // 桥接嵌套 ObservableObject 的变更通知至 AppState，保证 SwiftUI 界面第 0 毫秒即时刷新
        modelStorageManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        sidecarManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        if probeServices {
            Task {
                await sidecarManager.probeExistingStatus()
                await probeLocalOllama()
                await probeLocalASR()
            }
        }

        // 监听外部打开视频文件事件
        NotificationCenter.default.addObserver(
            forName: Notification.Name("com.videoautotranslate.openVideoFile"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let url = note.object as? URL {
                Task { @MainActor [weak self] in
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

    /// 详细探测本地 Ollama 并更新模型列表与即时连通反馈
    @discardableResult
    public func probeLocalOllamaDetailed() async -> (success: Bool, message: String) {
        let res = await ollamaProbe.probeDetailed(baseURL: project.llmConfig.ollamaBaseURL)
        await MainActor.run {
            self.availableOllamaModels = res.models
            if !res.models.isEmpty {
                if !res.models.contains(self.project.llmConfig.ollamaModel) {
                    if let preferred = self.ollamaProbe.findPreferredQwenModel(in: res.models) {
                        self.project.llmConfig.ollamaModel = preferred
                    } else if let first = res.models.first {
                        self.project.llmConfig.ollamaModel = first
                    }
                }
                self.project.llmConfig.providerType = .localOllama
            }
        }
        return (res.success, res.message)
    }

    /// 探测本地 Ollama
    public func probeLocalOllama() async {
        _ = await probeLocalOllamaDetailed()
    }

    /// 一键从 Ollama 官方源拉取推荐大语言模型并实时报告下载进度
    public func pullOllamaModel(name: String) {
        Task {
            await MainActor.run {
                self.ollamaPullStates[name] = .downloading(progress: 0.05, speed: "连接 Ollama 服务...")
            }
            do {
                try await ollamaProbe.pullModel(name: name, baseURL: project.llmConfig.ollamaBaseURL) { [weak self] progress, speed in
                    Task { @MainActor [weak self] in
                        self?.ollamaPullStates[name] = .downloading(progress: progress, speed: speed)
                    }
                }
                await probeLocalOllama()
                await MainActor.run {
                    self.ollamaPullStates[name] = .ready(localPath: "Ollama: \(name)", sizeDescription: "")
                    self.project.llmConfig.ollamaModel = name
                    self.statusMessage = "模型 \(name) 已成功下载至 Ollama 并设为当前模型"
                }
            } catch {
                await MainActor.run {
                    self.ollamaPullStates[name] = .failed(error.localizedDescription)
                    self.errorMessage = "Ollama 拉取模型失败: \(error.localizedDescription)"
                }
            }
        }
    }

    /// 取消所有正在执行的后台任务 (R03 & FU05)
    public func cancelAllTasks() {
        projectGeneration += 1
        editingTask?.cancel()
        editingTask = nil
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
        guard confirmReplacingProject() else { return }
        documentURL = nil
        saveStatus = "尚未保存"
        recoveryTask?.cancel()
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

        guard confirmReplacingProject() else { return }
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
        self.activeTranscriptionTask = Task {
            await withTaskCancellationHandler {
                _ = try? await worker.value
            } onCancel: { worker.cancel() }
        }

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
            statusMessage = "识别未完成: \(error.localizedDescription)"
            errorMessage = error.localizedDescription
        }
    }

    /// 执行字幕翻译 (R03, R07 & FU05: 任务防交叉、取消传递与脏状态标记)
    public func runTranslation() async {
        guard !project.subtitles.isEmpty else { return }

        translationTask?.cancel()
        activeTranslationTask?.cancel()
        let currentGen = projectGeneration

        project.isProcessing = true
        project.currentStepName = "正在启动模型 (\(project.llmConfig.effectiveModel))..."
        project.progress = 0.05

        let worker = Task { () -> Void in
            try await translator.translate(
                items: project.subtitles,
                config: project.llmConfig
            ) { [weak self] progress, status in
                Task { @MainActor [weak self] in
                    guard let self = self, self.projectGeneration == currentGen, !Task.isCancelled else { return }
                    self.project.progress = progress
                    self.project.currentStepName = status
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
            project.currentStepName = ""
            project.isDirty = true
            statusMessage = "翻译完成，已为 \(project.subtitles.count) 行字幕生成译文"
        } catch {
            guard currentGen == projectGeneration, !Task.isCancelled else { return }
            project.isProcessing = false
            project.currentStepName = ""
            if Task.isCancelled {
                statusMessage = "翻译已取消"
            } else {
                statusMessage = "翻译失败: \(error.localizedDescription)"
                errorMessage = "翻译失败: \(error.localizedDescription)"
            }
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
                do {
                    try await subtitleManager.reDub(item: item, ttsService: ttsService, voice: voice)
                } catch {
                    print("单句配音生成警告 [第\(idx + 1)句]: \(error)")
                }
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

    /// 确保所有含有译文（或原文）的字幕均具备有效的配音切片；缺失时即时自动合成补齐（供导出成片等场景使用，杜绝后半段失声）
    public func ensureAllSubtitlesDubbed(voice: String? = nil, onProgress: (@Sendable (Int, Int) -> Void)? = nil) async {
        let targetVoice = voice ?? project.llmConfig.targetLanguageVoiceCode
        let total = project.subtitles.count
        for (idx, item) in project.subtitles.enumerated() {
            let text = item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? item.originalText
                : item.translatedText
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let needsAudio = (item.dubbedAudioURL == nil) || !FileManager.default.fileExists(atPath: item.dubbedAudioURL!.path)
            if needsAudio {
                onProgress?(idx + 1, total)
                do {
                    try await subtitleManager.reDub(item: item, ttsService: ttsService, voice: targetVoice)
                } catch {
                    print("按需补齐配音警告 [第\(idx + 1)句]: \(error)")
                }
            }
        }
    }

    /// 试听目标类型
    public enum AuditionTarget {
        case original
        case translated
    }

    /// 试听单句音频 (支持原声片段与译文配音智能切换)
    /// - Parameters:
    ///   - item: 字幕项
    ///   - target: .original 播放原声片段；.translated 播放翻译配音
    public func auditionSubtitle(_ item: SubtitleItem, target: AuditionTarget = .original) async {
        // 1. 停止上一次未完成的试听播放及视频主播放器，避免混音杂糅
        self.player.pause()
        self.isPlaying = false
        self.auditionPlayer?.pause()
        self.auditionPlayer = nil

        if target == .translated && !item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 播放翻译后的配音语音 (TTS)
            do {
                item.isGeneratingAudio = true
                defer { item.isGeneratingAudio = false }
                let voice = project.llmConfig.targetLanguageVoiceCode
                if item.dubbedAudioURL == nil || !FileManager.default.fileExists(atPath: item.dubbedAudioURL!.path) {
                    try await subtitleManager.reDub(item: item, ttsService: ttsService, voice: voice)
                }
                if let audioURL = item.dubbedAudioURL {
                    let p = AVPlayer(url: audioURL)
                    self.auditionPlayer = p
                    p.play()
                    statusMessage = "正在试听译文配音: \(item.translatedText.prefix(25))..."
                }
            } catch {
                statusMessage = "试听生成失败: \(error.localizedDescription)"
            }
        } else {
            // 播放原声语音 (Rule 1 & Rule 3: 未选择或选择在原文时)
            guard let mediaURL = project.audioURL ?? project.videoURL else {
                statusMessage = "未找到可播放的原声音频素材"
                return
            }
            let playerItem = AVPlayerItem(url: mediaURL)
            playerItem.forwardPlaybackEndTime = item.endTime
            let p = AVPlayer(playerItem: playerItem)
            self.auditionPlayer = p
            await p.seek(to: item.startTime, toleranceBefore: .zero, toleranceAfter: .zero)
            p.play()
            self.seek(to: item.startTime)
            statusMessage = "正在试听原声: [\(item.startTime.displayFormat) ➔ \(item.endTime.displayFormat)] \(item.originalText.prefix(25))..."
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
        lastTextEditID = nil
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

    /// 校验是否选中了 2 行及以上且位置连续的字幕行
    public func canMergeMultipleConsecutive(ids: Set<UUID>) -> Bool {
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

    /// 校验是否满足合并条件：多选需连续；单选或聚焦需存在下一行
    public func canMerge(ids: Set<UUID>) -> Bool {
        if ids.count >= 2 {
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
        } else if let singleID = ids.first ?? project.selectedSubtitleID {
            if let index = project.subtitles.firstIndex(where: { $0.id == singleID }),
               index + 1 < project.subtitles.count {
                return true
            }
        }
        return false
    }

    /// 删除指定字幕行
    public func deleteSubtitle(id: UUID) {
        guard let index = project.subtitles.firstIndex(where: { $0.id == id }) else { return }
        recordUndoSnapshot()
        project.subtitles.remove(at: index)
        project.isDirty = true
        statusMessage = "已删除该行字幕"
    }

    /// 将指定字幕与下一行字幕直接合并
    public func mergeSubtitleWithNext(id: UUID) {
        guard let index = project.subtitles.firstIndex(where: { $0.id == id }),
              index + 1 < project.subtitles.count else {
            statusMessage = "已经是最后一行，无法向下合并"
            return
        }
        let nextID = project.subtitles[index + 1].id
        mergeSubtitles(ids: [id, nextID])
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
            if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
                let textStr = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
                let itemStr = item.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
                if textStr == itemStr || textView.string == item.originalText {
                    let loc = textView.selectedRange().location
                    if loc != NSNotFound, let offset = SubtitleManager.characterOffset(in: item.originalText, utf16Offset: loc), offset > 0 && offset < item.originalText.count {
                        charIndex = offset
                    }
                }
            }
        }

        var targetIndex = charIndex
        if targetIndex == nil || targetIndex! <= 0 || targetIndex! >= item.originalText.count {
            // 智能兜底：若用户未放置光标，在句子中间寻找最自然的标点/空格断句点
            let chars = Array(item.originalText)
            let mid = chars.count / 2
            var bestBreak: Int? = nil
            var minDiff = Int.max
            for (idx, ch) in chars.enumerated() {
                guard idx > 0 && idx < chars.count - 1 else { continue }
                if "，,。!?.!?；; ".contains(ch) {
                    let diff = abs(idx - mid)
                    if diff < minDiff {
                        minDiff = diff
                        bestBreak = idx + 1 // 断在标点/空格之后
                    }
                }
            }
            targetIndex = bestBreak ?? (mid > 0 ? mid : nil)
        }

        guard let finalIndex = targetIndex, finalIndex > 0, finalIndex < item.originalText.count else {
            errorMessage = "请先在文本框中将光标放置在想要拆分的字词之间"
            statusMessage = "拆分提示：请先在字幕文本中放置光标"
            NSSound.beep()
            return
        }

        splitSubtitle(id: selectedID, atCharIndex: finalIndex)
    }

    /// 执行大模型语义智能分句规整 (将每个词的精确定位发给大模型重构断句时间轴)
    public func runSmartSegmentation() async {
        guard !project.subtitles.isEmpty, !project.isProcessing else { return }
        guard !project.subtitles.contains(where: { !$0.translatedText.isEmpty }) else {
            errorMessage = "为保护已有译文，请在翻译前执行智能分句；已有译文可用行内拆分与合并调整。"
            return
        }
        let snapshot = createSubtitlesSnapshot()
        let tokens = snapshot.flatMap { item in
            item.words.isEmpty ? [WordToken(text: item.originalText, startTime: item.startTime, endTime: item.endTime)] : item.words
        }
        let config = project.llmConfig
        await runEditingJob(name: "智能分句", snapshot: snapshot) {
            try await self.llmSegmenter.segment(tokens: tokens, config: config)
        }
    }

    public func matchTimelineToTranslation() async {
        guard !project.subtitles.isEmpty, !project.isProcessing else { return }
        guard project.subtitles.contains(where: { !$0.translatedText.isEmpty }) else {
            errorMessage = "请先翻译字幕，再匹配译文时间轴"
            return
        }
        let snapshot = createSubtitlesSnapshot()
        let config = project.llmConfig
        let duration = try? await player.currentItem?.asset.load(.duration)
        let client = OpenAICompatibleClient(baseURL: config.effectiveBaseURL, apiKey: config.effectiveAPIKey)
        await runEditingJob(name: "匹配译文时间轴", snapshot: snapshot) {
            await self.timelineAligner.matchTimelineWithLLM(items: snapshot, config: config, client: client, videoDuration: duration?.secondsValue)
        }
    }

    /// All automatic editing uses the same ownership and cancellation boundary.
    public func runEditingJob(name: String, snapshot: [SubtitleItem], operation: @escaping @MainActor () async throws -> [SubtitleItem]) async {
        let generation = projectGeneration
        project.isProcessing = true
        project.currentStepName = name
        let worker = Task { try await operation() }
        editingTask = worker
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            guard generation == projectGeneration, !worker.isCancelled, !Task.isCancelled else { return }
            guard createSubtitlesSnapshot() == snapshot else {
                throw LLMError.parsingFailed("字幕已修改，请重新生成建议")
            }
            guard !result.isEmpty else { throw LLMError.parsingFailed("未生成有效字幕，原有内容已保留") }
            recordUndoSnapshot()
            project.subtitles = result
            project.isDirty = true
            project.isProcessing = false
            project.progress = 1
            statusMessage = "\(name)已完成，可撤销；请试听确认"
        } catch {
            guard generation == projectGeneration else { return }
            project.isProcessing = false
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            statusMessage = "\(name)未应用，原有字幕已保留"
        }
        if generation == projectGeneration { editingTask = nil }
    }

    /// 保持兼容
    public func realignTimelineForTranslationPacing() async {
        await matchTimelineToTranslation()
    }

    /// 合并选中的字幕 (Cmd+J) (支持多选相邻合并，或单选/当前行向下合并)
    public func mergeSubtitles(ids: Set<UUID>) {
        var targetIDs = ids
        if targetIDs.count < 2 {
            let baseID = targetIDs.first ?? project.selectedSubtitleID
            if let base = baseID,
               let index = project.subtitles.firstIndex(where: { $0.id == base }),
               index + 1 < project.subtitles.count {
                targetIDs = [base, project.subtitles[index + 1].id]
            } else {
                errorMessage = "请先选中至少两行相邻字幕，或选中一行向下合并"
                statusMessage = "合并提示：请选择需合并的字幕行"
                return
            }
        }

        // 获取被选中的索引并排序
        let indices = project.subtitles.enumerated()
            .filter { targetIDs.contains($1.id) }
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
            project.subtitles.removeAll(where: { targetIDs.contains($0.id) })
            project.subtitles.insert(merged, at: firstIndex)
            project.selectedSubtitleID = merged.id
            project.isDirty = true
            statusMessage = "已合并 \(selectedItems.count) 条字幕"
        }
    }

    // MARK: - 工程持久化与存取 (R04)

    public func saveProject(to url: URL) throws {
        try ProjectStore.write(documentData: project.encodeDocument(), to: url)
        recoveryTask?.cancel()
        recoveryWrite?.cancel()
        ProjectStore.removeCheckpoint(at: recoveryURL)
        recoveryAvailable = false
        documentURL = url
        project.isDirty = false
        saveStatus = "已保存"
        statusMessage = "工程已保存：\(url.lastPathComponent)"
    }

    @discardableResult public func saveProjectInteractively(chooseNewURL: Bool = false) -> Bool {
        var destination = chooseNewURL ? nil : documentURL
        if destination == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "字幕工程.vatproject"
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            destination = url
        }
        do { try saveProject(to: destination!); return true }
        catch { saveStatus = "保存失败"; errorMessage = error.localizedDescription; return false }
    }

    public func confirmReplacingProject() -> Bool {
        guard persistsRecovery, project.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "是否保存当前工程的修改？"
        alert.informativeText = "保存工程可在下次继续校对；导出字幕不能替代工程保存。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "放弃修改")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveProjectInteractively()
        case .alertThirdButtonReturn:
            recoveryTask?.cancel()
            recoveryWrite?.cancel()
            ProjectStore.removeCheckpoint(at: recoveryURL)
            return true
        default: return false
        }
    }

    public func openProjectInteractively() {
        guard confirmReplacingProject() else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try loadProject(from: url) } catch { errorMessage = "无法打开工程：\(error.localizedDescription)" }
    }

    public func loadProject(from url: URL) throws {
        let doc = try ProjectStore.read(from: url)
        recoveryTask?.cancel()
        cancelAllTasks()
        undoStack.removeAll()
        redoStack.removeAll()
        canUndo = false
        canRedo = false
        lastTextEditID = nil
        project.reset()
        project.restore(from: doc)
        project.audioURL = project.videoURL // Original-quality audio remains available after reopening.
        documentURL = url
        saveStatus = "已保存"
        if let video = project.videoURL {
            if FileManager.default.fileExists(atPath: video.path) {
                player.replaceCurrentItem(with: AVPlayerItem(url: video))
            } else { errorMessage = "工程已打开，但原视频已移动。请使用「重新定位媒体」选择原文件。" }
        }
        statusMessage = "已加载工程：\(url.lastPathComponent)"
    }

    public func relinkMedia() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        project.videoURL = url
        project.audioURL = url
        project.isDirty = true
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        scheduleRecovery()
    }

    public func scheduleRecovery() {
        guard persistsRecovery else { return }
        recoveryTask?.cancel()
        recoveryWrite?.cancel()
        recoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 700_000_000)
                guard let self = self, self.project.isDirty else { return }
                let data = try self.project.encodeDocument()
                let target = self.recoveryURL
                self.saveStatus = "正在保存恢复副本…"
                let write = Task.detached {
                    try Task.checkCancellation()
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try ProjectStore.write(documentData: data, to: target)
                }
                self.recoveryWrite = write
                try await write.value
                if !Task.isCancelled { self.saveStatus = "恢复副本已保存；工程有修改" }
            } catch is CancellationError { }
            catch { self?.saveStatus = "恢复副本保存失败，请手动保存" }
        }
    }

    public func restoreRecovery() {
        do {
            try loadProject(from: recoveryURL)
            documentURL = nil
            project.isDirty = true
            recoveryAvailable = false
            statusMessage = "已恢复上次未保存的编辑，请保存工程"
        } catch { errorMessage = "恢复失败：\(error.localizedDescription)" }
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
        // 先中止先前的下载准备任务（若有）
        downloadTasks[preset.id]?.cancel()

        // 第一时间在主线程将状态置为 0% downloading，界面上的“立即下载”按钮在点击瞬间立即切换为“取消”和 0% 进度条
        modelStorageManager.modelStates[preset.id] = .downloading(progress: 0.0, speed: "正在准备下载环境...")

        downloadTasks[preset.id] = Task {
            if Task.isCancelled { return }

            if preset.isRepo {
                // 确保 ASR 服务在线就绪（若未启动或已断开，自动唤醒并等待健康就绪）
                let isReady = await sidecarManager.ensureRunning()
                if Task.isCancelled { return }

                guard isReady else {
                    await MainActor.run {
                        if Task.isCancelled { return }
                        let reason: String
                        if case .error(let msg) = self.sidecarManager.status {
                            reason = msg
                        } else {
                            reason = "本地 ASR 引擎未能成功启动，请检查 Python 依赖"
                        }
                        self.modelStorageManager.modelStates[preset.id] = .failed(reason)
                        self.errorMessage = reason
                        self.statusMessage = "ASR 引擎启动失败"
                    }
                    return
                }

                await MainActor.run {
                    if Task.isCancelled { return }
                    self.modelStorageManager.modelStates[preset.id] = .downloading(progress: 0.0, speed: "正在连接下载镜像源...")
                }

                if Task.isCancelled { return }

                do {
                    try await modelStorageManager.triggerServerRepoDownload(preset: preset)
                } catch {
                    await MainActor.run {
                        if Task.isCancelled { return }
                        self.modelStorageManager.modelStates[preset.id] = .failed("连接服务失败: \(error.localizedDescription)")
                        self.errorMessage = "启动模型下载失败: \(error.localizedDescription)"
                        self.statusMessage = "模型下载启动失败"
                    }
                }
            } else {
                if Task.isCancelled { return }
                modelStorageManager.startDirectDownload(for: preset)
            }
        }
    }

    /// 取消指定模型的下载任务，立即切回“立即下载”
    public func cancelDownload(preset: ASRModelPreset) {
        downloadTasks[preset.id]?.cancel()
        downloadTasks.removeValue(forKey: preset.id)
        modelStorageManager.cancelDownload(for: preset.id)
    }
}
