import XCTest
@testable import VideoAutoTranslateCore

final class MultipartUploadTests: XCTestCase {
    func testMultipartPreservesAudioAcrossChunkBoundariesAndFields() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("sample.wav"), body = dir.appendingPathComponent("body")
        let data = Data((0..<150_000).map { UInt8($0 % 256) })
        try data.write(to: audio)
        try LocalASRService.writeMultipartBody(audioURL: audio, to: body, boundary: "test-boundary", model: "model", language: "zh")
        let result = try Data(contentsOf: body)
        let audioRange = try XCTUnwrap(result.range(of: data))
        let header = String(decoding: result[..<audioRange.lowerBound], as: UTF8.self)
        XCTAssertTrue(header.contains("name=\"model\"\r\n\r\nmodel\r\n"))
        XCTAssertTrue(header.contains("name=\"language\"\r\n\r\nzh\r\n"))
        XCTAssertTrue(header.contains("name=\"timestamp_granularities[]\"\r\n\r\nword\r\n"))
        XCTAssertEqual(String(decoding: result[audioRange.upperBound...], as: UTF8.self), "\r\n--test-boundary--\r\n")
    }
}
