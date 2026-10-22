import XCTest
import CoreMedia
import AVFoundation
@testable import VideoAutoTranslateCore

final class ReviewRegressionTests: XCTestCase {
    func testFirstWordAndUnicodeSplitBoundaries() {
        let text = "Hello world third fourth"
        let words = text.split(separator: " ").enumerated().map { index, word in
            WordToken(text: String(word), startTime: .from(seconds: Double(index)), endTime: .from(seconds: Double(index) + 0.8))
        }
        let item = SubtitleItem(startTime: .zero, endTime: .from(seconds: 4), originalText: text, words: words)
        let split = SubtitleManager().split(item: item, atCharIndex: 2)
        XCTAssertEqual(split?.0.originalText, "Hello")
        XCTAssertEqual(split?.1.originalText, "world third fourth")
        XCTAssertEqual(SubtitleManager.characterOffset(in: "😀a bc", utf16Offset: 4), 3)
        XCTAssertNil(SubtitleManager.characterOffset(in: "😀a bc", utf16Offset: 1))
    }

    func testCrowdedTimelinePreservesValidInputInsteadOfOverlapping() {
        let rows = (0..<5).map { index in
            SubtitleItem(startTime: .from(seconds: Double(index) * 0.2), endTime: .from(seconds: Double(index) * 0.2 + 0.15), originalText: "row", translatedText: "这是一段很长的翻译结果")
        }
        let result = TimelineAligner().matchTimelineToTranslation(items: rows, videoDuration: 1)
        XCTAssertEqual(result.count, rows.count)
        for i in result.indices {
            XCTAssertLessThanOrEqual(result[i].endTime.secondsValue, 1)
            if i > 0 { XCTAssertGreaterThanOrEqual(result[i].startTime, result[i-1].endTime) }
        }
    }

    func testSegmentationCannotChangeWordsAndSupportsUnspacedText() {
        let tokens = ["Hello", "world"].enumerated().map { i, word in
            WordToken(text: word, startTime: .from(seconds: Double(i)), endTime: .from(seconds: Double(i+1)))
        }
        let segmenter = LLMSegmenter()
        let rejected = segmenter.alignLinesToTokens(lines: ["Goodbye moon"], tokens: tokens)
        XCTAssertEqual(rejected.map(\.originalText).joined(separator: " "), "Hello world")
        let chinese = ["你好", "世界"].enumerated().map { i, word in
            WordToken(text: word, startTime: .from(seconds: Double(i)), endTime: .from(seconds: Double(i+1)))
        }
        let result = segmenter.alignLinesToTokens(lines: ["你好世界"], tokens: chinese)
        XCTAssertEqual(result.first?.words.count, 2)
        XCTAssertEqual(result.first?.endTime.secondsValue, 2)
    }

    func testLLMSegmenterStatusCallbackUpdates() async throws {
        let tokens = (0..<150).map { i in
            WordToken(text: "word\(i)", startTime: .from(seconds: Double(i) * 0.5), endTime: .from(seconds: Double(i + 1) * 0.5))
        }
        let segmenter = LLMSegmenter()
        var reportedStatuses: [String] = []
        var reportedProgress: [Double] = []

        // 使用离线/无效配置，将触发初始状态汇报、批次状态更新以及安全重构完成回调
        var config = LLMConfiguration()
        config.providerType = .onlineCustom
        config.onlineBaseURL = "http://127.0.0.1:9" // 快速失败端口
        config.onlineAPIKey = "dummy"

        _ = try await segmenter.segment(tokens: tokens, config: config) { status, progress in
            reportedStatuses.append(status)
            reportedProgress.append(progress)
        }

        XCTAssertFalse(reportedStatuses.isEmpty, "必须提供状态栏进度描述回调")
        XCTAssertTrue(reportedStatuses.contains(where: { $0.contains("批次") || $0.contains("分析") }), "状态信息应包含批次或分析详情")
        XCTAssertEqual(reportedProgress.last, 1.0, "最终进度必须达到 1.0 (100%)")
    }

    func testTranslationSequenceBaseAndCompleteCoverage() throws {
        let rows = ["First", "Second"].map { SubtitleItem(startTime: .zero, endTime: .from(seconds: 1), originalText: $0) }
        let translator = SubtitleTranslator()
        let entries = try translator.parseTranslationEntries(from: "[{\"id\":0,\"translation\":\"A\"},{\"id\":1,\"translation\":\"B\"}]", chunk: rows)
        let valid = try translator.validatedTranslations(entries, for: rows)
        XCTAssertEqual(valid[rows[0].id.uuidString], "A")
        XCTAssertEqual(valid[rows[1].id.uuidString], "B")
        XCTAssertThrowsError(try translator.validatedTranslations(Array(entries.prefix(1)), for: rows))
        XCTAssertThrowsError(try translator.validatedTranslations([entries[0], entries[0]], for: rows))
    }

