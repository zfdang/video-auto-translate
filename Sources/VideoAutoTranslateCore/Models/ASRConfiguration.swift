import Foundation

/// 本地 ASR 服务配置
public struct ASRConfiguration: Codable, Equatable {
    public var serviceURL: String
    public var model: String
    public var language: String

    public init(
        serviceURL: String = "http://127.0.0.1:8765/v1/audio/transcriptions",
        model: String = "qwen3-asr",
        language: String = "auto"
    ) {
        self.serviceURL = serviceURL
        self.model = model
        self.language = language
    }
}
