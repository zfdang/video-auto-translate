import XCTest
@testable import VideoAutoTranslateCore

final class StructuralReviewStateTests: XCTestCase {
    func testSplitPreservesReviewForTheRetainedTranslation() throws {
        let row = SubtitleItem(startTime: .zero, endTime: .from(seconds: 2), originalText: "Hello world", translatedText: "你好世界", translationNeedsReview: true)
        let (left, right) = try XCTUnwrap(SubtitleManager().split(item: row, atCharIndex: 5))
        XCTAssertEqual(left.translatedText, "你好世界")
        XCTAssertTrue(left.translationNeedsReview)
        XCTAssertTrue(right.translatedText.isEmpty)
        XCTAssertFalse(right.translationNeedsReview)
        let distributed = try XCTUnwrap(SubtitleManager().split(item: row, atCharIndex: 5, translatedParts: ("你好", "世界")))
        XCTAssertTrue(distributed.0.translationNeedsReview)
        XCTAssertTrue(distributed.1.translationNeedsReview)
    }

    func testMergeKeepsUnconfirmedAndIncompleteTranslationsPending() throws {
        let first = SubtitleItem(startTime: .zero, endTime: .from(seconds: 1), originalText: "Hello", translatedText: "你好")
        let second = SubtitleItem(startTime: .from(seconds: 1), endTime: .from(seconds: 2), originalText: "world", translatedText: "世界", translationNeedsReview: true)
        let manager = SubtitleManager()
        XCTAssertTrue(try XCTUnwrap(manager.merge(items: [first, second])).translationNeedsReview)
        second.confirmTranslation()
        XCTAssertFalse(try XCTUnwrap(manager.merge(items: [first, second])).translationNeedsReview)
        second.translatedText = ""
        XCTAssertTrue(try XCTUnwrap(manager.merge(items: [first, second])).translationNeedsReview)
        first.translatedText = ""
        XCTAssertFalse(try XCTUnwrap(manager.merge(items: [first, second])).translationNeedsReview)
    }
}
