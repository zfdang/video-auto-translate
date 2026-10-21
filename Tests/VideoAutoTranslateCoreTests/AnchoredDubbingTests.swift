import XCTest
import AVFoundation
import CoreMedia
@testable import VideoAutoTranslateCore
@testable import VideoAutoTranslateApp

final class AnchoredDubbingTests: XCTestCase {
    private func row(_ start: Double, _ end: Double, text: String = "测试译文") -> SubtitleItem {
        SubtitleItem(startTime: .from(seconds: start), endTime: .from(seconds: end), originalText: "source", translatedText: text)
    }

    func testShortSpeechDoesNotPullNextSentenceForwardAndMatchingIsIdempotent() {
        let rows = [row(0, 4, text: "好"), row(4.2, 8, text: "接着说明第二个操作步骤")]
        let aligner = TimelineAligner()
        let first = aligner.matchTimelineToTranslation(items: rows, videoDuration: 8)
        XCTAssertLessThan(first[0].endTime.secondsValue, 1)
        XCTAssertEqual(first[1].startTime.secondsValue, 4.2, accuracy: 0.001)
        for _ in 0..<10 {
            XCTAssertEqual(aligner.matchTimelineToTranslation(items: first, videoDuration: 8), first)
        }
        XCTAssertEqual(rows[0].endTime.secondsValue, 4, "Planning must not mutate the input")
    }

    func testLongSpeechHasBoundedBorrowingAndCannotCrossNextAnchorOrVideoEnd() {
        let long = String(repeating: "长", count: 80)
        let rows = [row(0, 2, text: long), row(2.3, 3, text: long), row(8, 9, text: long)]
        let planned = TimelineAligner().matchTimelineToTranslation(items: rows, videoDuration: 9.2)
        XCTAssertEqual(planned[0].endTime.secondsValue, 2.22, accuracy: 0.001)
        XCTAssertEqual(planned[1].endTime.secondsValue, 3.5, accuracy: 0.001)
        XCTAssertEqual(planned[2].endTime.secondsValue, 9.12, accuracy: 0.001)
        XCTAssertEqual(planned.map { $0.startTime }, rows.map { $0.sourceStartTime })
        XCTAssertEqual(TimelineAligner.pacingIssues(items: planned, language: "zh").count, 3)
    }

    func testInvalidAnchorsCannotBeRepairedByAccumulatingDelay() {
        let rows = [row(0, 2), row(1, 3)]
        XCTAssertEqual(TimelineAligner().matchTimelineToTranslation(items: rows, videoDuration: 4), rows)
    }

