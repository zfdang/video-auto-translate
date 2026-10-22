import XCTest
@testable import VideoAutoTranslateCore

final class SidecarStartupTests: XCTestCase {
    func testTTSStartsSidecarBeforeRequestAndHonorsCancellation() async throws {
        var starts = 0
        let service = EdgeTTSService(ensureSidecar: {
            starts += 1
            withUnsafeCurrentTask { $0?.cancel() }
            return false
        })
        let worker = Task {
            try await service.synthesize(text: "hello", outputURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        }
        do {
            _ = try await worker.value
            XCTFail("Expected cancellation before HTTP or fallback")
        } catch is CancellationError { }
        XCTAssertEqual(starts, 1)
    }
}
