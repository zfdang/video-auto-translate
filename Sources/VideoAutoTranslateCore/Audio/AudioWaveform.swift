import Foundation
import AVFoundation

public enum AudioWaveform {
    /// A bounded envelope; the original audio is streamed rather than retained in memory.
    public static func load(url: URL, bins: Int = 800, range: ClosedRange<Double>? = nil) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let mediaDuration = try await asset.load(.duration).seconds
        guard mediaDuration.isFinite, mediaDuration > 0 else { return [] }
        let lower = max(0, min(mediaDuration, range?.lowerBound ?? 0))
        let upper = max(lower, min(mediaDuration, range?.upperBound ?? mediaDuration))
        let duration = upper - lower
        guard duration > 0 else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .from(seconds: lower), duration: .from(seconds: duration))
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var peaks = [Float](repeating: 0, count: max(1, bins))
        var sampleIndex = 0
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMBlockBufferGetDataLength(block)
            guard count >= 4 else { continue }
            var data = Data(count: count)
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }
            data.withUnsafeBytes { bytes in
                for offset in stride(from: 0, to: count - 3, by: 4) {
                    let value = abs(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self))
                    let bin = min(peaks.count - 1, Int(Double(sampleIndex) / (duration * 8000) * Double(peaks.count)))
                    if value.isFinite { peaks[bin] = max(peaks[bin], min(1, value)) }
                    sampleIndex += 1
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return peaks
    }
}
