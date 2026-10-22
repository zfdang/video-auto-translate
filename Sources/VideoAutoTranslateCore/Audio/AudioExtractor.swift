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
        // 安全检查：严禁输出路径与输入视频相同或指向同一文件，防止覆盖源视频 (R01 / FU02)
        guard !outputWavURL.pointsToSameFile(as: videoURL) else {
            throw AudioExtractorError.writerFailed("输出音频路径不能与源视频路径相同")
        }

        let tempDirectory = outputWavURL.deletingLastPathComponent()
        let tempFilename = ".\(UUID().uuidString)_\(outputWavURL.lastPathComponent).tmp"
        let tempOutputWavURL = tempDirectory.appendingPathComponent(tempFilename)
        try? FileManager.default.removeItem(at: tempOutputWavURL)

        defer { try? FileManager.default.removeItem(at: tempOutputWavURL) }
        try Task.checkCancellation()

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

        let pump = AudioExtractionPump(reader: reader, output: readerOutput, writer: writer, input: writerInput)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await pump.run()
        } onCancel: {
            pump.cancel()
        }
        try Task.checkCancellation()

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

/// AVFoundation objects and the continuation are exclusively accessed on `queue`
/// after setup. Only the cancellation flag is shared, protected by `lock`.
private final class AudioExtractionPump: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "com.videoautotranslate.audioextract", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var finishing = false

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.reader = reader
        self.output = output
        self.writer = writer
        self.input = input
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        // Also wake a stalled writer which is no longer invoking its ready callback.
        queue.async { self.abort(CancellationError()) }
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                guard !self.isCancelled else { self.abort(CancellationError()); return }
                guard self.reader.startReading() else {
                    self.abort(AudioExtractorError.readerFailed(self.reader.error?.localizedDescription ?? "读取器启动失败"))
                    return
                }
                guard self.writer.startWriting() else {
                    self.abort(AudioExtractorError.writerFailed(self.writer.error?.localizedDescription ?? "写入器启动失败"))
                    return
                }
                self.writer.startSession(atSourceTime: .zero)
                self.input.requestMediaDataWhenReady(on: self.queue) { [weak self] in self?.pump() }
            }
        }
    }

    private func complete(_ result: Result<Void, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }

    private func abort(_ error: Error) {
        guard continuation != nil else { return }
        if reader.status == .reading { reader.cancelReading() }
        if writer.status == .writing { writer.cancelWriting() }
        complete(.failure(error))
    }

    private func pump() {
        guard continuation != nil, !finishing else { return }
        while input.isReadyForMoreMediaData {
            guard !isCancelled else { abort(CancellationError()); return }
            if let sample = output.copyNextSampleBuffer() {
                guard input.append(sample) else {
                    abort(AudioExtractorError.writerFailed(writer.error?.localizedDescription ?? "数据写入失败"))
                    return
                }
            } else {
                guard reader.status == .completed else {
                    abort(AudioExtractorError.readerFailed(reader.error?.localizedDescription ?? "音频读取未完成"))
                    return
                }
                finishing = true
                input.markAsFinished()
                writer.finishWriting {
                    self.queue.async {
                        guard self.continuation != nil else { return }
                        if self.isCancelled { self.abort(CancellationError()) }
                        else if self.writer.status == .completed { self.complete(.success(())) }
                        else { self.abort(AudioExtractorError.writerFailed(self.writer.error?.localizedDescription ?? "写入结束异常")) }
                    }
                }
                return
            }
        }
    }
}
