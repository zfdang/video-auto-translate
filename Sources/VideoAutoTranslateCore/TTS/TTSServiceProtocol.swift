import Foundation

public protocol TTSServiceProtocol {
    /// 合成单句语音，并保存为指定路径的音频文件
    func synthesize(
        text: String,
        voice: String,
        outputURL: URL
    ) async throws -> URL
}
