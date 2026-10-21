import XCTest
import CoreMedia
@testable import VideoAutoTranslateCore

final class VideoAutoTranslateCoreTests: XCTestCase {

    func testCMTimeFormatting() {
        let time = CMTime(value: 65432, timescale: 1000) // 65.432s = 01:05.432
        XCTAssertEqual(time.srtFormat, "00:01:05,432")
        XCTAssertEqual(time.vttFormat, "00:01:05.432")
        XCTAssertEqual(time.displayFormat, "01:05.43")
    }

    func testSubtitleItemSplitting() {
        let manager = SubtitleManager()

        let word1 = WordToken(text: "Hello", startTime: CMTime.from(seconds: 0.0), endTime: CMTime.from(seconds: 0.5))
        let word2 = WordToken(text: "World", startTime: CMTime.from(seconds: 0.6), endTime: CMTime.from(seconds: 1.2))

        let item = SubtitleItem(
            startTime: CMTime.from(seconds: 0.0),
            endTime: CMTime.from(seconds: 1.2),
            originalText: "Hello World",
            words: [word1, word2]
        )

        // 在 "Hello" 与 "World" 之间切分 (charIndex 5)
        let splitResult = manager.split(item: item, atCharIndex: 5)
        XCTAssertNotNil(splitResult)

        guard let (part1, part2) = splitResult else { return }

        XCTAssertEqual(part1.originalText, "Hello")
        XCTAssertEqual(part2.originalText, "World")
        XCTAssertEqual(part1.startTime.secondsValue, 0.0, accuracy: 0.001)
        XCTAssertEqual(part1.endTime.secondsValue, 0.5, accuracy: 0.001)
        XCTAssertEqual(part2.startTime.secondsValue, 0.5, accuracy: 0.001)
        XCTAssertEqual(part2.endTime.secondsValue, 1.2, accuracy: 0.001)
    }

    func testSubtitleItemSplittingUserReportedCase() {
        let manager = SubtitleManager()

        let text = "Bonjour, yes, yes. You are for the tour, Très bien."
        // ASR 输出词序列（包含大小写与标点差异）
        let words = [
            WordToken(text: "Bonjour", startTime: .from(seconds: 0.08), endTime: .from(seconds: 0.40)),
            WordToken(text: "Yes", startTime: .from(seconds: 1.28), endTime: .from(seconds: 1.52)),
            WordToken(text: "yes", startTime: .from(seconds: 1.60), endTime: .from(seconds: 1.76)),
            WordToken(text: "you", startTime: .from(seconds: 1.92), endTime: .from(seconds: 2.00)), // 小写 you
            WordToken(text: "are", startTime: .from(seconds: 2.00), endTime: .from(seconds: 2.08)),
            WordToken(text: "for", startTime: .from(seconds: 2.16), endTime: .from(seconds: 2.24)),
            WordToken(text: "the", startTime: .from(seconds: 2.24), endTime: .from(seconds: 2.40)),
            WordToken(text: "tour", startTime: .from(seconds: 2.40), endTime: .from(seconds: 2.56)),
            WordToken(text: "Très", startTime: .from(seconds: 3.12), endTime: .from(seconds: 3.20)),
            WordToken(text: "bien", startTime: .from(seconds: 3.28), endTime: .from(seconds: 3.44))
        ]

        let item = SubtitleItem(
            startTime: .from(seconds: 0.08),
            endTime: .from(seconds: 3.44),
            originalText: text,
            words: words
        )

        // 1. 光标放置在 "You" 前面 (charIndex 19)
        let youIndex = text.range(of: "You")!.lowerBound
        let charIndex = text.distance(from: text.startIndex, to: youIndex)

        guard let (part1, part2) = manager.split(item: item, atCharIndex: charIndex) else {
            XCTFail("Split before 'You' should succeed")
            return
        }

        // 验证前半部分保持句尾标点，后半部分从 "You" 开始
        XCTAssertEqual(part1.originalText, "Bonjour, yes, yes.")
        XCTAssertEqual(part2.originalText, "You are for the tour, Très bien.")

        // 验证词级 WordTokens 正确切分归属
        XCTAssertEqual(part1.words.count, 3)
        XCTAssertEqual(part1.words.map { $0.text }, ["Bonjour", "Yes", "yes"])
        XCTAssertEqual(part2.words.count, 7)
        XCTAssertEqual(part2.words.first?.text, "you")

        // 验证切分时间点处于两句之间的间隔内 (1.76s ~ 1.92s)
        XCTAssertEqual(part1.endTime, part2.startTime)
        XCTAssertGreaterThanOrEqual(part1.endTime.secondsValue, 1.76)
        XCTAssertLessThanOrEqual(part1.endTime.secondsValue, 1.92)

        // 2. 光标放置在 "are" 前面
        let areIndex = text.range(of: "are")!.lowerBound
        let areCharIndex = text.distance(from: text.startIndex, to: areIndex)
        guard let (arePart1, arePart2) = manager.split(item: item, atCharIndex: areCharIndex) else {
            XCTFail("Split before 'are' should succeed")
            return
        }
        XCTAssertEqual(arePart1.originalText, "Bonjour, yes, yes. You")
        XCTAssertEqual(arePart2.originalText, "are for the tour, Très bien.")
        XCTAssertEqual(arePart1.words.map { $0.text }, ["Bonjour", "Yes", "yes", "you"])
        XCTAssertEqual(arePart2.words.first?.text, "are")
    }