    @MainActor func testRealMeasurementOverridesCharacterEstimateAndCacheSurvivesTimingEdits() async throws {
        let tts = TimingFixtureTTS(duration: 1, leading: 0.25, trailing: 0.35)
        let manager = SubtitleManager()
        let input = [row(0, 4, text: String(repeating: "长", count: 100)), row(4.2, 8)]
        let planned = try await TimelineAligner().matchTimelineUsingSpeech(
            items: input, language: "zh", voice: "zh-CN", ttsService: tts,
            manager: manager, videoDuration: 8)
        XCTAssertEqual(tts.calls, 2)
        XCTAssertNil(input[0].naturalSpeech, "Proposals own their caches until confirmed")
        XCTAssertEqual(planned[0].durationSeconds, 1.08, accuracy: 0.02)
        XCTAssertEqual(planned[1].startTime.secondsValue, 4.2, accuracy: 0.001)
        XCTAssertNil(planned[0].dubbingTimingIssue)
        XCTAssertFalse(TimelineAligner.pacingIssues(items: planned, language: "zh").contains(planned[0].id))
        planned[0].endTime = .from(seconds: 3)
        try await manager.reDub(item: planned[0], ttsService: tts)
        defer { if let url = planned[0].dubbedAudioURL { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(tts.calls, 2, "Timing edits must reuse measured audio")
        let duration = try await AVURLAsset(url: XCTUnwrap(planned[0].dubbedAudioURL)).load(.duration)
        XCTAssertEqual(duration.secondsValue, 1.08, accuracy: 0.02, "Short speech must not be stretched to fill 3 seconds")
        let again = try await TimelineAligner().matchTimelineUsingSpeech(
            items: planned, language: "zh", voice: "zh-CN", ttsService: tts,
            manager: manager, videoDuration: 8)
        XCTAssertEqual(tts.calls, 2)
        XCTAssertEqual(again[0].durationSeconds, 1.08, accuracy: 0.02)
    }

    @MainActor func testOverlongSpeechBlocksDubbingAndContentOrVoiceInvalidatesRawCache() async throws {
        let manager = SubtitleManager()
        let tts = TimingFixtureTTS(duration: 2)
        let item = row(0, 1)
        do {
            try await manager.reDub(item: item, ttsService: tts)
            XCTFail("Overlong speech must not be accelerated or published")
        } catch { XCTAssertTrue(error.localizedDescription.contains("匹配译文时间轴")) }
        XCTAssertNil(item.dubbedAudioURL)
        XCTAssertNotNil(item.dubbingTimingIssue)
        _ = try await manager.prepareNaturalSpeech(item: item, ttsService: tts)
        XCTAssertEqual(tts.calls, 1)
        _ = try await manager.prepareNaturalSpeech(item: item, ttsService: tts, voice: "en-US")
        XCTAssertEqual(tts.calls, 2)
        item.translatedText = "新的译文"
        XCTAssertNil(item.currentNaturalSpeech)
        _ = try await manager.prepareNaturalSpeech(item: item, ttsService: tts)
        XCTAssertEqual(tts.calls, 3)
    }

    @MainActor func testGentleAccelerationFitsAndRetainsAudibleTail() async throws {
        let manager = SubtitleManager()
        let tts = TimingFixtureTTS(duration: 1.1)
        let planned = try await TimelineAligner().matchTimelineUsingSpeech(
            items: [row(0, 1)], language: "zh", voice: "zh-CN", ttsService: tts, manager: manager, videoDuration: 1)
        let item = planned[0]
        let url = try XCTUnwrap(item.dubbedAudioURL)
        let confirmedData = try Data(contentsOf: url)
        try await manager.reDub(item: item, ttsService: tts)
        XCTAssertEqual(tts.calls, 1)
        XCTAssertEqual(item.dubbedAudioURL, url)
        XCTAssertEqual(try Data(contentsOf: url), confirmedData, "Generation must reuse the exact confirmed audio")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 1, accuracy: 0.005)
        let tail = try await AudioWaveform.load(url: url, range: 0.9...0.99)
        XCTAssertGreaterThan(tail.max() ?? 0, 0.01, "Gentle fitting must retain the end of speech")
    }

    @MainActor func testTrimKeepsInternalPausesAndRejectsSilence() async throws {
        let manager = SubtitleManager()
        let item = row(0, 4)
        let speech = try await manager.prepareNaturalSpeech(item: item, ttsService: TimingFixtureTTS(duration: 2, internalPause: true))
        XCTAssertEqual(speech.duration, 2, accuracy: 0.005)
        let middle = try await AudioWaveform.load(url: speech.url, range: 0.9...1.1)
        XCTAssertEqual(middle.max() ?? 1, 0)
        do {
            _ = try await manager.prepareNaturalSpeech(item: row(0, 4), ttsService: TimingFixtureTTS(duration: 1, silent: true))
            XCTFail("Silent TTS output cannot be treated as successful speech")
        } catch { XCTAssertTrue(error.localizedDescription.contains("静音")) }
    }

    @MainActor func testCancelledMeasurementCannotPublishCache() async throws {
        let item = row(0, 4)
        let task = Task {
            try await SubtitleManager().prepareNaturalSpeech(item: item, ttsService: TimingFixtureTTS(duration: 1, delay: true))
        }
        await Task.yield()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertNil(item.naturalSpeech) }
    }

