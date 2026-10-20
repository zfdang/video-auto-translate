import Foundation
import CoreMedia

public protocol ASREngineProtocol {
    /// 执行语音识别，返回带有词级时间戳的字幕行列表
    func transcribe(
        audioURL: URL,
        onProgress: ((Double) -> Void)?
    ) async throws -> [SubtitleItem]
}
