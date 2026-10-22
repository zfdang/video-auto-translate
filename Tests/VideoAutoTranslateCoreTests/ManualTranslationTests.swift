import XCTest
import AVFoundation
@testable import VideoAutoTranslateCore
@testable import VideoAutoTranslateApp

@MainActor final class ManualTranslationTests: XCTestCase {
    func testCorrectedTranslationCanBeDubbedExportedAndReopened() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = AppState(probeServices: false)
        let row = SubtitleItem(startTime: .zero, endTime: .from(seconds: 1), originalText: "Helo", translatedText: "旧译文")
        app.project.subtitles = [row]
        row.originalText = "Hello"
        XCTAssertTrue(row.translationNeedsReview)
        row.translatedText = "你好"
        XCTAssertFalse(row.translationNeedsReview)
        try await SubtitleManager().reDub(item: row, ttsService: ManualTranslationTTS(), voice: "zh-CN")
        let audio = try XCTUnwrap(row.dubbedAudioURL)
        defer { try? FileManager.default.removeItem(at: audio) }
        XCTAssertTrue(row.hasCurrentAudio(voice: "zh-CN"))
        let captions = folder.appendingPathComponent("corrected.srt")
        try SRTExporter().saveToFile(items: [row], to: captions)
        XCTAssertTrue(try String(contentsOf: captions).contains("你好\nHello"))
        let project = folder.appendingPathComponent("corrected.vatproject")
        try app.saveProject(to: project)
        try app.loadProject(from: project)
        XCTAssertEqual(app.project.subtitles.first?.translatedText, "你好")
        XCTAssertEqual(app.project.subtitles.first?.translationNeedsReview, false)
        XCTAssertTrue(app.project.subtitles[0].hasCurrentAudio(voice: "zh-CN"))
    }

    func testUserCanConfirmAnUnchangedTranslation() {
        let row = SubtitleItem(startTime: .zero, endTime: .from(seconds: 1), originalText: "Helo", translatedText: "你好")
        row.originalText = "Hello"
        row.confirmTranslation()
        XCTAssertFalse(row.translationNeedsReview)
        XCTAssertEqual(row.translatedText, "你好")
        row.translatedText = " "
        row.translationNeedsReview = true
        row.confirmTranslation()
        XCTAssertTrue(row.translationNeedsReview)
    }
}

private struct ManualTranslationTTS: TTSServiceProtocol {
    func synthesize(text: String, voice: String, outputURL: URL) async throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let file = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3200)!
        buffer.frameLength = 3200
        for frame in 0..<3200 { buffer.floatChannelData![0][frame] = 0.2 * sin(Float(frame) * 0.1) }
        try file.write(from: buffer)
        return outputURL
    }
}
