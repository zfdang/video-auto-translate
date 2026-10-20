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

        let srt = exporter.exportSRT(items: [item], mode: .bilingual)
        XCTAssertTrue(srt.contains("00:00:01,000 --> 00:00:02,500"))
        XCTAssertTrue(srt.contains("欢迎观看视频"))
        XCTAssertTrue(srt.contains("Welcome to video"))
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

        try await translator.translate(items: [item], config: config)
        print("Live Qwen translation result: \(item.translatedText)")
        XCTAssertFalse(item.translatedText.isEmpty, "翻译结果不应为空")
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
}
