import XCTest
import AVFoundation
import Combine
@testable import VideoAutoTranslateCore
@testable import VideoAutoTranslateApp

@MainActor final class ExportProgressTests: XCTestCase {
    func testRenderingReportsIntermediateProgressAndCompletesAfterSaving() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280, AVVideoHeightKey: 720
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 1280, kCVPixelBufferHeightKey as String: 720
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32ARGB, nil, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 0, CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        for frame in 0..<600 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(adaptor.append(image, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)

        // Exercise both rendering paths, including the subtitle animation tool.
        for mode in [SubtitleExportMode.none, .originalOnly] {
            let destination = folder.appendingPathComponent("\(mode.rawValue).mp4")
            let job = ExportJob()
            var values: [Double] = []
            let observation = job.$progress.sink { value in
                values.append(value)
                if value == 1 {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
                }
            }
            let row = SubtitleItem(startTime: .zero, endTime: .from(seconds: 20), originalText: "Progress regression")
            job.start(video: source, rows: [row], voice: "zh-CN", audioMode: .original,
                      subtitleMode: mode, destination: destination, skipped: 0)
            while job.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertNil(job.error)
            XCTAssertEqual(job.outputURL, destination)
            XCTAssertEqual(values.first, 0)
            XCTAssertEqual(values.last, 1)
            if mode != .none {
                XCTAssertTrue(values.contains { $0 > 0 && $0 < 0.99 }, "Subtitle rendering must publish native intermediate progress: \(values)")
            }
            XCTAssertEqual(values.dropFirst().first, 0, "Rendering must start at zero instead of jumping to 75%")
            XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
            let count = values.count
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(values.count, count, "Polling must stop after completion")
            withExtendedLifetime(observation) {}
        }

        let destination = folder.appendingPathComponent("cancelled.mp4")
        let previousOutput = Data("Previous output".utf8)
        try previousOutput.write(to: destination)
        let cancelledJob = ExportJob()
        var cancelledValues: [Double] = []
        let observation = cancelledJob.$progress.sink { value in
            cancelledValues.append(value)
            if value > 0 && value < 0.99 { cancelledJob.cancel() }
        }
        let row = SubtitleItem(startTime: .zero, endTime: .from(seconds: 20), originalText: "Cancel during rendering")
        cancelledJob.start(video: source, rows: [row], voice: "zh-CN", audioMode: .original,
                           subtitleMode: .originalOnly, destination: destination, skipped: 0)
        while cancelledJob.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(cancelledJob.error)
        XCTAssertNil(cancelledJob.outputURL)
        XCTAssertEqual(cancelledJob.message, "导出已取消")
        XCTAssertEqual(try Data(contentsOf: destination), previousOutput)
        XCTAssertFalse(cancelledValues.contains(1))
        let count = cancelledValues.count
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(cancelledValues.count, count, "Polling must stop after cancellation")
        withExtendedLifetime(observation) {}
    }
}
