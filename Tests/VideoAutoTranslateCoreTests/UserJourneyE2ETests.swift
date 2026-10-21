import XCTest
import CoreMedia
import AVFoundation
@testable import VideoAutoTranslateCore

/// 模拟用户在应用中的交互会话（覆盖用户界面的核心操作与生命周期）
final class UserJourneySimulator {
    var project = ProjectState()
    var undoStack: [[SubtitleItem]] = []
    var redoStack: [[SubtitleItem]] = []

    let subtitleManager = SubtitleManager()
    let timelineAligner = TimelineAligner()
    let srtExporter = SRTExporter()
    let ttsService = SystemTTSService()

    /// 步骤 1: 用户打开视频文件
    func openVideo(url: URL) {
        project.reset()
        project.videoURL = url
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// 步骤 2: 用户探测本地 ASR 语音识别服务在线状态
    func probeASRServer() async -> Bool {
        let (online, _) = await LocalASRService.testConnection(urlString: project.asrConfig.serviceURL)
        return online
    }

    /// 记录撤销快照 (支持 Cmd+Z)
    private func recordUndoSnapshot() {
        let snapshot = project.subtitles.map { item in
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
        undoStack.append(snapshot)
        redoStack.removeAll()
    }

    /// 用户在界面上按下 Cmd+Z 撤销
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        let current = project.subtitles.map { item in
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
        redoStack.append(current)
        project.subtitles = previous
    }

    /// 用户在界面上按下 Cmd+Shift+Z 重做
    func redo() {
        guard let next = redoStack.popLast() else { return }
        let current = project.subtitles.map { item in
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
        undoStack.append(current)
        project.subtitles = next
    }

    /// 步骤 3.1: 用户选中某字幕行并在指定字符处触发拆分 (Cmd+B)
    func splitSubtitle(id: UUID, atCharIndex charIndex: Int) {
        guard let index = project.subtitles.firstIndex(where: { $0.id == id }) else { return }
        let target = project.subtitles[index]
        if let (part1, part2) = subtitleManager.split(item: target, atCharIndex: charIndex) {
            recordUndoSnapshot()
            project.subtitles.remove(at: index)
            project.subtitles.insert(part2, at: index)
            project.subtitles.insert(part1, at: index)
            project.selectedSubtitleID = part1.id
        }
    }

    /// 步骤 3.4: 用户多选字幕并点击合并 (Cmd+J)
    func mergeSubtitles(ids: Set<UUID>) {
        let targets = project.subtitles.filter { ids.contains($0.id) }
        guard targets.count >= 2 else { return }
        guard let merged = subtitleManager.merge(items: targets) else { return }
        recordUndoSnapshot()
        let firstIndex = project.subtitles.firstIndex(where: { ids.contains($0.id) })!
        project.subtitles.removeAll(where: { ids.contains($0.id) })
        project.subtitles.insert(merged, at: firstIndex)
        project.selectedSubtitleID = merged.id
    }

    /// 步骤 5: 用户点击「匹配译文时间轴」（保持原文译文一一对应，根据译文发音时长重排时间轴）
    func matchTimelineToTranslation() async {
        guard !project.subtitles.isEmpty else { return }
        recordUndoSnapshot()
        let client = OpenAICompatibleClient(baseURL: project.llmConfig.effectiveBaseURL, apiKey: project.llmConfig.effectiveAPIKey)
        let realigned = await timelineAligner.matchTimelineWithLLM(
            items: project.subtitles,
            config: project.llmConfig,
            client: client
        )
        project.subtitles = realigned
        for item in project.subtitles {
            item.dubbedAudioURL = nil
        }
    }

    /// 步骤 6: 用户点击单句试听 (TTS 语音合成)
    func auditionSubtitle(item: SubtitleItem, outputURL: URL) async throws -> URL {
        let voice = "zh-CN"
        return try await ttsService.synthesize(text: item.translatedText, voice: voice, outputURL: outputURL)
    }

    /// 步骤 7: 用户导出双语字幕文件
    func exportBilingualSRT(to url: URL) throws -> String {
        let content = srtExporter.exportSRT(items: project.subtitles, mode: .bilingual)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return content
    }
}

final class UserJourneyE2ETests: XCTestCase {
    var session: UserJourneySimulator!

    override func setUp() async throws {
        try await super.setUp()
        session = UserJourneySimulator()
    }

    override func tearDown() async throws {
        session = nil
        try await super.tearDown()
    }

    /// 动态生成轻量有效测试视频，确保在无外部视频大文件的 CI 环境中也能独立完成 AVAsset 全链路测试
    private static func createMockTestVideo(at url: URL, durationSeconds: Double = 6.0) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 240
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 240
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        if let buffer = pixelBuffer {
            adaptor.append(buffer, withPresentationTime: .zero)
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: durationSeconds, preferredTimescale: 600))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    /// 用户核心使用旅程端到端全链路测试
    func testFullUserJourneyFromImportToExport() async throws {
        print("====== [User Journey E2E] 开始全链路用户视角测试 ======")

        // -------------------------------------------------------------
        // 步骤 1: 用户打开视频文件
        // -------------------------------------------------------------
        print("--> 步骤 1: 用户打开待翻译视频...")
        let localPath = "/Users/zfdang/workspaces/video-auto-translate/Tests/Fme9C5ShSr2fuWQ8_Translated.mp4"
        let activeVideoURL: URL
        if FileManager.default.fileExists(atPath: localPath) {
            activeVideoURL = URL(fileURLWithPath: localPath)
        } else {
            let tempVideoURL = FileManager.default.temporaryDirectory.appendingPathComponent("e2e_ci_video_\(UUID().uuidString).mp4")
            try await Self.createMockTestVideo(at: tempVideoURL, durationSeconds: 6.0)
            activeVideoURL = tempVideoURL
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: activeVideoURL.path), "测试视频文件必须存在")
        session.openVideo(url: activeVideoURL)
        XCTAssertEqual(session.project.videoURL, activeVideoURL)

        // 校验视频时长是否能够被 AVAsset 读取
        let asset = AVURLAsset(url: activeVideoURL)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 5.0, "视频实际时长应当大于 5 秒")
        print("  ✓ 视频载入成功，总时长: \(String(format: "%.2f", duration.seconds)) 秒")

        // -------------------------------------------------------------
        // 步骤 2: 用户点击「语音识别/语音转录」
        // -------------------------------------------------------------
        print("--> 步骤 2: 用户点击「语音转录」按钮...")
        let isASROnline = await session.probeASRServer()
        print("  ✓ 本地 ASR 服务状态: \(isASROnline ? "在线 (127.0.0.1:8765)" : "离线")")

        // 构造代表真实 ASR 识别出的标准语音与字词序列 (含精准物理时间戳)
        let sampleItems = [
            SubtitleItem(
                startTime: .from(seconds: 0.16),
                endTime: .from(seconds: 0.40),
                originalText: "Bonjour",
                words: [WordToken(text: "Bonjour", startTime: .from(seconds: 0.16), endTime: .from(seconds: 0.40))]
            ),
            SubtitleItem(
                startTime: .from(seconds: 1.28),
                endTime: .from(seconds: 2.80),
                originalText: "Bonjour, yes, yes. You are for the tour, Très bien.",
                words: [
                    WordToken(text: "Bonjour", startTime: .from(seconds: 1.28), endTime: .from(seconds: 1.50)),
                    WordToken(text: "yes", startTime: .from(seconds: 1.52), endTime: .from(seconds: 1.70)),
                    WordToken(text: "yes", startTime: .from(seconds: 1.72), endTime: .from(seconds: 1.90)),
                    WordToken(text: "you", startTime: .from(seconds: 1.95), endTime: .from(seconds: 2.10)),
                    WordToken(text: "are", startTime: .from(seconds: 2.12), endTime: .from(seconds: 2.22)),
                    WordToken(text: "for", startTime: .from(seconds: 2.24), endTime: .from(seconds: 2.34)),
                    WordToken(text: "the", startTime: .from(seconds: 2.36), endTime: .from(seconds: 2.45)),
                    WordToken(text: "tour", startTime: .from(seconds: 2.47), endTime: .from(seconds: 2.60)),
                    WordToken(text: "Très", startTime: .from(seconds: 2.62), endTime: .from(seconds: 2.70)),
                    WordToken(text: "bien", startTime: .from(seconds: 2.72), endTime: .from(seconds: 2.80))
                ]
            ),
            SubtitleItem(
                startTime: .from(seconds: 3.12),
                endTime: .from(seconds: 4.80),
                originalText: "Welcome mes amis Welcome to Paris City Tours",
                words: [
                    WordToken(text: "Welcome", startTime: .from(seconds: 3.12), endTime: .from(seconds: 3.40)),
                    WordToken(text: "mes", startTime: .from(seconds: 3.42), endTime: .from(seconds: 3.60)),
                    WordToken(text: "amis", startTime: .from(seconds: 3.62), endTime: .from(seconds: 3.80)),
                    WordToken(text: "Welcome", startTime: .from(seconds: 3.85), endTime: .from(seconds: 4.20)),
                    WordToken(text: "to", startTime: .from(seconds: 4.22), endTime: .from(seconds: 4.35)),
                    WordToken(text: "Paris", startTime: .from(seconds: 4.38), endTime: .from(seconds: 4.55)),
                    WordToken(text: "City", startTime: .from(seconds: 4.58), endTime: .from(seconds: 4.68)),
                    WordToken(text: "Tours", startTime: .from(seconds: 4.70), endTime: .from(seconds: 4.80))
                ]
            ),
            SubtitleItem(
                startTime: .from(seconds: 5.00),
                endTime: .from(seconds: 6.80),
                originalText: "Today I show you the real Paris Follow me",
                words: [
                    WordToken(text: "Today", startTime: .from(seconds: 5.00), endTime: .from(seconds: 5.30)),
                    WordToken(text: "I", startTime: .from(seconds: 5.32), endTime: .from(seconds: 5.45)),
                    WordToken(text: "show", startTime: .from(seconds: 5.48), endTime: .from(seconds: 5.70)),
                    WordToken(text: "you", startTime: .from(seconds: 5.72), endTime: .from(seconds: 5.85)),
                    WordToken(text: "the", startTime: .from(seconds: 5.88), endTime: .from(seconds: 6.00)),
                    WordToken(text: "real", startTime: .from(seconds: 6.02), endTime: .from(seconds: 6.25)),
                    WordToken(text: "Paris", startTime: .from(seconds: 6.28), endTime: .from(seconds: 6.45)),
                    WordToken(text: "Follow", startTime: .from(seconds: 6.48), endTime: .from(seconds: 6.65)),
                    WordToken(text: "me", startTime: .from(seconds: 6.68), endTime: .from(seconds: 6.80))
                ]
            )
        ]
        session.project.subtitles = sampleItems
        session.project.selectedSubtitleID = sampleItems[1].id
        XCTAssertEqual(session.project.subtitles.count, 4)
        print("  ✓ 语音识别字幕已填充，共 \(session.project.subtitles.count) 行字幕")

        // -------------------------------------------------------------
        // 步骤 3: 用户对字幕进行交互微调（拆分、合并、撤销、重做）
        // -------------------------------------------------------------
        print("--> 步骤 3: 用户交互式微调字幕...")

        // 3.1 用户测试「拆分」：把第 2 行在 "You" 前面拆开
        let targetRow = session.project.subtitles[1]
        let youCharIndex = targetRow.originalText.distance(
            from: targetRow.originalText.startIndex,
            to: targetRow.originalText.range(of: "You")!.lowerBound
        )
        print("  3.1 用户在第 2 行 'You' 前面 (字符索引 \(youCharIndex)) 触发拆分...")
        session.splitSubtitle(id: targetRow.id, atCharIndex: youCharIndex)

        // 验证拆分结果：从 4 行变为 5 行，且拆开的两行文字与标点完美对齐
        XCTAssertEqual(session.project.subtitles.count, 5, "拆分后总行数应为 5")
        XCTAssertEqual(session.project.subtitles[1].originalText, "Bonjour, yes, yes.")
        XCTAssertEqual(session.project.subtitles[2].originalText, "You are for the tour, Très bien.")
        print("    ✓ 拆分成功！前半句: \(session.project.subtitles[1].originalText)，后半句: \(session.project.subtitles[2].originalText)")

        // 3.2 用户测试「撤销 Undo (Cmd+Z)」
        print("  3.2 用户按下 Cmd+Z 撤销刚才的拆分...")
        session.undo()
        XCTAssertEqual(session.project.subtitles.count, 4, "撤销后行数应恢复为 4")
        XCTAssertEqual(session.project.subtitles[1].originalText, targetRow.originalText)
        print("    ✓ 撤销成功，恢复为 4 行")

        // 3.3 用户测试「重做 Redo (Cmd+Shift+Z)」
        print("  3.3 用户按下 Cmd+Shift+Z 重做拆分...")
        session.redo()
        XCTAssertEqual(session.project.subtitles.count, 5, "重做后行数应重新为 5")
        print("    ✓ 重做成功，重新切分为 5 行")

        // 3.4 用户测试「向下合并 (Cmd+J)」：将第 4 行与第 5 行合并
        let mergeID1 = session.project.subtitles[3].id
        let mergeID2 = session.project.subtitles[4].id
        print("  3.4 用户选中第 4 行与第 5 行，触发合并...")
        session.mergeSubtitles(ids: [mergeID1, mergeID2])
        XCTAssertEqual(session.project.subtitles.count, 4, "合并后行数应缩减为 4")
        print("    ✓ 合并成功，合并后末行文本: \(session.project.subtitles.last!.originalText)")

        // -------------------------------------------------------------
        // 步骤 4: 用户进行「字幕翻译」
        // -------------------------------------------------------------
        print("--> 步骤 4: 用户配置中文并执行「字幕翻译」...")
        session.project.llmConfig.targetLanguage = "中文 (简体)"

        // 模拟各行地道影视翻译
        session.project.subtitles[0].translatedText = "你好"
        session.project.subtitles[1].translatedText = "是的是的"
        session.project.subtitles[2].translatedText = "你们是来参加这次观光游的，太好了"
        session.project.subtitles[3].translatedText = "欢迎各位朋友参加巴黎城市之旅，今天我要带你们看看真正的巴黎，跟我来吧"

        for (idx, item) in session.project.subtitles.enumerated() {
            print("  [\(idx + 1)] 原文: \(item.originalText) -> 译文: \(item.translatedText)")
        }
        print("  ✓ 双语字幕翻译就绪")

        // -------------------------------------------------------------
        // 步骤 5: 用户点击「匹配译文时间轴」
        // -------------------------------------------------------------
        print("--> 步骤 5: 用户点击「匹配译文时间轴」（跟译文期望发音时间做匹配，原文译文一一对应不变）...")
        let beforeOriginals = session.project.subtitles.map { $0.originalText }
        let beforeTranslations = session.project.subtitles.map { $0.translatedText }
        let beforeRates = session.project.subtitles.map { Double($0.translatedText.count) / $0.durationSeconds }
        print("  匹配前各行语速（与原声绑定）: \(beforeRates.map { String(format: "%.1f字/s", $0) })")

        await session.matchTimelineToTranslation()

        // 1. 验证原文与译文 1:1 严格对应关系绝对未变
        XCTAssertEqual(session.project.subtitles.map { $0.originalText }, beforeOriginals, "原文内容与顺序保持完全一致")
        XCTAssertEqual(session.project.subtitles.map { $0.translatedText }, beforeTranslations, "译文内容与顺序保持完全一致")

        let afterRates = session.project.subtitles.map { Double($0.translatedText.count) / $0.durationSeconds }
        print("  匹配后各行语速（契合译文自然发音）: \(afterRates.map { String(format: "%.1f字/s", $0) })")

        // 2. 验证语速已自然稳定收敛在舒适区间 (1.5 ~ 5.0 字/秒)，消除忽快忽慢
        for rate in afterRates {
            XCTAssertLessThanOrEqual(rate, 5.0, "匹配后语速不应出现急促冲刺 (>5.0字/s)")
            XCTAssertGreaterThanOrEqual(rate, 1.5, "匹配后语速不应出现过于拖沓 (<1.5字/s)")
        }

        // 3. 验证时间轴无重叠交叉
        for i in 1..<session.project.subtitles.count {
            XCTAssertGreaterThanOrEqual(
                session.project.subtitles[i].startTime.secondsValue,
                session.project.subtitles[i - 1].endTime.secondsValue,
                "匹配后各行字幕时间轴绝不能重叠"
            )
        }
        print("  ✓ 译文时间轴匹配成功：原文译文对应保持不变，时间轴与译文语音时长完全吻合！")

        // -------------------------------------------------------------
        // 步骤 6: 用户单句试听与测试配音合成
        // -------------------------------------------------------------
        print("--> 步骤 6: 用户测试单句试听与配音合成...")
        let firstItem = session.project.subtitles[0]
        let tempDir = FileManager.default.temporaryDirectory
        let auditionURL = tempDir.appendingPathComponent("e2e_audition_\(UUID().uuidString).wav")

        let generatedAudio = try await session.auditionSubtitle(item: firstItem, outputURL: auditionURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: generatedAudio.path), "单句试听音频应当成功生成")
        print("  ✓ 单句试听配音生成成功 (\(generatedAudio.lastPathComponent))")

        // -------------------------------------------------------------
        // 步骤 7: 用户导出成品（双语字幕 SRT 与成片校验）
        // -------------------------------------------------------------
        print("--> 步骤 7: 用户测试导出最终成品...")
        let exportedSRTURL = tempDir.appendingPathComponent("e2e_export_\(UUID().uuidString).srt")

        let srtContent = try session.exportBilingualSRT(to: exportedSRTURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedSRTURL.path), "导出的 SRT 文件必须存在")
        XCTAssertTrue(srtContent.contains("Bonjour"), "SRT 必须包含原文")
        XCTAssertTrue(srtContent.contains("你好"), "SRT 必须包含译文")
        print("  ✓ 双语 SRT 字幕导出校验成功")

        print("====== [User Journey E2E] 测试全部圆满通过！ ======")
    }
}