    func testSubtitleItemMerging() {
        let manager = SubtitleManager()

        let item1 = SubtitleItem(
            startTime: CMTime.from(seconds: 1.0),
            endTime: CMTime.from(seconds: 2.0),
            originalText: "Line One",
            translatedText: "第一行"
        )
        let item2 = SubtitleItem(
            startTime: CMTime.from(seconds: 2.2),
            endTime: CMTime.from(seconds: 3.5),
            originalText: "Line Two",
            translatedText: "第二行"
        )

        let merged = manager.merge(items: [item1, item2])
        XCTAssertNotNil(merged)
        guard let merged = merged else { return }

        XCTAssertEqual(merged.originalText, "Line One Line Two")
        XCTAssertEqual(merged.translatedText, "第一行 第二行")
        XCTAssertEqual(merged.startTime.secondsValue, 1.0, accuracy: 0.001)
        XCTAssertEqual(merged.endTime.secondsValue, 3.5, accuracy: 0.001)
    }

    func testSRTExport() {
        let exporter = SRTExporter()
        let item = SubtitleItem(
            startTime: CMTime.from(seconds: 1.0),
            endTime: CMTime.from(seconds: 2.5),
            originalText: "Welcome to video",
            translatedText: "欢迎观看视频"
        )

        // 双语对照
        let bilingualSRT = exporter.exportSRT(items: [item], mode: .bilingual)
        XCTAssertTrue(bilingualSRT.contains("00:00:01,000 --> 00:00:02,500"))
        XCTAssertTrue(bilingualSRT.contains("欢迎观看视频"))
        XCTAssertTrue(bilingualSRT.contains("Welcome to video"))

        // 仅译文
        let translatedSRT = exporter.exportSRT(items: [item], mode: .translatedOnly)
        XCTAssertTrue(translatedSRT.contains("欢迎观看视频"))
        XCTAssertFalse(translatedSRT.contains("Welcome to video"))

        // 仅原文
        let originalSRT = exporter.exportSRT(items: [item], mode: .originalOnly)
        XCTAssertFalse(originalSRT.contains("欢迎观看视频"))
        XCTAssertTrue(originalSRT.contains("Welcome to video"))

        // 不内嵌/无
        let noneSRT = exporter.exportSRT(items: [item], mode: .none)
        XCTAssertEqual(noneSRT, "")
    }

    func testVideoExportModesDefinitions() {
        XCTAssertEqual(SubtitleExportMode.bilingual.displayName, "双语对照")
        XCTAssertEqual(SubtitleExportMode.translatedOnly.displayName, "仅目标语")
        XCTAssertEqual(SubtitleExportMode.originalOnly.displayName, "仅原始语")
        XCTAssertEqual(SubtitleExportMode.none.displayName, "没有字幕")

        XCTAssertEqual(VideoAudioExportMode.translated.displayName, "自动翻译的语言")
        XCTAssertEqual(VideoAudioExportMode.original.displayName, "原始语言")
    }