    @MainActor func testUnchangedTimingStillProducesReviewableMeasuredConflictAndUndo() async throws {
        let app = AppState(probeServices: false)
        let rows = [row(0, 1)]
        app.project.subtitles = rows
        let snapshot = app.createSubtitlesSnapshot()
        await app.runEditingJob(name: "匹配译文时间轴", snapshot: snapshot, reviewUnchangedResult: true) {
            try await app.timelineAligner.matchTimelineUsingSpeech(
                items: snapshot, language: "zh", voice: app.project.llmConfig.targetLanguageVoiceCode,
                ttsService: TimingFixtureTTS(duration: 3), manager: app.subtitleManager, videoDuration: 1)
        }
        let proposal = try XCTUnwrap(app.editProposal)
        XCTAssertNotNil(proposal.after[0].dubbingTimingIssue)
        XCTAssertNil(app.project.subtitles[0].naturalSpeech)
        app.applyEditProposal()
        XCTAssertNotNil(app.project.subtitles[0].dubbingTimingIssue)
        XCTAssertTrue(app.statusMessage.contains("1 句"))
        app.undo()
        XCTAssertNil(app.project.subtitles[0].naturalSpeech)
    }

    @MainActor func testTimingButtonMeasuresWithSelectedVoiceAndRejectsChangedLanguage() async throws {
        let media = FileManager.default.temporaryDirectory.appendingPathComponent("timing-media-\(UUID()).wav")
        _ = try await TimingFixtureTTS(duration: 8).synthesize(text: "media", voice: "zh-CN", outputURL: media)
        defer { try? FileManager.default.removeItem(at: media) }
        let app = AppState(probeServices: false)
        let fixture = TimingFixtureTTS(duration: 1)
        app.ttsService = fixture
        app.project.videoURL = media
        app.player.replaceCurrentItem(with: AVPlayerItem(url: media))
        app.project.subtitles = [row(0, 4), row(4.2, 8)]
        await app.matchTimelineToTranslation()
        XCTAssertEqual(fixture.calls, 2)
        let proposal = try XCTUnwrap(app.editProposal)
        XCTAssertEqual(proposal.after[0].currentNaturalSpeech?.voice, app.project.llmConfig.targetLanguageVoiceCode)
        XCTAssertEqual(app.project.subtitles[0].durationSeconds, 4)
        app.project.llmConfig.targetLanguage = "English"
        app.applyEditProposal()
        XCTAssertNil(app.editProposal)
        XCTAssertEqual(app.project.subtitles[0].durationSeconds, 4)
    }

    func testInvalidCMTimesAreRejectedRatherThanSanitizedIntoAnchors() {
        let invalid = SubtitleItem(startTime: .invalid, endTime: .from(seconds: 2), originalText: "source", translatedText: "好")
        let negative = SubtitleItem(startTime: CMTime(value: -1, timescale: 1), endTime: .from(seconds: 2), originalText: "source", translatedText: "好")
        for item in [invalid, negative] {
            let result = TimelineAligner().matchTimelineToTranslation(items: [item], videoDuration: 3)
            XCTAssertTrue(result[0] === item)
        }
    }

    @MainActor func testGenerationCannotAccelerateEvenWhenSpeechWouldFitAtGentleRate() async throws {
        let item = row(2, 3)
        let manager = SubtitleManager()
        let tts = TimingFixtureTTS(duration: 1.1)
        do {
            try await manager.reDub(item: item, ttsService: tts)
            XCTFail("Generation must request an explicit timeline match, not adjust speech")
        } catch { XCTAssertTrue(error.localizedDescription.contains("匹配译文时间轴")) }
        XCTAssertNil(item.dubbedAudioURL)
        XCTAssertEqual(item.startTime.secondsValue, 2)
        XCTAssertEqual(item.endTime.secondsValue, 3)
        XCTAssertEqual(item.currentNaturalSpeech?.duration ?? 0, 1.1, accuracy: 0.005)
    }

