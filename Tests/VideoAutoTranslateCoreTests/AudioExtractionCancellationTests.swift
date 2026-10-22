import XCTest
import AVFoundation
@testable import VideoAutoTranslateCore

final class AudioExtractionCancellationTests: XCTestCase {
    func testExtractionCompletesWithExpectedPCMFormat() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.wav"), destination = dir.appendingPathComponent("output.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
            buffer.frameLength = 16000
            memset(buffer.floatChannelData![0], 0, 16000 * MemoryLayout<Float>.size)
            try file.write(from: buffer)
        }
        try await AudioExtractor().extract16kMonoWav(from: source, to: destination)
        let result = try AVAudioFile(forReading: destination)
        XCTAssertEqual(result.length, 16000)
        XCTAssertEqual(result.fileFormat.sampleRate, 16000)
        XCTAssertEqual(result.fileFormat.channelCount, 1)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["source.wav", "output.wav"])
    }

    func testCancelExtractionPreservesDestinationAndRemovesTemporaryFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.wav"), destination = dir.appendingPathComponent("output.wav")
        let sentinel = Data("existing output".utf8)
        try sentinel.write(to: destination)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
            buffer.frameLength = 16000
            memset(buffer.floatChannelData![0], 0, 16000 * MemoryLayout<Float>.size)
            for _ in 0..<600 { try file.write(from: buffer) }
        }
        let worker = Task {
            try await AudioExtractor().extract16kMonoWav(from: source, to: destination)
        }
        // Wait until the extraction has created its staging file before cancelling.
        var sawTemporaryFile = false
        for _ in 0..<1000 {
            if try FileManager.default.contentsOfDirectory(atPath: dir.path).contains(where: { $0.hasSuffix(".tmp") }) {
                sawTemporaryFile = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(sawTemporaryFile)
        worker.cancel()
        do {
            try await worker.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["source.wav", "output.wav"])
    }
}
