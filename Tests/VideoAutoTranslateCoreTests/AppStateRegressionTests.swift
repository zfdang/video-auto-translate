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
}
