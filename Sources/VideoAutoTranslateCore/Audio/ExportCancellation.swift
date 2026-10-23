import AVFoundation
import Foundation

/// Bridges task cancellation to AVFoundation without transferring the mutable
/// export session into a Sendable closure. Configuration remains with its caller;
/// the only concurrent operation is AVFoundation's supported cancelExport().
final class ExportCancellation: @unchecked Sendable {
    private let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) { self.session = session }

    func cancel() { session.cancelExport() }
}

/// Poll the native export session while it runs. Keep callbacks on the UI actor
/// and stop polling before returning, including cancellation and failure paths.
@MainActor
func exportWithProgress(
    _ session: AVAssetExportSession,
    onProgress: @escaping @MainActor (Double) -> Void
) async throws {
    try Task.checkCancellation()
    onProgress(0)
    let monitor = Task { @MainActor in
        var reported = 0.0
        while !Task.isCancelled {
            let value = Double(session.progress)
            if value.isFinite {
                reported = max(reported, min(0.99, max(0, value)))
                onProgress(reported)
            }
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { break }
        }
    }
    defer { monitor.cancel() }
    let cancellation = ExportCancellation(session)
    await withTaskCancellationHandler {
        await session.export()
    } onCancel: { cancellation.cancel() }
    try Task.checkCancellation()
}
