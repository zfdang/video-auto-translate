import Foundation
import AVFoundation

public enum TimePitchError: LocalizedError {
    case invalidRate
    case renderingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRate:
            return "语速速率超出有效范围 (0.5x - 2.5x)"
        case .renderingFailed(let msg):
            return "音频语速变换渲染失败: \(msg)"
        }
    }
}

/// 原生音频变速引擎：保持音调，离线渲染
public final class TimePitchEngine {
    public init() {}

    /// 调整音频播放语速（音调保持不变）
    /// - Parameters:
    ///   - inputURL: 输入音频路径 (.wav / .m4a)
    ///   - outputURL: 输出音频路径 (.wav)
    ///   - rate: 语速倍率（0.5 ~ 2.5，1.0为原始语速）
    public func changeSpeed(inputURL: URL, outputURL: URL, rate: Float) throws {
        guard rate.isFinite, rate >= 0.5, rate <= 2.5 else { throw TimePitchError.invalidRate }
        let clampedRate = rate
        try? FileManager.default.removeItem(at: outputURL)

        let inputFile = try AVAudioFile(forReading: inputURL)
        let format = inputFile.processingFormat

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let timePitchNode = AVAudioUnitTimePitch()

        timePitchNode.rate = clampedRate
        timePitchNode.pitch = 0.0 // 严格保持音调不变

        engine.attach(playerNode)
        engine.attach(timePitchNode)

        engine.connect(playerNode, to: timePitchNode, format: format)
        engine.connect(timePitchNode, to: engine.mainMixerNode, format: format)

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(
            .offline,
            format: format,
            maximumFrameCount: maxFrames
        )

        try engine.start()
        playerNode.scheduleFile(inputFile, at: nil)
        playerNode.play()

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: inputFile.fileFormat.settings
        )

        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else {
            throw TimePitchError.renderingFailed("无法创建 PCM 缓冲区")
        }

        // Render the requested duration; extra padding would spill into the next utterance.
        let estimatedTotalFrames = AVAudioFramePosition(Double(inputFile.length) / Double(clampedRate))
        var framesRendered: AVAudioFramePosition = 0

        while framesRendered < estimatedTotalFrames {
            let framesToRender = min(maxFrames, AVAudioFrameCount(estimatedTotalFrames - framesRendered))
            let status = try engine.renderOffline(framesToRender, to: buffer)

            switch status {
            case .success:
                try outputFile.write(from: buffer)
                framesRendered += AVAudioFramePosition(buffer.frameLength)
            case .insufficientDataFromInputNode:
                // 数据读取完毕
                break
            case .cannotDoInCurrentContext:
                continue
            case .error:
                throw TimePitchError.renderingFailed("引擎离线渲染出错")
            @unknown default:
                break
            }

            if status == .insufficientDataFromInputNode {
                break
            }
        }

        playerNode.stop()
        engine.stop()
        engine.disableManualRenderingMode()
    }
}