    @MainActor func testConfirmedMatchedAudioSurvivesSaveAndGenerationDoesNotSynthesize() async throws {
        let manager = SubtitleManager()
        let planned = try await TimelineAligner().matchTimelineUsingSpeech(
            items: [row(0, 1)], language: "zh", voice: "zh-CN", ttsService: TimingFixtureTTS(duration: 1.1), manager: manager, videoDuration: 1)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectURL = folder.appendingPathComponent("Confirmed.vatproject")
        try ProjectStore.write(documentData: ProjectState(subtitles: planned).encodeDocument(), to: projectURL)
        let loaded = try ProjectStore.read(from: projectURL).subtitles[0]
        let url = try XCTUnwrap(loaded.dubbedAudioURL)
        let before = try Data(contentsOf: url)
        let tts = TimingFixtureTTS(duration: 9)
        try await manager.reDub(item: loaded, ttsService: tts)
        XCTAssertEqual(tts.calls, 0)
        XCTAssertEqual(loaded.dubbedAudioURL, url)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(loaded.startTime.secondsValue, 0)
        XCTAssertEqual(loaded.endTime.secondsValue, 1)
        defer { for item in planned { if let url = item.dubbedAudioURL { try? FileManager.default.removeItem(at: url) } } }
    }

    @MainActor func testMixedMatchedAudioKeepsTheGapBeforeTheNextSentence() async throws {
        let planned = try await TimelineAligner().matchTimelineUsingSpeech(
            items: [row(0, 4), row(4.2, 8)], language: "zh", voice: "zh-CN",
            ttsService: TimingFixtureTTS(duration: 1), manager: SubtitleManager(), videoDuration: 8)
        let mixed = FileManager.default.temporaryDirectory.appendingPathComponent("matched-mix-\(UUID()).m4a")
        defer {
            try? FileManager.default.removeItem(at: mixed)
            for item in planned { if let url = item.dubbedAudioURL { try? FileManager.default.removeItem(at: url) } }
        }
        try await AudioMixer().mix(backgroundAudioURL: nil, subtitles: planned, to: mixed)
        let gap = try await AudioWaveform.load(url: mixed, range: 2...4)
        let second = try await AudioWaveform.load(url: mixed, range: 4.3...5)
        XCTAssertLessThan(gap.max() ?? 1, 0.001)
        XCTAssertGreaterThan(second.max() ?? 0, 0.01)
    }

    func testRatePolicyNeverSlowsAndRejectsInvalidOrExcessiveRates() throws {
        XCTAssertEqual(try DubbingPacing.rate(naturalDuration: 1, availableDuration: 5), 1)
        XCTAssertEqual(try DubbingPacing.rate(naturalDuration: 1.1, availableDuration: 1), 1.1, accuracy: 0.001)
        XCTAssertThrowsError(try DubbingPacing.rate(naturalDuration: 2, availableDuration: 1))
        XCTAssertThrowsError(try DubbingPacing.rate(naturalDuration: .nan, availableDuration: 1))
    }
}

private final class TimingFixtureTTS: TTSServiceProtocol {
    var calls = 0
    let duration: Double
    let leading: Double
    let trailing: Double
    let internalPause: Bool
    let silent: Bool
    let delay: Bool

    init(duration: Double, leading: Double = 0, trailing: Double = 0,
         internalPause: Bool = false, silent: Bool = false, delay: Bool = false) {
        self.duration = duration; self.leading = leading; self.trailing = trailing
        self.internalPause = internalPause; self.silent = silent; self.delay = delay
    }

    func synthesize(text: String, voice: String, outputURL: URL) async throws -> URL {
        calls += 1
        if delay { try await Task.sleep(nanoseconds: 100_000_000) }
        let sampleRate = 24000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let count = AVAudioFrameCount((duration + leading + trailing) * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for frame in 0..<Int(count) {
            let time = Double(frame) / sampleRate - leading
            let pause = internalPause && time > duration * 0.4 && time < duration * 0.6
            buffer.floatChannelData![0][frame] = time >= 0 && time < duration && !pause && !silent
                ? Float(sin(Double(frame) * 2 * .pi * 440 / sampleRate)) * 0.1 : 0
        }
        do { let file = try AVAudioFile(forWriting: outputURL, settings: format.settings); try file.write(from: buffer) }
        return outputURL
    }
}
