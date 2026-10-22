import XCTest
import CoreMedia
@testable import VideoAutoTranslateCore

final class TimelineDriftTests: XCTestCase {
    func testPacketDriftClampsEndWithoutChangingSourceAnchor() {
        let row = SubtitleItem(startTime: .from(seconds: 1), endTime: .from(seconds: 2.03), originalText: "hello", translatedText: "你好")
        let result = TimelineAligner().matchTimelineToTranslation(items: [row], videoDuration: 2)
        XCTAssertEqual(result[0].endTime.seconds, 2, accuracy: 0.001)
        XCTAssertEqual(result[0].sourceEndTime, row.sourceEndTime)
        XCTAssertEqual(row.endTime.seconds, 2.03, accuracy: 0.001)
    }

    func testLargeOverflowAndRowsBeyondVideoRemainRejected() {
        for (start, end) in [(1.0, 3.0), (2.1, 2.3), (1.95, 2.03)] {
            let row = SubtitleItem(startTime: .from(seconds: start), endTime: .from(seconds: end), originalText: "hello")
            let result = TimelineAligner().matchTimelineToTranslation(items: [row], videoDuration: 2)
            XCTAssertTrue(result[0] === row)
        }
    }
}
