import Foundation
import AVFoundation

public enum AudioMixerError: LocalizedError {
    case exportFailed(String)
    case cannotCreateComposition

    public var errorDescription: String? {
        switch self {
        case .exportFailed(let msg):
            return "混音导出失败: \(msg)"
        case .cannotCreateComposition:
            return "无法创建音频工程"
        }
    }
}

/// 纯原生多轨配音与背景音闪避（Audio Ducking）混音器
public final class AudioMixer {
    public init() {}

    /// 将所有字幕对应的配音片段按时间戳合成完整配音轨，并与原背景音执行闪避混音
    /// - Parameters:
    ///   - backgroundAudioURL: 提取的背景音乐轨（或原音频轨）
    ///   - items: 含有配音片段 URL 的字幕列表
    ///   - outputURL: 输出混音音频路径 (.m4a)
    ///   - duckingVolume: 配音说话时背景音衰减的目标音量（默认 0.35，即压低65%）
    public func mix(
        backgroundAudioURL: URL?,
        subtitles: [SubtitleItem],
        to outputURL: URL,
        duckingVolume: Float = 0.35
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)

        let composition = AVMutableComposition()

        // 1. 配音音轨
        guard let voiceTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioMixerError.cannotCreateComposition
        }

        // 记录所有配音说话的区间，用于背景音闪避
        var speechIntervals: [CMTimeRange] = []

        for item in subtitles {
            guard let snippetURL = item.dubbedAudioURL,
                  FileManager.default.fileExists(atPath: snippetURL.path) else {
                continue
            }

            let snippetAsset = AVURLAsset(url: snippetURL)
            guard let snippetAudioTrack = try await snippetAsset.loadTracks(withMediaType: .audio).first else {
                continue
            }

            let snippetDuration = try await snippetAsset.load(.duration)
            // 说话时长不应超过字幕结束时间
            let actualDuration = min(snippetDuration, item.duration)
            let snippetRange = CMTimeRange(start: .zero, duration: actualDuration)

            do {
                try voiceTrack.insertTimeRange(
                    snippetRange,
                    of: snippetAudioTrack,
                    at: item.startTime
                )
                speechIntervals.append(CMTimeRange(start: item.startTime, duration: actualDuration))
            } catch {
                print("插入配音切片失败 [\(item.originalText)]: \(error)")
            }
        }

        // 2. 背景音轨与闪避混音参数
        var audioMix: AVMutableAudioMix? = nil

        if let bgURL = backgroundAudioURL, FileManager.default.fileExists(atPath: bgURL.path) {
            let bgAsset = AVURLAsset(url: bgURL)
            if let bgSourceTrack = try await bgAsset.loadTracks(withMediaType: .audio).first {
                guard let bgCompositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    throw AudioMixerError.cannotCreateComposition
                }

                let bgDuration = try await bgAsset.load(.duration)
                try bgCompositionTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: bgDuration),
                    of: bgSourceTrack,
                    at: .zero
                )

                // 设置背景音闪避曲线
                let bgMixParams = AVMutableAudioMixInputParameters(track: bgCompositionTrack)
                bgMixParams.setVolume(1.0, at: .zero)

                let rampDuration = CMTime(value: 150, timescale: 1000) // 150ms 平滑过渡

                for interval in speechIntervals {
                    let duckStart = interval.start
                    let duckEnd = CMTimeAdd(interval.start, interval.duration)

                    // 说话开始前 150ms 开始下潜到目标音量
                    let rampDownStart = max(.zero, CMTimeSubtract(duckStart, rampDuration))
                    bgMixParams.setVolumeRamp(
                        fromStartVolume: 1.0,
                        toEndVolume: duckingVolume,
                        timeRange: CMTimeRange(start: rampDownStart, duration: rampDuration)
                    )

                    // 说话结束时 150ms 平滑回升到原音量
                    bgMixParams.setVolumeRamp(
                        fromStartVolume: duckingVolume,
                        toEndVolume: 1.0,
                        timeRange: CMTimeRange(start: duckEnd, duration: rampDuration)
                    )
                }

                let mutableAudioMix = AVMutableAudioMix()
                mutableAudioMix.inputParameters = [bgMixParams]
                audioMix = mutableAudioMix
            }
        }

        // 3. 导出成片音频
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioMixerError.exportFailed("无法创建导出任务")
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        if let audioMix = audioMix {
            exportSession.audioMix = audioMix
        }

        await exportSession.export()

        if exportSession.status != .completed {
            throw AudioMixerError.exportFailed(exportSession.error?.localizedDescription ?? "导出未知错误")
        }
    }
}
