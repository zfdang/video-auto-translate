import XCTest
import AVFoundation
@testable import VideoAutoTranslateCore
@testable import VideoAutoTranslateApp

@MainActor final class DubbingPersistenceTests: XCTestCase {
    func testReopeningKeepsPlayableDubbingAndItsSpeedWarning() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let snippet = folder.appendingPathComponent("speech.wav")
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let audio = try AVAudioFile(forWriting: snippet, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            buffer.frameLength = 1600
            for i in 0..<1600 { buffer.floatChannelData![0][i] = 0.2 * sin(Float(i) * 0.1) }
            try audio.write(from: buffer)
        }
        let row = SubtitleItem(startTime: .zero, endTime: .from(seconds: 0.1), originalText: "Hello", translatedText: "你好", dubbedAudioURL: snippet, dubbedRate: 1.7)
        let app = AppState(probeServices: false)
        let voice = app.project.effectiveVoiceCode
        row.dubbedAudioSignature = row.audioSignature(voice: voice)
        app.project.subtitles = [row]
        let project = folder.appendingPathComponent("Saved.vatproject")
        try app.saveProject(to: project)
        try FileManager.default.removeItem(at: snippet)
        try app.loadProject(from: project)
        let restored = try XCTUnwrap(app.project.subtitles.first)
        XCTAssertNil(restored.naturalSpeech)
        XCTAssertEqual(restored.dubbedRate, 1.7)
        XCTAssertEqual(restored.dubbingSpeedDisplay, "1.7倍速")
        XCTAssertEqual(restored.dubbingTimingIssue, row.dubbingTimingIssue)
        XCTAssertTrue(restored.hasCurrentAudio(voice: voice))
        let asset = AVURLAsset(url: try XCTUnwrap(restored.dubbedAudioURL))
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
    }

    func testOldDocumentsWithoutSpeedStillOpen() throws {
        let row = SubtitleItem(startTime: .zero, endTime: .from(seconds: 1), originalText: "Hello", dubbedRate: 1.7)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        json.removeValue(forKey: "dubbedRate")
        let restored = try JSONDecoder().decode(SubtitleItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.dubbedRate)
        XCTAssertNil(restored.dubbingSpeedDisplay)
    }
}
