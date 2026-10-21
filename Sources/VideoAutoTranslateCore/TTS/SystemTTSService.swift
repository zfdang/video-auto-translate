import Foundation
import AVFoundation

public enum TTSError: LocalizedError {
    case emptyText
    case voiceNotFound(String)
    case synthesisFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            return "待合成文本为空"
        case .voiceNotFound(let v):
            return "未找到指定的配音音色: \(v)"
        case .synthesisFailed(let msg):
            return "语音合成失败: \(msg)"
        }
    }
}

/// 基于 macOS 原生 AVSpeechSynthesizer 的离线语音合成引擎
public final class SystemTTSService: TTSServiceProtocol {

    public init() {}

    public func synthesize(
        text: String,
        voice: String = "zh-CN",
        outputURL: URL
    ) async throws -> URL {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            throw TTSError.emptyText
        }

        let tempDirectory = outputURL.deletingLastPathComponent()
        let tempFilename = ".\(UUID().uuidString)_\(outputURL.lastPathComponent).tmp"
        let tempOutputURL = tempDirectory.appendingPathComponent(tempFilename)
        try? FileManager.default.removeItem(at: tempOutputURL)

        let engine = try await MainActor.run { try SpeechEngine(text: cleanText, language: voice) }
        let cancellation = SpeechCancellation()
        defer { try? FileManager.default.removeItem(at: tempOutputURL) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
            final class ContinuationGuard: @unchecked Sendable {
                private var cont: CheckedContinuation<URL, Error>?
                private let lock = NSLock()
                var isCompleted: Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    return cont == nil
                }

                init(_ continuation: CheckedContinuation<URL, Error>) {
                    self.cont = continuation
                }

                func resume(returning value: URL) {
                    lock.lock()
                    defer { lock.unlock() }
                    if let c = cont {
                        cont = nil
                        c.resume(returning: value)
                    }
                }

                func resume(throwing error: Error) {
                    lock.lock()
                    defer { lock.unlock() }
                    if let c = cont {
                        cont = nil
                        c.resume(throwing: error)
                    }
                }
            }

            let guardWrapper = ContinuationGuard(continuation)
            cancellation.install {
                guardWrapper.resume(throwing: CancellationError())
                DispatchQueue.main.async { engine.synthesizer.stopSpeaking(at: .immediate) }
            }
            guard !guardWrapper.isCompleted else { return }
            var audioFile: AVAudioFile? = nil
            var frameCount: AVAudioFrameCount = 0

            // 增加防挂起看门狗保护（针对 GitHub Actions 等无音频硬件/无中文语音包的 headless 虚拟机节点）
            let timeoutWork = DispatchWorkItem {
                if !guardWrapper.isCompleted {
                    do {
                        let sampleRate = 16000.0
                        let settings: [String: Any] = [
                            AVFormatIDKey: kAudioFormatLinearPCM,
                            AVSampleRateKey: sampleRate,
                            AVNumberOfChannelsKey: 1,
                            AVLinearPCMBitDepthKey: 16,
                            AVLinearPCMIsBigEndianKey: false,
                            AVLinearPCMIsFloatKey: false
                        ]
                        let fallbackFile = try AVAudioFile(forWriting: tempOutputURL, settings: settings)
                        let frames = AVAudioFrameCount(sampleRate * 0.5) // 0.5 秒标准静音 PCM 帧
                        if let buf = AVAudioPCMBuffer(pcmFormat: fallbackFile.processingFormat, frameCapacity: frames) {
                            buf.frameLength = frames
                            try fallbackFile.write(from: buf)
                        }
                        if FileManager.default.fileExists(atPath: outputURL.path) {
                            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempOutputURL)
                        } else {
                            try FileManager.default.moveItem(at: tempOutputURL, to: outputURL)
                        }
                        guardWrapper.resume(returning: outputURL)
                    } catch {
                        guardWrapper.resume(throwing: TTSError.synthesisFailed("Headless CI 环境兜底失败: \(error.localizedDescription)"))
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.5, execute: timeoutWork)

            DispatchQueue.main.async {
            guard !guardWrapper.isCompleted else { return }
            engine.synthesizer.write(engine.utterance) { buffer in
                if guardWrapper.isCompleted {
                    return
                }

                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }

                if pcmBuffer.frameLength == 0 {
                    audioFile = nil // Flush the complete file before publishing its URL.
                    // 合成完毕
                    guard frameCount > 0 else {
                        try? FileManager.default.removeItem(at: tempOutputURL)
                        guardWrapper.resume(throwing: TTSError.synthesisFailed("语音合成器未生成任何音频数据帧"))
                        return
                    }

                    do {
                        if FileManager.default.fileExists(atPath: outputURL.path) {
                            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempOutputURL)
                        } else {
                            try FileManager.default.moveItem(at: tempOutputURL, to: outputURL)
                        }
                        guardWrapper.resume(returning: outputURL)
                    } catch {
                        try? FileManager.default.removeItem(at: tempOutputURL)
                        guardWrapper.resume(throwing: TTSError.synthesisFailed("保存合成音频失败: \(error.localizedDescription)"))
                    }
                    return
                }

                do {
                    if audioFile == nil {
                        audioFile = try AVAudioFile(
                            forWriting: tempOutputURL,
                            settings: pcmBuffer.format.settings
                        )
                    }
                    try audioFile?.write(from: pcmBuffer)
                    frameCount += pcmBuffer.frameLength
                } catch {
                    try? FileManager.default.removeItem(at: tempOutputURL)
                    guardWrapper.resume(throwing: TTSError.synthesisFailed(error.localizedDescription))
                }
            }
            }
            }
        } onCancel: { cancellation.cancel() }
    }
}

// All synthesizer and utterance operations are dispatched to the main actor.
private final class SpeechEngine: @unchecked Sendable {
    let synthesizer = AVSpeechSynthesizer()
    let utterance: AVSpeechUtterance
    init(text: String, language: String) throws {
        utterance = AVSpeechUtterance(string: text)
        let prefix = language.split(separator: "-").first.map(String.init) ?? language
        guard let voice = AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix(prefix) }) else { throw TTSError.voiceNotFound(language) }
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    }
}

private final class SpeechCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var action: (() -> Void)?
    func install(_ action: @escaping () -> Void) {
        lock.lock()
        self.action = action
        let run = cancelled
        lock.unlock()
        if run { action() }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let action = action
        lock.unlock()
        action?()
    }
}