    func testVideoComposerWithSubtitleEmbedding() async throws {
        let testVideoPath = "/Users/zfdang/workspaces/video-auto-translate/Tests/Fme9C5ShSr2fuWQ8_Translated.mp4"
        guard FileManager.default.fileExists(atPath: testVideoPath) else { return }

        let composer = VideoComposer()
        let item = SubtitleItem(
            startTime: CMTime.from(seconds: 0.5),
            endTime: CMTime.from(seconds: 2.0),
            originalText: "Bonjour",
            translatedText: "你好，巴黎！"
        )

        let tempDir = FileManager.default.temporaryDirectory

        // 1. 测试双语内嵌导出
        let bilingualOut = tempDir.appendingPathComponent("test_bilingual_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: bilingualOut) }

        try await composer.compose(
            videoURL: URL(fileURLWithPath: testVideoPath),
            newAudioURL: nil,
            outputURL: bilingualOut,
            subtitles: [item],
            subtitleMode: .bilingual
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: bilingualOut.path))
        let bilingualSize = (try? FileManager.default.attributesOfItem(atPath: bilingualOut.path)[.size] as? UInt64) ?? 0
        XCTAssertGreaterThan(bilingualSize, 1000)

        // 2. 测试不内嵌字幕导出
        let noneOut = tempDir.appendingPathComponent("test_none_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: noneOut) }

        try await composer.compose(
            videoURL: URL(fileURLWithPath: testVideoPath),
            newAudioURL: nil,
            outputURL: noneOut,
            subtitles: [item],
            subtitleMode: .none
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: noneOut.path))
        let noneSize = (try? FileManager.default.attributesOfItem(atPath: noneOut.path)[.size] as? UInt64) ?? 0
        XCTAssertGreaterThan(noneSize, 1000)
    }

    func testLLMConfigurationEffectiveValues() {
        var config = LLMConfiguration(providerType: .localOllama)
        XCTAssertEqual(config.effectiveBaseURL, "http://localhost:11434/v1")
        XCTAssertEqual(config.effectiveModel, "qwen2.5:latest")

        config.providerType = .onlineCustom
        config.onlineBaseURL = "https://api.deepseek.com"
        config.onlineModel = "deepseek-chat"
        config.onlineAPIKey = "sk-test"
        XCTAssertEqual(config.effectiveBaseURL, "https://api.deepseek.com")
        XCTAssertEqual(config.effectiveModel, "deepseek-chat")
        XCTAssertEqual(config.effectiveAPIKey, "sk-test")
    }

    func testOllamaProbeAndLiveTranslation() async throws {
        let probe = OllamaProbe()
        let models = await probe.fetchLocalModels()
        guard !models.isEmpty else {
            print("Ollama 未启动，跳过实时翻译测试")
            return
        }

        XCTAssertTrue(models.contains(where: { $0.contains("qwen") }))

        let preferredModel = probe.findPreferredQwenModel(in: models) ?? "qwen2.5:latest"
        let config = LLMConfiguration(
            providerType: .localOllama,
            ollamaModel: preferredModel,
            targetLanguage: "简体中文"
        )

        let translator = SubtitleTranslator()
        let item = SubtitleItem(
            startTime: CMTime.from(seconds: 0),
            endTime: CMTime.from(seconds: 2),
            originalText: "Artificial intelligence is changing the world."
        )

        var statusStages: [String] = []
        var progressValues: [Double] = []

        try await translator.translate(items: [item], config: config) { progress, status in
            progressValues.append(progress)
            statusStages.append(status)
        }

        print("Live Qwen translation result: \(item.translatedText)")
        XCTAssertFalse(item.translatedText.isEmpty, "翻译结果不应为空")

        // 验证生命周期三阶段提示：启动模型 -> 翻译文本 -> 终止模型
        XCTAssertTrue(statusStages.contains(where: { $0.contains("启动模型") }), "应包含启动模型阶段提示: \(statusStages)")
        XCTAssertTrue(statusStages.contains(where: { $0.contains("翻译文本") }), "应包含翻译文本阶段提示: \(statusStages)")
        XCTAssertTrue(statusStages.contains(where: { $0.contains("终止模型") }), "应包含终止模型阶段提示: \(statusStages)")
        XCTAssertTrue((progressValues.last ?? 0.0) >= 0.95, "最终进度应接近完成")
    }

