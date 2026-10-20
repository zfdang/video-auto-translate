import Foundation
import AVFoundation

public enum AudioExtractorError: LocalizedError {
    case noAudioTrack
    case readerFailed(String)
    case writerFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "未在源视频文件中找到音轨"
        case .readerFailed(let msg):
            return "音频读取失败: \(msg)"
        case .writerFailed(let msg):
            return "音频写入失败: \(msg)"
        case .cancelled:
            return "提取过程已取消"
        }
    }
}

/// 纯原生音频提取器：从视频抽取 16kHz 单声道 LinearPCM WAV
public final class AudioExtractor {
    public init() {}

    /// 从本地视频提取 16kHz 单声道 PCM WAV 格式音频
    public func extract16kMonoWav(from videoURL: URL, to outputWavURL: URL) async throws {
        // 安全检查：严禁输出路径与输入视频相同，防止覆盖源视频 (R01)
        guard outputWavURL.standardizedFileURL != videoURL.standardizedFileURL else {
            throw AudioExtractorError.writerFailed("输出音频路径不能与源视频路径相同")
        }

        let tempDirectory = outputWavURL.deletingLastPathComponent()
        let tempFilename = ".\(UUID().uuidString)_\(outputWavURL.lastPathComponent).tmp"
        let tempOutputWavURL = tempDirectory.appendingPathComponent(tempFilename)
        try? FileManager.default.removeItem(at: tempOutputWavURL)

        let asset = AVURLAsset(url: videoURL)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioExtractorError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)

        // 目标解调格式: 16000Hz, 单声道, 16位PCM
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw AudioExtractorError.readerFailed("无法添加音频读取输出通道")
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: tempOutputWavURL, fileType: .wav)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw AudioExtractorError.writerFailed("无法添加音频写入通道")
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            try? FileManager.default.removeItem(at: tempOutputWavURL)
            throw AudioExtractorError.readerFailed(reader.error?.localizedDescription ?? "读取器启动失败")
        }
        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: tempOutputWavURL)
            throw AudioExtractorError.writerFailed(writer.error?.localizedDescription ?? "写入器启动失败")
        }
        writer.startSession(atSourceTime: .zero)

        // 异步将 sample buffer 从 reader 泵送至 writer (带 exactly-once 保护)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "com.videoautotranslate.audioextract", qos: .userInitiated)
            let lock = NSLock()
            var hasResumed = false

            func safeResume(throwing error: Error) {
                lock.lock()
                defer { lock.unlock() }
                if !hasResumed {
                    hasResumed = true
                    continuation.resume(throwing: error)
                }
            }

            func safeResumeSuccess() {
                lock.lock()
                defer { lock.unlock() }
                if !hasResumed {
                    hasResumed = true
                    continuation.resume()
                }
            }

            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        if !writerInput.append(sampleBuffer) {
                            reader.cancelReading()
                            writer.cancelWriting()
                            safeResume(throwing: AudioExtractorError.writerFailed(writer.error?.localizedDescription ?? "数据写入失败"))
                            return
                        }
                    } else {
                        // 读取完成
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed {
                                safeResumeSuccess()
                            } else {
                                safeResume(throwing: AudioExtractorError.writerFailed(writer.error?.localizedDescription ?? "写入结束异常"))
                            }
                        }
                        return
                    }
                }
            }
        }

        // 提取成功后原子替换目标文件
        do {
            if FileManager.default.fileExists(atPath: outputWavURL.path) {
                _ = try FileManager.default.replaceItemAt(outputWavURL, withItemAt: tempOutputWavURL)
            } else {
                try FileManager.default.moveItem(at: tempOutputWavURL, to: outputWavURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempOutputWavURL)
            throw AudioExtractorError.writerFailed("替换导出目标音频失败: \(error.localizedDescription)")
        }
    }
}
