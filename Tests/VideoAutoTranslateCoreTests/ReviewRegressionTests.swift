import XCTest
import CoreMedia
@testable import VideoAutoTranslateCore

final class ReviewRegressionTests: XCTestCase {
    func testTimelineRejectsDuplicateAndMissingIDs() {
        let item = SubtitleItem(startTime: .zero, endTime: .from(seconds: 2), originalText: "hello", translatedText: "你好")
        for response in ["{\"subtitles\":[{\"id\":0,\"start\":0,\"end\":2},{\"id\":0,\"start\":0,\"end\":2}]}", "{\"subtitles\":[]}"] {
            XCTAssertNil(TimelineAligner().parseLLMTimeline(from: response, baseMatched: [item], language: "zh", videoDuration: 3))
        }
    }
    func testFirstWordAndUnicodeSplitBoundaries() {
        let text = "Hello world third fourth"
        let words = text.split(separator: " ").enumerated().map { index, word in
            WordToken(text: String(word), startTime: .from(seconds: Double(index)), endTime: .from(seconds: Double(index) + 0.8))
        }
        let item = SubtitleItem(startTime: .zero, endTime: .from(seconds: 4), originalText: text, words: words)
        let split = SubtitleManager().split(item: item, atCharIndex: 2)
        XCTAssertEqual(split?.0.originalText, "Hello")
        XCTAssertEqual(split?.1.originalText, "world third fourth")
        XCTAssertEqual(SubtitleManager.characterOffset(in: "😀a bc", utf16Offset: 4), 3)
        XCTAssertNil(SubtitleManager.characterOffset(in: "😀a bc", utf16Offset: 1))
    }

    func testCrowdedTimelinePreservesValidInputInsteadOfOverlapping() {
        let rows = (0..<5).map { index in
            SubtitleItem(startTime: .from(seconds: Double(index) * 0.2), endTime: .from(seconds: Double(index) * 0.2 + 0.15), originalText: "row", translatedText: "这是一段很长的翻译结果")
        }
        let result = TimelineAligner().matchTimelineToTranslation(items: rows, videoDuration: 1)
        XCTAssertEqual(result.count, rows.count)
        for i in result.indices {
            XCTAssertLessThanOrEqual(result[i].endTime.secondsValue, 1)
            if i > 0 { XCTAssertGreaterThanOrEqual(result[i].startTime, result[i-1].endTime) }
        }
    }

    func testSegmentationCannotChangeWordsAndSupportsUnspacedText() {
        let tokens = ["Hello", "world"].enumerated().map { i, word in
            WordToken(text: word, startTime: .from(seconds: Double(i)), endTime: .from(seconds: Double(i+1)))
        }
        let segmenter = LLMSegmenter()
        let rejected = segmenter.alignLinesToTokens(lines: ["Goodbye moon"], tokens: tokens)
        XCTAssertEqual(rejected.map(\.originalText).joined(separator: " "), "Hello world")
        let chinese = ["你好", "世界"].enumerated().map { i, word in
            WordToken(text: word, startTime: .from(seconds: Double(i)), endTime: .from(seconds: Double(i+1)))
        }
        let result = segmenter.alignLinesToTokens(lines: ["你好世界"], tokens: chinese)
        XCTAssertEqual(result.first?.words.count, 2)
        XCTAssertEqual(result.first?.endTime.secondsValue, 2)
    }

    func testTranslationSequenceBaseAndCompleteCoverage() throws {
        let rows = ["First", "Second"].map { SubtitleItem(startTime: .zero, endTime: .from(seconds: 1), originalText: $0) }
        let translator = SubtitleTranslator()
        let entries = try translator.parseTranslationEntries(from: "[{\"id\":0,\"translation\":\"A\"},{\"id\":1,\"translation\":\"B\"}]", chunk: rows)
        let valid = try translator.validatedTranslations(entries, for: rows)
        XCTAssertEqual(valid[rows[0].id.uuidString], "A")
        XCTAssertEqual(valid[rows[1].id.uuidString], "B")
        XCTAssertThrowsError(try translator.validatedTranslations(Array(entries.prefix(1)), for: rows))
        XCTAssertThrowsError(try translator.validatedTranslations([entries[0], entries[0]], for: rows))
    }

}
