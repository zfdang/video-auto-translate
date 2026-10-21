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
        // 安全检查：严禁输出路径与背景音频或配音片段相同（防符号链接别名覆盖，R01 / FU02）
        if let bgURL = backgroundAudioURL {
            guard !outputURL.pointsToSameFile(as: bgURL) else {
                throw AudioMixerError.exportFailed("输出文件路径不能与背景音频输入路径相同")
            }
        }
        for item in subtitles {
            if let snip = item.dubbedAudioURL, outputURL.pointsToSameFile(as: snip) {
                throw AudioMixerError.exportFailed("输出文件路径不能与配音切片路径相同")
            }
        }

        let tempDirectory = outputURL.deletingLastPathComponent()
        let tempFilename = ".\(UUID().uuidString)_\(outputURL.lastPathComponent).tmp"
        let tempOutputURL = tempDirectory.appendingPathComponent(tempFilename)
        try? FileManager.default.removeItem(at: tempOutputURL)

        let composition = AVMutableComposition()

        // 1. 配音音轨池：支持多轨道叠混，防止重叠片段在单轨插入时推移时间轴 (R18)
        var voiceTracks: [AVMutableCompositionTrack] = []
        var trackEndTimes: [CMTime] = []

        func getTrack(for startTime: CMTime) -> AVMutableCompositionTrack? {
            for (idx, endTime) in trackEndTimes.enumerated() {
                if startTime >= endTime {
                    return voiceTracks[idx]
                }
            }
            guard let newTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                return nil
            }
            voiceTracks.append(newTrack)
            trackEndTimes.append(.zero)
            return newTrack
        }

        // 记录所有配音说话的区间，用于背景音闪避
        var speechIntervals: [CMTimeRange] = []

        // 按起始时间排序，确保轨道插入顺序单调递增
        let sortedSubtitles = subtitles.sorted { $0.startTime < $1.startTime }

        for item in sortedSubtitles {
            guard let snippetURL = item.dubbedAudioURL,
                  FileManager.default.fileExists(atPath: snippetURL.path) else {
                continue
            }

            let snippetAsset = AVURLAsset(url: snippetURL)
            guard let snippetAudioTrack = try await snippetAsset.loadTracks(withMediaType: .audio).first else {
                continue
            }

            let snippetDuration = try await snippetAsset.load(.duration)
            // R10: 保留完整发音长度，避免末尾语音被粗暴裁断丢失
            let actualDuration = snippetDuration
            let snippetRange = CMTimeRange(start: .zero, duration: actualDuration)

            guard let targetTrack = getTrack(for: item.startTime) else {
                print("创建配音轨道失败 [\(item.originalText)]")
                continue
            }

            do {
                try targetTrack.insertTimeRange(
                    snippetRange,
                    of: snippetAudioTrack,
                    at: item.startTime
                )
                if let trackIdx = voiceTracks.firstIndex(where: { $0 === targetTrack }) {
                    trackEndTimes[trackIdx] = CMTimeAdd(item.startTime, actualDuration)
                }
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

                // 合并重叠或间隔小于 300ms 的语音区间，生成平滑统一的闪避包络 (R18)
                var mergedIntervals: [CMTimeRange] = []
                let sortedIntervals = speechIntervals.sorted { $0.start < $1.start }
                for interval in sortedIntervals {
                    if let last = mergedIntervals.last {
                        let lastEnd = CMTimeAdd(last.start, last.duration)
                        let gap = CMTimeSubtract(interval.start, lastEnd)
                        if interval.start <= lastEnd || gap.secondsValue <= 0.3 {
                            let newEnd = max(lastEnd, CMTimeAdd(interval.start, interval.duration))
                            mergedIntervals[mergedIntervals.count - 1] = CMTimeRange(
                                start: last.start,
                                duration: CMTimeSubtract(newEnd, last.start)
                            )
                            continue
                        }
                    }
                    mergedIntervals.append(interval)
                }

                for interval in mergedIntervals {
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

        // 3. 导出成片音频 (输出至临时文件，成功后原子替换，R01)
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            try? FileManager.default.removeItem(at: tempOutputURL)
            throw AudioMixerError.exportFailed("无法创建导出任务")
        }

        exportSession.outputURL = tempOutputURL
        exportSession.outputFileType = .m4a
        if let audioMix = audioMix {
            exportSession.audioMix = audioMix
        }

        await exportSession.export()

        if exportSession.status != .completed {
            try? FileManager.default.removeItem(at: tempOutputURL)
            throw AudioMixerError.exportFailed(exportSession.error?.localizedDescription ?? "导出未知错误")
        }

        // 原子替换目标文件
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempOutputURL)
            } else {
                try FileManager.default.moveItem(at: tempOutputURL, to: outputURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempOutputURL)
            throw AudioMixerError.exportFailed("替换混音目标文件失败: \(error.localizedDescription)")
        }
    }
}
