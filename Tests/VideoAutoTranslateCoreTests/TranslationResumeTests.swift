import XCTest
import CoreMedia
@testable import VideoAutoTranslateCore

final class TranslationResumeTests: XCTestCase {
    func testBatchRetriesExactlyOnce() async throws {
        var attempts = 0
        try await SubtitleTranslator.retryBatch {
            attempts += 1
            if attempts == 1 { throw LLMError.invalidResponseFormat }
        }
        XCTAssertEqual(attempts, 2)
        attempts = 0
        do {
            try await SubtitleTranslator.retryBatch {
                attempts += 1
                throw LLMError.invalidResponseFormat
            }
            XCTFail("Expected second failure")
        } catch { XCTAssertEqual(attempts, 2) }
    }

    func testCancellationNeverRetries() async {
        var attempts = 0
        do {
            try await SubtitleTranslator.retryBatch {
                attempts += 1
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(attempts, 1)
    }

    func testExistingTranslationsSkipModelAndNetwork() async throws {
        let row = SubtitleItem(startTime: .zero, endTime: .from(seconds: 1), originalText: "Hello", translatedText: "你好")
        var config = LLMConfiguration()
        config.providerType = .onlineCustom
        config.onlineBaseURL = "http://127.0.0.1:9"
        var progressCalls = 0
        try await SubtitleTranslator().translate(items: [row], config: config) { _, _ in progressCalls += 1 }
        XCTAssertEqual(row.translatedText, "你好")
        XCTAssertEqual(progressCalls, 0)
    }
}