    func testASRVerboseJSONParsing() throws {
        let sampleJSON = """
        {
          "text": "Hello world welcome to native app",
          "words": [
            {"word": "Hello", "start": 0.1, "end": 0.5},
            {"word": "world", "start": 0.55, "end": 0.95},
            {"word": "welcome", "start": 1.2, "end": 1.6},
            {"word": "to", "start": 1.65, "end": 1.8},
            {"word": "native", "start": 1.85, "end": 2.2},
            {"word": "app", "start": 2.25, "end": 2.6}
          ]
        }
        """

        let decoded = try JSONDecoder().decode(ASRTranscriptionResponse.self, from: sampleJSON.data(using: .utf8)!)
        XCTAssertNotNil(decoded.words)
        XCTAssertEqual(decoded.words?.count, 6)

        let segmenter = NaturalLanguageSegmenter()
        let tokens = decoded.words!.map {
            WordToken(text: $0.word, startTime: CMTime.from(seconds: $0.start), endTime: CMTime.from(seconds: $0.end))
        }
        let subtitles = segmenter.segment(tokens: tokens, maxPauseGapSeconds: 0.2)
        XCTAssertFalse(subtitles.isEmpty)
        XCTAssertEqual(subtitles.first?.words.count, 2) // "Hello world" split by pause
    }

    // MARK: - Code Review (2026-10-21) Regression Tests

