import Foundation
import SwiftUI
import AVFoundation
import AppKit
import VideoAutoTranslateCore

@MainActor
public final class AppState: ObservableObject {
    @Published public var project: ProjectState = ProjectState()
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
    @Published public var modelStorageManager = ModelStorageManager()
    @Published public var sidecarManager = ASRSidecarManager.shared

    // 设置与探测
    @Published public var availableOllamaModels: [String] = []
    @Published public var isASRServerOnline: Bool = false
    @Published public var showSettings: Bool = false
    @Published public var showExportSheet: Bool = false
    @Published public var statusMessage: String = "就绪"

    private var timeObserverToken: Any?

    public init() {
        setupTimeObserver()
        Task {
            await sidecarManager.probeExistingStatus()
            await probeLocalOllama()
            await probeLocalASR()
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

    /// 自动根据时间选中高亮当前发音字幕
    private func updateSelectedSubtitle(for time: CMTime) {
        if let current = project.subtitles.first(where: { time >= $0.startTime && time <= $0.endTime }) {
            if project.selectedSubtitleID != current.id {
                project.selectedSubtitleID = current.id
            }
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

    /// 打开本地视频文件
    public func openVideo(url: URL) {
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

    /// 一键执行：本地音频提取与 Qwen 语音识别
    public func runTranscription() async {
        guard let videoURL = project.videoURL else { return }

        project.isProcessing = true
        project.currentStepName = "正在提取音频..."
        project.progress = 0.1

        do {
            let tempDir = FileManager.default.temporaryDirectory
            let wavURL = tempDir.appendingPathComponent("extracted_\(UUID().uuidString).wav")
            try await audioExtractor.extract16kMonoWav(from: videoURL, to: wavURL)
            project.audioURL = wavURL

            project.currentStepName = "正在按需准备本地 ASR 推理引擎..."
            project.progress = 0.25
            _ = await sidecarManager.ensureRunning()
            await probeLocalASR()

            project.currentStepName = "正在调用 Qwen3-ASR 执行转录与词级对齐..."
            project.progress = 0.4

            let asrService = LocalASRService(config: project.asrConfig)
            let items = try await asrService.transcribe(audioURL: wavURL) { progress in
                Task { @MainActor in
                    self.project.progress = 0.4 + progress * 0.5
                }
            }

            project.subtitles = items
            project.isProcessing = false
            project.progress = 1.0
            statusMessage = "识别完成，共生成 \(items.count) 行字幕"
        } catch {
            project.isProcessing = false
            statusMessage = "识别失败: \(error.localizedDescription)"
        }
    }

    /// 一键执行：Qwen/LLM 智能翻译
    public func runTranslation() async {
        guard !project.subtitles.isEmpty else { return }

        project.isProcessing = true
        project.currentStepName = "正在使用 \(project.llmConfig.effectiveModel) 翻译字幕..."
        project.progress = 0.0

        do {
            try await translator.translate(
                items: project.subtitles,
                config: project.llmConfig
            ) { progress in
                Task { @MainActor in
                    self.project.progress = progress
                }
            }
            project.isProcessing = false
            statusMessage = "翻译完成，已为 \(project.subtitles.count) 行字幕生成译文"
        } catch {
            project.isProcessing = false
            statusMessage = "翻译失败: \(error.localizedDescription)"
        }
    }

    /// 一键执行：多语言自动配音与混音
    public func runFullDubbing() async {
        guard !project.subtitles.isEmpty else { return }

        project.isProcessing = true
        project.currentStepName = "正在合成新语言配音片段..."
        project.progress = 0.0

        do {
            let total = Double(project.subtitles.count)
            for (idx, item) in project.subtitles.enumerated() {
                try await subtitleManager.reDub(item: item, ttsService: ttsService)
                project.progress = Double(idx + 1) / total
            }

            project.currentStepName = "正在执行音频无损伸缩与闪避混音..."
            let tempDir = FileManager.default.temporaryDirectory
            let mixedAudioURL = tempDir.appendingPathComponent("mixed_dubbed_\(UUID().uuidString).m4a")

            try await audioMixer.mix(
                backgroundAudioURL: project.audioURL,
                subtitles: project.subtitles,
                to: mixedAudioURL
            )

            project.isProcessing = false
            statusMessage = "配音合成完成！可导出新视频"
        } catch {
            project.isProcessing = false
            statusMessage = "配音生成失败: \(error.localizedDescription)"
        }
    }

    /// 试听单句配音音频
    public func auditionSubtitle(_ item: SubtitleItem) async {
        do {
            if item.dubbedAudioURL == nil || !FileManager.default.fileExists(atPath: item.dubbedAudioURL!.path) {
                try await subtitleManager.reDub(item: item, ttsService: ttsService)
            }
            if let audioURL = item.dubbedAudioURL {
                let tempPlayer = AVPlayer(url: audioURL)
                tempPlayer.play()
            }
        } catch {
            statusMessage = "试听生成失败: \(error.localizedDescription)"
        }
    }

    /// 拆分字幕 (Cmd+B)
    public func splitCurrentSubtitle(atCharIndex: Int) {
        guard let selectedID = project.selectedSubtitleID,
              let index = project.subtitles.firstIndex(where: { $0.id == selectedID }) else {
            return
        }
        let target = project.subtitles[index]
        if let (part1, part2) = subtitleManager.split(item: target, atCharIndex: atCharIndex) {
            project.subtitles.remove(at: index)
            project.subtitles.insert(part2, at: index)
            project.subtitles.insert(part1, at: index)
            project.selectedSubtitleID = part1.id
            statusMessage = "已成功拆分字幕"
        }
    }

    /// 合并选中的字幕 (Cmd+J)
    public func mergeSubtitles(ids: Set<UUID>) {
        let selectedItems = project.subtitles.filter { ids.contains($0.id) }
        guard selectedItems.count >= 2 else { return }

        if let merged = subtitleManager.merge(items: selectedItems) {
            let firstIndex = project.subtitles.firstIndex(where: { ids.contains($0.id) }) ?? 0
            project.subtitles.removeAll(where: { ids.contains($0.id) })
            project.subtitles.insert(merged, at: firstIndex)
            project.selectedSubtitleID = merged.id
            statusMessage = "已合并 \(selectedItems.count) 条字幕"
        }
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

    /// 触发指定模型的下载
    public func downloadModel(preset: ASRModelPreset) {
        if preset.isRepo {
            Task {
                try? await modelStorageManager.triggerServerRepoDownload(preset: preset)
            }
        } else {
            modelStorageManager.startDirectDownload(for: preset)
        }
    }
}
