import XCTest
import CoreMedia
@testable import VideoAutoTranslateCore

final class FillerAlignmentTests: XCTestCase {
    func testOmittedFillersPreserveEveryPhysicalTokenAndLLMBoundaries() {
        let tokens = ["Um", "Hello", "uh", "world", "呃", "Next", "line"].enumerated().map {
            WordToken(text: $0.element, startTime: .from(seconds: Double($0.offset)), endTime: .from(seconds: Double($0.offset + 1)))
        }
        let result = LLMSegmenter().alignLinesToTokens(lines: ["Hello world", "Next line"], tokens: tokens)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].words.map(\.text), ["Um", "Hello", "uh", "world"])
        XCTAssertEqual(result[1].words.map(\.text), ["呃", "Next", "line"])
        XCTAssertEqual(result.flatMap(\.words).map(\.text), tokens.map(\.text))
        XCTAssertEqual(result.last?.endTime.seconds, 7)
    }

    func testMeaningfulOmissionsStillRejectLLMBoundaries() {
        let tokens = ["Hello", "brave", "world"].enumerated().map {
            WordToken(text: $0.element, startTime: .from(seconds: Double($0.offset)), endTime: .from(seconds: Double($0.offset + 1)))
        }
        let result = LLMSegmenter().alignLinesToTokens(lines: ["Hello world"], tokens: tokens)
        XCTAssertEqual(result.flatMap(\.words).map(\.text), tokens.map(\.text))
    }
}