    func testProjectAudioSurvivesTemporarySourceRemoval() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("temporary.wav")
        try Data("saved audio".utf8).write(to: audio)
        let row = SubtitleItem(startTime: .zero, endTime: .from(seconds: 1), originalText: "hello", dubbedAudioURL: audio)
        let url = folder.appendingPathComponent("Example.vatproject")
        try ProjectStore.write(documentData: ProjectState(subtitles: [row]).encodeDocument(), to: url)
        try FileManager.default.removeItem(at: audio)
        let restored = try ProjectStore.read(from: url)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.subtitles.first?.dubbedAudioURL)), Data("saved audio".utf8))
    }

    func testDubbingSignatureExpiresWhenContentOrTimingChanges() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let row = SubtitleItem(startTime: .zero, endTime: .from(seconds: 1), originalText: "hello", translatedText: "你好", dubbedAudioURL: url)
        row.dubbedAudioSignature = row.audioSignature(voice: "zh-CN")
        XCTAssertTrue(row.hasCurrentAudio(voice: "zh-CN"))
        XCTAssertFalse(row.hasCurrentAudio(voice: "ja-JP"))
        row.endTime = .from(seconds: 2)
        XCTAssertFalse(row.hasCurrentAudio(voice: "zh-CN"))
        XCTAssertNil(row.dubbedAudioURL)
    }

    func testTimingEditsRejectOverlapsAndMediaOverflow() {
        XCTAssertThrowsError(try SubtitleTiming.validate(start: 1, end: 3, mediaDuration: 2, previousEnd: nil, nextStart: nil))
        XCTAssertThrowsError(try SubtitleTiming.validate(start: 1, end: 2, mediaDuration: 3, previousEnd: 1.5, nextStart: nil))
        XCTAssertNoThrow(try SubtitleTiming.validate(start: 1, end: 2, mediaDuration: 3, previousEnd: 1, nextStart: 2))
    }

    func testMixerRejectsMissingSpeechInsteadOfSilentlySkipping() async {
        let row = SubtitleItem(startTime: .zero, endTime: .from(seconds: 1), originalText: "Missing")
        do {
            try await AudioMixer().mix(backgroundAudioURL: nil, subtitles: [row], to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a"))
            XCTFail("Missing audio must block the result")
        } catch { XCTAssertTrue(error.localizedDescription.contains("缺少配音")) }
    }

    func testIncompleteSubtitleExportRequiresExplicitSkipping() throws {
        let good = SubtitleItem(startTime: .zero, endTime: .from(seconds: 1), originalText: "A", translatedText: "甲")
        let bad = SubtitleItem(startTime: .from(seconds: 1), endTime: .from(seconds: 2), originalText: "B")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".srt")
        defer { try? FileManager.default.removeItem(at: url) }
        let exporter = SRTExporter()
        XCTAssertThrowsError(try exporter.saveToFile(items: [good, bad], to: url, mode: .translatedOnly))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try exporter.saveToFile(items: [good, bad], to: url, mode: .translatedOnly, allowSkippingIssues: true)
        XCTAssertEqual(exporter.validate(items: [good, bad], mode: .translatedOnly).validCount, 1)
        XCTAssertFalse(try String(contentsOf: url).contains("待翻译"))
    }

    func testOriginalAuditionAnchorsSurviveTimingChangesAndPersistence() throws {
        let row = SubtitleItem(startTime: .from(seconds: 1), endTime: .from(seconds: 2), originalText: "hello")
        row.startTime = .from(seconds: 3)
        row.endTime = .from(seconds: 4)
        let copy = row.snapshot()
        let decoded = try JSONDecoder().decode(SubtitleItem.self, from: JSONEncoder().encode(copy))
        XCTAssertEqual(decoded.sourceStartTime.secondsValue, 1)
        XCTAssertEqual(decoded.sourceEndTime.secondsValue, 2)
        XCTAssertEqual(decoded.startTime.secondsValue, 3)
    }

    @MainActor func testLateSpeechCannotInstallAnOutdatedCache() async throws {
        let row = SubtitleItem(startTime: .zero, endTime: .from(seconds: 1), originalText: "hello", translatedText: "你好")
        let task = Task { try await SubtitleManager().reDub(item: row, ttsService: DelayedReviewTTS(), voice: "zh-CN") }
        try await Task.sleep(nanoseconds: 10_000_000)
        row.translatedText = "新译文"
        do { try await task.value; XCTFail("A stale response must be rejected") }
        catch { XCTAssertNil(row.dubbedAudioURL) }
    }

    func testPreferencesEncodingExcludesCredentials() throws {
        var config = LLMConfiguration()
        config.onlineAPIKey = "secret-review-sentinel"
        let preferences = ApplicationPreferences(llm: config, asr: ASRConfiguration(), storage: ModelStorageConfig())
        let data = try preferences.encodedWithoutSecrets()
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("secret-review-sentinel"))
        XCTAssertTrue(TargetLanguagePreset.defaultPresets.contains { $0.name == LLMConfiguration().targetLanguage })
    }
    func testWaveformEnvelopeReadsTheSelectedInterval() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            buffer.frameLength = 16000
            for index in 0..<16000 { buffer.floatChannelData![0][index] = index < 8000 ? 0 : 0.5 }
            try file.write(from: buffer)
        }
        let silent = try await AudioWaveform.load(url: url, range: 0...0.8)
        let speech = try await AudioWaveform.load(url: url, range: 1.2...1.8)
        XCTAssertEqual(silent.max(), 0)
        XCTAssertGreaterThan(speech.max() ?? 0, 0.4)
    }

    func testLoadingProjectCannotReuseAnotherServiceCredential() throws {
        var project = ProjectState()
        project.llmConfig.onlineAPIKey = "private-key-A"
        project.llmConfig.onlineBaseURL = "https://a.example/v1"
        let document = ProjectDocument(llmConfig: LLMConfiguration(onlineBaseURL: "https://b.example/v1"))
        project.restore(from: document)
        XCTAssertEqual(project.llmConfig.onlineAPIKey, "")
    }

}

private struct DelayedReviewTTS: TTSServiceProtocol {
    func synthesize(text: String, voice: String, outputURL: URL) async throws -> URL {
        try await Task.sleep(nanoseconds: 60_000_000)
        try Data([1]).write(to: outputURL)
        return outputURL
    }


}
