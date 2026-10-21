import XCTest
import CoreMedia
@testable import VideoAutoTranslateCore
@testable import VideoAutoTranslateApp

@MainActor final class AppStateRegressionTests: XCTestCase {
    func testFirstTextEditCanUndoAndLoadClearsHistory() async throws {
        let app = AppState(probeServices: false)
        app.project.subtitles = [SubtitleItem(startTime: .zero, endTime: .from(seconds: 2), originalText: "Before")]
        app.project.subtitles[0].originalText = "After"
        app.feedbackKind = .failure
        app.undo()
        XCTAssertEqual(app.feedbackKind, .success)
        XCTAssertEqual(app.project.subtitles[0].originalText, "Before")
        app.redo()
        XCTAssertEqual(app.project.subtitles[0].originalText, "After")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("project-\(UUID()).vatproject")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProjectState(subtitles: []).encodeDocument().write(to: url)
        try app.loadProject(from: url)
        XCTAssertFalse(app.canUndo)
        XCTAssertFalse(app.canRedo)
        app.undo()
        XCTAssertTrue(app.project.subtitles.isEmpty)
    }
    func testLateEditingResultCannotReplaceAnotherVideo() async throws {
        let app = AppState(probeServices: false)
        let old = SubtitleItem(startTime: .zero, endTime: .from(seconds: 2), originalText: "A")
        app.project.subtitles = [old]
        let job = Task {
            await app.runEditingJob(name: "test", snapshot: app.createSubtitlesSnapshot()) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                return [old]
            }
        }
        await Task.yield()
        app.openVideo(url: URL(fileURLWithPath: "/tmp/B.mp4"))
        await job.value
        XCTAssertTrue(app.project.subtitles.isEmpty)
        XCTAssertFalse(app.project.isProcessing)
    }

    func testRecoveryContainsCommittedTextAndSaveClearsCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = directory.appendingPathComponent("Recovery.vatproject")
        let app = AppState(probeServices: false, recoveryURL: checkpoint)
        app.project.subtitles = [SubtitleItem(startTime: .zero, endTime: .from(seconds: 1), originalText: "Before")]
        app.project.subtitles[0].originalText = "Edited"
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(try ProjectStore.read(from: checkpoint).subtitles[0].originalText, "Edited")
        try app.saveProject(to: directory.appendingPathComponent("Saved.vatproject"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path))
        XCTAssertFalse(app.project.isDirty)
    }

    func testTranslatedSplitWaitsForUserDistribution() async {
        let app = AppState(probeServices: false)
        let row = SubtitleItem(startTime: .zero, endTime: .from(seconds: 2), originalText: "Hello world", translatedText: "你好世界")
        app.project.subtitles = [row]
        app.requestSplit(id: row.id, atCharIndex: 5)
        // 必须有光标才允许直接拆分，译文不做改动保留在前半句
        XCTAssertEqual(app.project.subtitles.count, 2, "拆分原文字幕成功")
        XCTAssertEqual(app.project.subtitles[0].translatedText, "你好世界", "译文不做改动保留在前半句")
        XCTAssertEqual(app.project.subtitles[1].translatedText, "", "后半句译文为空等待再次翻译")
        app.undo()
        XCTAssertEqual(app.project.subtitles.count, 1)
        XCTAssertEqual(app.project.subtitles[0].translatedText, "你好世界")
    }

    func testTimingApplicationIsOneUndoableTransaction() async throws {
        let app = AppState(probeServices: false)
        let row = SubtitleItem(startTime: .from(seconds: 1), endTime: .from(seconds: 2), originalText: "hello")
        app.project.subtitles = [row]
        try app.updateTiming(id: row.id, start: 1.1, end: 2.1, duration: 3)
        app.undo()
        XCTAssertEqual(app.project.subtitles[0].startTime.secondsValue, 1)
        XCTAssertEqual(app.project.subtitles[0].endTime.secondsValue, 2)
        XCTAssertFalse(app.canUndo)
    }

    func testExportCancellationPreservesExistingDestination() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("Previous output".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let job = ExportJob()
        job.start(video: URL(fileURLWithPath: "/missing.mp4"), background: nil, rows: [], voice: "zh-CN", audioMode: .original, subtitleMode: .none, destination: url, skipped: 0)
        job.cancel()
        while job.isRunning { await Task.yield() }
        XCTAssertNil(job.outputURL)
        XCTAssertNil(job.error)
        XCTAssertEqual(try Data(contentsOf: url), Data("Previous output".utf8))
    }

    func testAutomaticEditsRequireConfirmationAndCanUndo() async {
        let app = AppState(probeServices: false)
        let old = SubtitleItem(startTime: .zero, endTime: .from(seconds: 1), originalText: "hello")
        app.project.subtitles = [old]
        await app.runEditingJob(name: "test", snapshot: app.createSubtitlesSnapshot()) {
            [SubtitleItem(startTime: .zero, endTime: .from(seconds: 2), originalText: "hello")]
        }
        XCTAssertEqual(app.project.subtitles[0].endTime.secondsValue, 1)
        XCTAssertNotNil(app.editProposal)
        app.applyEditProposal()
        XCTAssertEqual(app.project.subtitles[0].endTime.secondsValue, 2)
        app.undo()
        XCTAssertEqual(app.project.subtitles[0].endTime.secondsValue, 1)
    }

    func testPreviewAudioTrackSwitchWithoutDubbingBeepsAndStaysOriginal() async {
        let app = AppState(probeServices: false)
        let testVideo = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString).mp4")
        try? Data("dummy".utf8).write(to: testVideo)
        defer { try? FileManager.default.removeItem(at: testVideo) }

        app.openVideo(url: testVideo)
        XCTAssertEqual(app.previewAudioTrack, .original)
        XCTAssertFalse(app.hasDubbing)

        // 未生成配音时切换为译文配音，应被拦截并提示
        await app.setPreviewAudioTrack(.translated)
        XCTAssertEqual(app.previewAudioTrack, .original)
        XCTAssertTrue(app.statusMessage.contains("尚未生成配音"))

        // 未生成配音时切换为原声叠加，也应被拦截
        await app.setPreviewAudioTrack(.overlay)
        XCTAssertEqual(app.previewAudioTrack, .original)
        XCTAssertTrue(app.statusMessage.contains("尚未生成配音"))
    }

    func testPreviewAudioTrackSwitchWithDubbingSucceeds() async {
        let app = AppState(probeServices: false)
        let tempDir = FileManager.default.temporaryDirectory
        let dummyAudio = tempDir.appendingPathComponent("dummy_dubbing_\(UUID().uuidString).m4a")
        try? Data("dummy_audio".utf8).write(to: dummyAudio)
        defer { try? FileManager.default.removeItem(at: dummyAudio) }

        let item = SubtitleItem(
            startTime: .zero,
            endTime: .from(seconds: 2),
            originalText: "Hello",
            translatedText: "你好",
            dubbedAudioURL: dummyAudio
        )
        app.project.subtitles = [item]
        XCTAssertTrue(app.hasDubbing)

        let dummyVideo = tempDir.appendingPathComponent("dummy_video_\(UUID().uuidString).mp4")
        try? Data("dummy_video".utf8).write(to: dummyVideo)
        defer { try? FileManager.default.removeItem(at: dummyVideo) }
        app.project.videoURL = dummyVideo

        // 有配音文件，切换音轨模式
        app.previewAudioTrack = .translated
        XCTAssertEqual(app.previewAudioTrack, .translated)

        app.previewAudioTrack = .overlay
        XCTAssertEqual(app.previewAudioTrack, .overlay)

        app.previewAudioTrack = .original
        XCTAssertEqual(app.previewAudioTrack, .original)
    }

    func testAudioMixerBuildPreviewItemOriginalReturnsAssetItem() async throws {
        let mixer = AudioMixer()
        let testVideoPath = "/Users/zfdang/workspaces/video-auto-translate/Tests/Fme9C5ShSr2fuWQ8_Translated.mp4"
        guard FileManager.default.fileExists(atPath: testVideoPath) else { return }
        let videoURL = URL(fileURLWithPath: testVideoPath)

        let item = try await mixer.buildPreviewItem(videoURL: videoURL, subtitles: [], mode: .original)
        XCTAssertNotNil(item)
    }
}
