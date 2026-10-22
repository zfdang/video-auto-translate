import XCTest
import CoreMedia
@testable import VideoAutoTranslateCore

final class ASRWordBoundaryTests: XCTestCase {
    func testSharedWordAnchorsDoNotInventSentenceOverlap() throws {
        // Captured from the real Paris tour: mes/amis share Here's start time.
        let words = [
            ASRWordResponse(word: "way", start: 9.6, end: 10.56),
            ASRWordResponse(word: "mes", start: 10.56, end: 10.56),
            ASRWordResponse(word: "amis", start: 10.56, end: 10.56),
            ASRWordResponse(word: "Here", start: 10.56, end: 10.64),
            ASRWordResponse(word: "Place", start: 10.8, end: 10.96)
        ]
        let tokens = try words.map(LocalASRService.alignedWordToken)
        XCTAssertEqual(tokens.count, 5)
        XCTAssertEqual(tokens[1].durationCMTime.seconds, 0)
        XCTAssertEqual(tokens[2].endCMTime, tokens[3].startCMTime)
        let rows = LLMSegmenter().alignLinesToTokens(lines: ["way mes amis", "Here Place"], tokens: tokens)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].endTime, rows[1].startTime)
        rows.forEach { $0.translatedText = "你好" }
        let result = TimelineAligner().matchTimelineToTranslation(items: rows, videoDuration: 12)
        XCTAssertFalse(result[0] === rows[0], "Valid shared anchors must produce a matching proposal")
    }

    func testShortWordsRetainMeasuredDurationAndInvalidTimesAreRejected() throws {
        let short = try LocalASRService.alignedWordToken(ASRWordResponse(word: "a", start: 1, end: 1.02))
        XCTAssertEqual(short.durationCMTime.seconds, 0.02, accuracy: 0.001)
        for (start, end) in [(-1.0, 1.0), (1.0, 0.5), (Double.nan, 1.0), (0.0, Double.infinity)] {
            XCTAssertThrowsError(try LocalASRService.alignedWordToken(ASRWordResponse(word: "bad", start: start, end: end)))
        }
    }
}
