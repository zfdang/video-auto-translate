import XCTest
@testable import VideoAutoTranslateCore
@testable import VideoAutoTranslateApp

@MainActor final class ExportReviewTests: XCTestCase {
    func testSubtitleAndVideoExportsBothRequireTranslationConfirmation() async throws {
        let row = SubtitleItem(startTime: .zero, endTime: .from(seconds: 1), originalText: "Hello", translatedText: "你好", translationNeedsReview: true)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        XCTAssertThrowsError(try SRTExporter().saveToFile(items: [row], to: destination)) {
            XCTAssertTrue($0.localizedDescription.contains("译文待复核"))
        }
        for (audio, captions) in [(VideoAudioExportMode.original, SubtitleExportMode.bilingual), (.translated, .none)] {
            let job = ExportJob()
            job.start(video: URL(fileURLWithPath: "/missing.mp4"), background: nil, rows: [row], voice: "zh-CN", audioMode: audio, subtitleMode: captions, destination: destination, skipped: 0)
            while job.isRunning { await Task.yield() }
            XCTAssertTrue(job.error?.contains("第1句：译文待复核") == true)
            XCTAssertNil(job.outputURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
        row.confirmTranslation()
        XCTAssertNoThrow(try SRTExporter().saveToFile(items: [row], to: destination))
    }

    func testOriginalOnlyExportDoesNotRequireUnusedTranslation() async {
        let row = SubtitleItem(startTime: .zero, endTime: .from(seconds: 1), originalText: "Hello", translatedText: "旧译文", translationNeedsReview: true)
        let job = ExportJob()
        job.start(video: URL(fileURLWithPath: "/missing.mp4"), background: nil, rows: [row], voice: "zh-CN", audioMode: .original, subtitleMode: .originalOnly, destination: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), skipped: 0)
        while job.isRunning { await Task.yield() }
        XCTAssertNotNil(job.error, "The missing media should fail after translation validation")
        XCTAssertFalse(job.error?.contains("译文待复核") == true)
    }
}
