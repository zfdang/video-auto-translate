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
    private let synthesizer = AVSpeechSynthesizer()

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

        let utterance = AVSpeechUtterance(string: cleanText)
        
        // R19: 优先匹配精确 BCP-47 语言代码，次选同语族音色，避免非中文请求被静默降级为中文
        if let preferredVoice = AVSpeechSynthesisVoice(language: voice) {
            utterance.voice = preferredVoice
        } else if let prefix = voice.split(separator: "-").first,
                  let matched = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix(String(prefix)) }) {
            utterance.voice = matched
        } else if let fallback = AVSpeechSynthesisVoice(language: "zh-CN") {
            utterance.voice = fallback
        }

        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        // R11: 线程安全的 exactly-once continuation 守卫，杜绝重复 resume 崩溃
        return try await withCheckedThrowingContinuation { continuation in
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
            var audioFile: AVAudioFile? = nil
            var frameCount: AVAudioFrameCount = 0

            self.synthesizer.write(utterance) { buffer in
                if guardWrapper.isCompleted {
                    return
                }

                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }

                if pcmBuffer.frameLength == 0 {
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
}
