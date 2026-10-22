import XCTest
@testable import VideoAutoTranslateCore

final class SubtitleAnimationTests: XCTestCase {
    func testClippedKeyTimesAreFiniteOrderedAndBounded() throws {
        for (start, end) in [(-0.1, 1.0), (1.0, 2.03), (0.0, 2.0)] {
            let times = try XCTUnwrap(VideoComposer.subtitleKeyTimes(start: start, end: end, duration: 2))
            XCTAssertEqual(times.count, 6)
            XCTAssertTrue(times.allSatisfy { $0.isFinite && (0...1).contains($0) })
            XCTAssertEqual(times, times.sorted())
        }
    }

    func testInvalidAndInvisibleSubtitlesAreSkipped() {
        for (start, end) in [(3.0, 4.0), (-2.0, -1.0), (1.0, 0.5), (Double.nan, 1.0), (0.0, Double.infinity)] {
            XCTAssertNil(VideoComposer.subtitleKeyTimes(start: start, end: end, duration: 2))
        }
        XCTAssertNil(VideoComposer.subtitleKeyTimes(start: 0, end: 1, duration: 0))
    }
}