    func testR01_VideoComposerRejectsSameSourceAndDestination() async {
        let composer = VideoComposer()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("dummy_\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: tempURL.path, contents: Data("test".utf8))
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            try await composer.compose(videoURL: tempURL, outputURL: tempURL)
            XCTFail("同路径导出应该抛出错误")
        } catch {
            // 验证源文件未被删除
            XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path), "同路径被拒绝后源文件必须完整保留")
        }
    }

    func testR05_R06_SubtitleSplittingPreservesTranslationAndEnforcesMinDuration() {
        let manager = SubtitleManager()

        let item = SubtitleItem(
            startTime: CMTime.from(seconds: 1.0),
            endTime: CMTime.from(seconds: 3.0),
            originalText: "Hello world this is a test",
            translatedText: "你好世界这是一个测试"
        )

        // 拆分
        let res = manager.split(item: item, atCharIndex: 11) // "Hello world"
        XCTAssertNotNil(res)
        guard let (part1, part2) = res else { return }

        // R05: 译文不应被粗暴清空
        XCTAssertFalse(part1.translatedText.isEmpty, "拆分后第一部分应保留已有译文劳动成果")
        XCTAssertEqual(part1.translatedText, "你好世界这是一个测试")

        // R06: 最小时长校验，两段时长均应大于 0
        XCTAssertGreaterThan(part1.durationSeconds, 0.05)
        XCTAssertGreaterThan(part2.durationSeconds, 0.05)
        XCTAssertEqual(part1.endTime.secondsValue, part2.startTime.secondsValue, accuracy: 0.001)

        // 测试极短无法拆分的情况 (小于 160ms)
        let tinyItem = SubtitleItem(
            startTime: CMTime.from(seconds: 0.0),
            endTime: CMTime.from(seconds: 0.05),
            originalText: "Hi"
        )
        XCTAssertNil(manager.split(item: tinyItem, atCharIndex: 1), "超短切片应当拒绝拆分以防产生0时长")
    }

    func testR15_SubtitleMergingNestedIntervals() {
        let manager = SubtitleManager()

        let itemLong = SubtitleItem(
            startTime: CMTime.from(seconds: 0.0),
            endTime: CMTime.from(seconds: 10.0),
            originalText: "Long sentence"
        )
        let itemNested = SubtitleItem(
            startTime: CMTime.from(seconds: 1.0),
            endTime: CMTime.from(seconds: 2.0),
            originalText: "Nested short"
        )

        let merged = manager.merge(items: [itemLong, itemNested])
        XCTAssertNotNil(merged)
        // R15: 嵌套区间的结束时间应为 10.0，而非 2.0
        XCTAssertEqual(merged?.startTime.secondsValue, 0.0)
        XCTAssertEqual(merged?.endTime.secondsValue, 10.0)
    }

    func testR27_TimeTypesAccuracyAndBounds() {
        // 浮点毫秒四舍五入，消除截断 1ms 误差
        let t1 = CMTime.from(seconds: 1.001)
        XCTAssertEqual(t1.srtFormat, "00:00:01,001")

        let t2 = CMTime.from(seconds: 1.003)
        XCTAssertEqual(t2.srtFormat, "00:00:01,003")

        // 极端超大数值防溢出崩溃
        let huge = CMTime.from(seconds: 1e300)
        XCTAssertTrue(huge.secondsValue.isFinite)
        XCTAssertNoThrow(huge.srtFormat)

        // NaN 或负值安全
        let nanTime = CMTime.from(seconds: Double.nan)
        XCTAssertEqual(nanTime.secondsValue, 0.0)
    }

    func testR31_TranslatedOnlyModeDoesNotFallbackToOriginalText() {
        let exporter = SRTExporter()
        let itemWithoutTranslation = SubtitleItem(
            startTime: CMTime.from(seconds: 0.0),
            endTime: CMTime.from(seconds: 2.0),
            originalText: "Hello there",
            translatedText: ""
        )

        let srt = exporter.exportSRT(items: [itemWithoutTranslation], mode: .translatedOnly)
        // 仅译文模式下，未翻译的行不得输出原文
        XCTAssertFalse(srt.contains("Hello there"), "仅译文模式下未翻译项不能静默输出原文")
    }

    func testR04_ProjectPersistenceSerialization() throws {
        let item = SubtitleItem(
            startTime: CMTime.from(seconds: 1.0),
            endTime: CMTime.from(seconds: 3.5),
            originalText: "Test persistence",
            translatedText: "测试持久化"
        )
        var project = ProjectState(
            videoURL: URL(fileURLWithPath: "/tmp/sample.mp4"),
            subtitles: [item]
        )
        project.isDirty = true

        let data = try project.encodeDocument()
        XCTAssertFalse(data.isEmpty)

        var newProject = ProjectState()
        let doc = try ProjectState.decodeDocument(from: data)
        newProject.restore(from: doc)

        XCTAssertEqual(newProject.videoURL?.path, "/tmp/sample.mp4")
        XCTAssertEqual(newProject.subtitles.count, 1)
        XCTAssertEqual(newProject.subtitles.first?.originalText, "Test persistence")
        XCTAssertEqual(newProject.subtitles.first?.translatedText, "测试持久化")
        XCTAssertFalse(newProject.isDirty)
    }

    func testSubtitleTranslatorResilientParsing() throws {
        let translator = SubtitleTranslator()
        let item1 = SubtitleItem(startTime: .zero, endTime: .from(seconds: 1), originalText: "Bonjour")
        let item2 = SubtitleItem(startTime: .from(seconds: 1), endTime: .from(seconds: 2), originalText: "How are you")
        let chunk = [item1, item2]

        // 1. 标准 Markdown 代码块
        let mdJSON = """
        ```json
        [
          {"id": "\(item1.id.uuidString)", "translation": "你好"},
          {"id": "\(item2.id.uuidString)", "translation": "你好吗"}
        ]
        ```
        """
        let res1 = try translator.parseTranslationEntries(from: mdJSON, chunk: chunk)
        XCTAssertEqual(res1.count, 2)
        XCTAssertEqual(res1[0].translation, "你好")

        // 2. 包含非法转义序列 \' 以及尾随逗号
        let brokenEscapeJSON = """
        [
          {"id": "\(item1.id.uuidString)", "translation": "c\\'est la vie"},
          {"id": "\(item2.id.uuidString)", "translation": "fine",}
        ]
        """
        let res2 = try translator.parseTranslationEntries(from: brokenEscapeJSON, chunk: chunk)
        XCTAssertEqual(res2.count, 2)
        XCTAssertEqual(res2[0].translation, "c'est la vie")

        // 3. 包含尾随注释及带括号的引用 [1]
        let trailingCommentJSON = """
        [
          {"id": "\(item1.id.uuidString)", "translation": "你好"}
        ]
        Note: [1] The word Bonjour was translated colloquially.
        """
        let res3 = try translator.parseTranslationEntries(from: trailingCommentJSON, chunk: chunk)
        XCTAssertEqual(res3.count, 1)
        XCTAssertEqual(res3[0].translation, "你好")

        // 4. 对象包裹结构 (translations, data, items)
        let wrappedJSON = """
        {
          "translations": [
            {"id": "\(item1.id.uuidString)", "translation": "你好"}
          ]
        }
        """
        let res4 = try translator.parseTranslationEntries(from: wrappedJSON, chunk: chunk)
        XCTAssertEqual(res4.count, 1)

        // 5. 序号回退映射 (模型未原样返回 UUID，返回 1, 2 序号)
        let indexJSON = """
        [
          {"id": "1", "translation": "你好"},
          {"id": "2", "translation": "你好吗"}
        ]
        """
        let res5 = try translator.parseTranslationEntries(from: indexJSON, chunk: chunk)
        XCTAssertEqual(res5.count, 2)
        XCTAssertEqual(res5[0].id, item1.id.uuidString)
        XCTAssertEqual(res5[1].id, item2.id.uuidString)

        // 6. 纯字符串数组对应映射
        let strArrayJSON = """
        ["你好", "你好吗"]
        """
        let res6 = try translator.parseTranslationEntries(from: strArrayJSON, chunk: chunk)
        XCTAssertEqual(res6.count, 2)
        XCTAssertEqual(res6[0].id, item1.id.uuidString)
        XCTAssertEqual(res6[0].translation, "你好")

        // 7. 单个对象容错提取（兄弟对象含未转义引号）
        let brokenQuotesJSON = """
        [
          {"id": "\(item1.id.uuidString)", "translation": "Bonjour"},
          {"id": "\(item2.id.uuidString)", "translation": "He said \\"yes\\" to me"}
        ]
        """
        let res7 = try translator.parseTranslationEntries(from: brokenQuotesJSON, chunk: chunk)
        XCTAssertFalse(res7.isEmpty)
        XCTAssertEqual(res7[0].translation, "Bonjour")
    }

    func testModelStorageManagerSymlinkDetection() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_hf_cache_\(UUID().uuidString)")
        let blobsDir = tempDir.appendingPathComponent("blobs")
        let snapshotDir = tempDir.appendingPathComponent("snapshots/testhash123")
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create blob files
        let configBlob = blobsDir.appendingPathComponent("config_blob")
        let weightsBlob = blobsDir.appendingPathComponent("weights_blob")
        try Data("{\"architectures\": [\"Qwen3ForCausalLM\"]}".utf8).write(to: configBlob)
        // Write 1.5MB of dummy data
        let dummyWeights = Data(repeating: 0x42, count: 1_500_000)
        try dummyWeights.write(to: weightsBlob)

        // Create symlinks in snapshotDir
        let configLink = snapshotDir.appendingPathComponent("config.json")
        let weightsLink = snapshotDir.appendingPathComponent("model.safetensors")
        try FileManager.default.createSymbolicLink(at: configLink, withDestinationURL: configBlob)
        try FileManager.default.createSymbolicLink(at: weightsLink, withDestinationURL: weightsBlob)

        let config = ModelStorageConfig(locationType: .custom, customDirectoryPath: tempDir.deletingLastPathComponent().path)
        let manager = ModelStorageManager(config: config)

        let preset = ASRModelPreset(
            id: "test-model",
            displayName: "Test Model",
            repoOrFileName: tempDir.lastPathComponent,
            sizeDescription: "~1.5 MB",
            approxSizeBytes: 1_500_000,
            isRepo: true,
            note: "Test"
        )

        let state = manager.detectModel(preset)
        switch state {
        case .ready(let localPath, let sizeDescription):
            XCTAssertTrue(localPath.contains(tempDir.lastPathComponent))
            XCTAssertTrue(sizeDescription.contains("MB"))
        default:
            XCTFail("Symlinked HuggingFace cache must be detected as .ready, got \(state)")
        }
    }

    func testOllamaModelPresetDefinitions() {
        let presets = OllamaModelPreset.recommended
        XCTAssertFalse(presets.isEmpty)
        XCTAssertTrue(presets.contains(where: { $0.name == "qwen2.5:latest" }))
        XCTAssertEqual(presets.first?.name, "qwen2.5:latest")
    }
}
