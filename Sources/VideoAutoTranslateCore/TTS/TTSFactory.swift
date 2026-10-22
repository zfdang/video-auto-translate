import Foundation

/// TTS 引擎创建工厂
public enum TTSFactory {
    public static func makeService(for engine: TTSEngineType) -> TTSServiceProtocol {
        switch engine {
        case .edgeTTS:
            return EdgeTTSService()
        case .system:
            return SystemTTSService()
        }
    }
}

/// 支持依据当前动态设置自动分发引擎的 TTS 服务代理
public final class DynamicTTSService: TTSServiceProtocol {
    private let configProvider: () -> TTSConfiguration
    private let edgeService: EdgeTTSService
    private let systemService: SystemTTSService

    public init(configProvider: @escaping () -> TTSConfiguration) {
        self.configProvider = configProvider
        self.edgeService = EdgeTTSService()
        self.systemService = SystemTTSService()
    }

    public func synthesize(
        text: String,
        voice: String,
        outputURL: URL
    ) async throws -> URL {
        let config = configProvider()
        switch config.engineType {
        case .edgeTTS:
            return try await edgeService.synthesize(text: text, voice: voice, outputURL: outputURL)
        case .system:
            return try await systemService.synthesize(text: text, voice: voice, outputURL: outputURL)
        }
    }
}
