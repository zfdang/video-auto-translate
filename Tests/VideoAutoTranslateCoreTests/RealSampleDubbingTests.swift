import XCTest
import AVFoundation
@testable import VideoAutoTranslateCore
@testable import VideoAutoTranslateApp

/// Opt-in real-media acceptance test. Uses the supplied Paris tour and its
/// captured 25-line project, real system voices, local context planning and export.
final class RealSampleDubbingTests: XCTestCase {
    @MainActor func testParisTourMatchAuditionGenerateAndExport() async throws {
        guard ProcessInfo.processInfo.environment["VAT_REAL_DUBBING_SAMPLE"] == "1" else {
            throw XCTSkip("Set VAT_REAL_DUBBING_SAMPLE=1 to validate the local sample with real voices and export")
        }
        struct Sample: Decodable {
            struct Row: Decodable { let start: Double; let end: Double; let source: String; let translation: String }
            let rows: [Row]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let video = root.appendingPathComponent("Tests/Fme9C5ShSr2fuWQ8_Translated.mp4")
        guard FileManager.default.fileExists(atPath: video.path) else { throw XCTSkip("The local sample video is unavailable") }
        let folder = root.appendingPathComponent("dist/timing-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "paris-tour-timing", withExtension: "json", subdirectory: "Fixtures")))
        let sample = try JSONDecoder().decode(Sample.self, from: data)
        let app = AppState(probeServices: false, recoveryURL: folder.appendingPathComponent("TestRecovery.vatproject"))
        app.project.videoURL = video
        app.player.replaceCurrentItem(with: AVPlayerItem(url: video))
        app.project.subtitles = sample.rows.map {
            SubtitleItem(startTime: .from(seconds: $0.start), endTime: .from(seconds: $0.end), originalText: $0.source, translatedText: $0.translation)
        }
        let original = app.createSubtitlesSnapshot()
        print("REAL SAMPLE: matching all \(original.count) lines with real zh-CN speech"); fflush(stdout)
        await app.matchTimelineToTranslation()
        XCTAssertNil(app.errorMessage)
        let proposal = try XCTUnwrap(app.editProposal)
        XCTAssertEqual(proposal.after.count, 25)
        XCTAssertEqual(proposal.after.map(\.translatedText), original.map(\.translatedText))
        let voice = app.project.llmConfig.targetLanguageVoiceCode
        let timeline = proposal.after.map { ($0.startTime, $0.endTime, $0.dubbedAudioURL) }
        var report: [[String: Any]] = []
        var fastest = 1.0
        for (index, item) in proposal.after.enumerated() {
            XCTAssertTrue(item.hasCurrentAudio(voice: voice), "Line \(index + 1) must be playable")
            let url = try XCTUnwrap(item.dubbedAudioURL)
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let playable = try await asset.load(.isPlayable)
            XCTAssertTrue(playable)
            XCTAssertLessThanOrEqual(duration.seconds, item.durationSeconds + DubbingPacing.timeTolerance)
            await app.auditionSubtitle(item, target: .translated)
            app.auditionPlayer?.volume = 0
            XCTAssertNotNil(app.auditionPlayer)
            XCTAssertNil(app.errorMessage)
            app.cancelAudition()
            let rate = max(1, item.currentNaturalSpeech!.duration / item.durationSeconds)
            fastest = max(fastest, rate)
            report.append(["row": index + 1, "start": item.startTime.secondsValue, "end": item.endTime.secondsValue,
                "sourceStart": item.sourceStartTime.secondsValue, "sourceEnd": item.sourceEndTime.secondsValue,
                "contextStart": item.timingContext!.start.secondsValue, "contextEnd": item.timingContext!.end.secondsValue,
                "naturalDuration": item.currentNaturalSpeech!.duration, "speechDuration": duration.seconds,
                "rate": rate, "translation": item.translatedText, "playable": true])
        }
        app.applyEditProposal()
        print("REAL SAMPLE: all 25 lines auditionable; generating the full dubbed track"); fflush(stdout)
        await app.runFullDubbing()
        XCTAssertNil(app.errorMessage)
        XCTAssertEqual(app.previewAudioTrack, .translated)
        XCTAssertFalse(app.project.isProcessing)
        for (index, item) in app.project.subtitles.enumerated() {
            XCTAssertEqual(item.startTime, timeline[index].0)
            XCTAssertEqual(item.endTime, timeline[index].1)
            XCTAssertEqual(item.dubbedAudioURL, timeline[index].2)
        }
        let destination = folder.appendingPathComponent("cluster-preview.mp4")
        print("REAL SAMPLE: exporting \(destination.path)"); fflush(stdout)
        app.exportJob.start(video: video, background: nil, rows: app.project.subtitles, voice: voice,
            audioMode: .translated, subtitleMode: .bilingual, destination: destination, skipped: 0)
        let deadline = Date().addingTimeInterval(180)
        while app.exportJob.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        if app.exportJob.isRunning { app.exportJob.cancel(); XCTFail("Sample export timed out") }
        XCTAssertNil(app.exportJob.error)
        XCTAssertEqual(app.exportJob.outputURL, destination)
        let exported = AVURLAsset(url: destination)
        let exportedDuration = try await exported.load(.duration)
        let sourceDuration = try await AVURLAsset(url: video).load(.duration)
        XCTAssertEqual(exportedDuration.seconds, sourceDuration.seconds, accuracy: 0.1)
        let audioTracks = try await exported.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty)
        try SRTExporter().saveToFile(items: app.project.subtitles, to: folder.appendingPathComponent("cluster-subtitles.srt"))
        try ProjectStore.write(documentData: app.project.encodeDocument(), to: folder.appendingPathComponent("ClusterPreview.vatproject"))
        try JSONSerialization.data(withJSONObject: ["rows": report, "playable": 25, "fastestRate": fastest,
            "exportDuration": exportedDuration.seconds], options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("after.json"))
        print("REAL SAMPLE PASSED: 25/25 playable, peak rate \(fastest), export \(exportedDuration.seconds)s"); fflush(stdout)
        app.player.pause()
        app.clearRecoveryCheckpoint()
    }
}
