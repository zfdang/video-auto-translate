import XCTest
import CoreMedia
@testable import VideoAutoTranslateCore
@testable import VideoAutoTranslateApp

@MainActor final class AppStateRegressionTests: XCTestCase {
    func testFirstTextEditCanUndoAndLoadClearsHistory() async throws {
        let app = AppState(probeServices: false)
        app.project.subtitles = [SubtitleItem(startTime: .zero, endTime: .from(seconds: 2), originalText: "Before")]
        app.project.subtitles[0].originalText = "After"
        app.undo()
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
        XCTAssertEqual(app.project.subtitles.count, 1)
        XCTAssertNotNil(app.splitDraft)
        app.applySplitDraft(left: "你好", right: "世界")
        XCTAssertEqual(app.project.subtitles.map(\.translatedText), ["你好", "世界"])
        app.undo()
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

}
