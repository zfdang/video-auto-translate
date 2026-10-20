import Foundation
import AVFoundation

public enum VideoComposerError: LocalizedError {
    case noVideoTrack
    case exportFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "源视频中未找到有效视频轨道"
        case .exportFailed(let msg):
            return "成片视频合成导出失败: \(msg)"
        case .cancelled:
            return "导出任务已取消"
        }
    }
}

/// 纯原生多媒体合成与 VideoToolbox 硬件硬编导出器
public final class VideoComposer {
    public init() {}

    /// 合成原视频画面轨与全新配音音频轨为最终 MP4 视频
    /// - Parameters:
    ///   - videoURL: 原视频文件路径
    ///   - newAudioURL: 混音好的新音频文件路径
    ///   - outputURL: 最终导出的 MP4 文件路径
    public func compose(
        videoURL: URL,
        newAudioURL: URL,
        outputURL: URL
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)

        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: newAudioURL)

        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw VideoComposerError.noVideoTrack
        }

        let composition = AVMutableComposition()

        // 1. 插入画面轨
        guard let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoComposerError.exportFailed("无法创建视频轨道")
        }

        let videoDuration = try await videoAsset.load(.duration)
        try compVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoTrack,
            at: .zero
        )

        // 保持视频原始方向变换
        let transform = try await videoTrack.load(.preferredTransform)
        compVideoTrack.preferredTransform = transform

        // 2. 插入新配音轨
        if let newAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first {
            guard let compAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw VideoComposerError.exportFailed("无法创建音频轨道")
            }

            let audioDuration = try await audioAsset.load(.duration)
            let actualAudioDuration = min(videoDuration, audioDuration)
            try compAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: actualAudioDuration),
                of: newAudioTrack,
                at: .zero
            )
        }

        // 3. 利用 Apple VideoToolbox 硬件加速导出 MP4
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw VideoComposerError.exportFailed("无法初始化导出引擎")
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        await exportSession.export()

        if exportSession.status != .completed {
            throw VideoComposerError.exportFailed(exportSession.error?.localizedDescription ?? "未知导出错误")
        }
    }
}
