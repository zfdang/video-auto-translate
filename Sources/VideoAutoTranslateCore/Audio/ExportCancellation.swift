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
