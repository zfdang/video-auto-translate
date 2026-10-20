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

        try? FileManager.default.removeItem(at: outputURL)

        let utterance = AVSpeechUtterance(string: cleanText)
        if let preferredVoice = AVSpeechSynthesisVoice(language: voice) {
            utterance.voice = preferredVoice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }

        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        return try await withCheckedThrowingContinuation { continuation in
            var audioFile: AVAudioFile? = nil

            self.synthesizer.write(utterance) { buffer in
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }

                if pcmBuffer.frameLength == 0 {
                    // 合成完毕
                    continuation.resume(returning: outputURL)
                    return
                }

                do {
                    if audioFile == nil {
                        audioFile = try AVAudioFile(
                            forWriting: outputURL,
                            settings: pcmBuffer.format.settings
                        )
                    }
                    try audioFile?.write(from: pcmBuffer)
                } catch {
                    continuation.resume(throwing: TTSError.synthesisFailed(error.localizedDescription))
                }
            }
        }
    }
}
