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
}
