import Foundation
import AVFoundation

public enum DubbingTimingError: LocalizedError {
    case requiresTimelineMatch(natural: Double, available: Double)
    case invalidDuration
    case insufficientTime(natural: Double, available: Double)

    public var errorDescription: String? {
        switch self {
        case .requiresTimelineMatch(let natural, let available):
            return String(format: "正常配音需 %.2f 秒，当前仅 %.2f 秒；请先使用「匹配译文时间轴」确认语速和时间安排，再生成配音。", natural, available)
        case .invalidDuration:
            return "配音或字幕时长无效，请重新匹配时间轴。"
        case .insufficientTime(let natural, let available):
            return String(format: "正常配音需 %.2f 秒，当前仅 %.2f 秒；超过 1.15 倍温和调速范围，请精简译文或手动调时。", natural, available)
        }
    }
}

public enum DubbingPacing {
    public static let maximumRate = 1.15
    public static let timeTolerance = 0.005

    /// Never slow a short utterance to fill its subtitle interval.
    public static func rate(naturalDuration: Double, availableDuration: Double) throws -> Double {
        guard naturalDuration.isFinite, availableDuration.isFinite,
              naturalDuration > 0, availableDuration > 0 else {
            throw DubbingTimingError.invalidDuration
        }
        let required = naturalDuration / availableDuration
        guard naturalDuration <= availableDuration * maximumRate + timeTolerance else {
            throw DubbingTimingError.insufficientTime(natural: naturalDuration, available: availableDuration)
        }
        return min(maximumRate, max(1, required))
    }
}

/// Session-only, immutable normal-speed audio. Snapshots share ownership; the
/// temporary file is released when the last proposal/undo/project reference ends.
public final class NaturalSpeechAudio {
    public let url: URL
    public let duration: Double
    public let text: String
    public let voice: String

    init(url: URL, duration: Double, text: String, voice: String) {
        self.url = url
        self.duration = duration
        self.text = text
        self.voice = voice
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// Trims only near-silent edges, preserving 40ms padding and every internal
    /// pause. Reads in 10ms blocks instead of loading an entire utterance in memory.
    static func trimEdges(inputURL: URL, outputURL: URL) throws -> Double {
        let input = try AVAudioFile(forReading: inputURL)
        let format = input.processingFormat
        let framesPerBlock = AVAudioFrameCount(max(1, Int(format.sampleRate * 0.01)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBlock) else {
            throw TTSError.synthesisFailed("无法读取正常语速音频。")
        }
        var first: AVAudioFramePosition?
        var last: AVAudioFramePosition = 0
        while input.framePosition < input.length {
            try Task.checkCancellation()
            let position = input.framePosition
            try input.read(into: buffer, frameCount: framesPerBlock)
            guard buffer.frameLength > 0 else { break }
            guard let channels = buffer.floatChannelData else {
                throw TTSError.synthesisFailed("配音音频格式不支持时长检测。")
            }
            var peak: Float = 0
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[channel][frame])) }
            }
            if peak > 0.001 {
                if first == nil { first = position }
                last = position + AVAudioFramePosition(buffer.frameLength)
            }
        }
        guard let first else { throw TTSError.synthesisFailed("配音仅包含静音，请检查音色后重试。") }
        let padding = AVAudioFramePosition(format.sampleRate * 0.04)
        let begin = max(0, first - padding)
        let end = min(input.length, last + padding)
        input.framePosition = begin
        do {
            let output = try AVAudioFile(forWriting: outputURL, settings: format.settings)
            while input.framePosition < end {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(Int64(framesPerBlock), end - input.framePosition))
                try input.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0 else { throw TTSError.synthesisFailed("配音数据不完整。") }
                try output.write(from: buffer)
            }
        }
        return Double(end - begin) / format.sampleRate
    }
}
