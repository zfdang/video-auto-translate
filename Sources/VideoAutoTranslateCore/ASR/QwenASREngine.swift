import Foundation
import CoreMedia

public enum ASRError: LocalizedError {
    case alignmentRequired(String)
    case audioFileNotFound
    case engineNotReady(String)
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alignmentRequired:
            return "已取得识别文本，但缺少有效时间，请准备对齐模型后重新转录。原文已保留。"
        case .audioFileNotFound:
            return "待识别音频文件不存在"
        case .engineNotReady(let msg):
            return msg
        case .transcriptionFailed(let msg):
            return msg
        }
    }
}

/// Compatibility entry point; recognition always uses the actual local service.
public final class QwenASREngine: ASREngineProtocol {
    public init() {}
    public func transcribe(audioURL: URL, onProgress: ((Double) -> Void)? = nil) async throws -> [SubtitleItem] {
        try await LocalASRService().transcribe(audioURL: audioURL, onProgress: onProgress)
    }
}
