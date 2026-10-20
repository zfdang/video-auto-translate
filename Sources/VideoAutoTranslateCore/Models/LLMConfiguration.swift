import Foundation

/// 翻译大模型提供者类型
public enum LLMProviderType: String, Codable, CaseIterable, Identifiable {
    case localOllama = "本地 Qwen (Ollama)"
    case onlineCustom = "在线大模型 (OpenAI兼容)"

    public var id: String { rawValue }
}

/// 大语言模型与翻译参数配置
public struct LLMConfiguration: Codable, Equatable {
    public var providerType: LLMProviderType

    // 本地 Ollama 配置
    public var ollamaBaseURL: String
    public var ollamaModel: String

    // 在线大模型备选配置
    public var onlineBaseURL: String
    public var onlineModel: String
    public var onlineAPIKey: String

    // 翻译通用参数
    public var targetLanguage: String
    public var maxConcurrency: Int
    public var temperature: Double

    public init(
        providerType: LLMProviderType = .localOllama,
        ollamaBaseURL: String = "http://localhost:11434",
        ollamaModel: String = "qwen2.5:latest",
        onlineBaseURL: String = "https://api.deepseek.com/v1",
        onlineModel: String = "deepseek-chat",
        onlineAPIKey: String = "",
        targetLanguage: String = "简体中文",
        maxConcurrency: Int = 4,
        temperature: Double = 0.3
    ) {
        self.providerType = providerType
        self.ollamaBaseURL = ollamaBaseURL
        self.ollamaModel = ollamaModel
        self.onlineBaseURL = onlineBaseURL
        self.onlineModel = onlineModel
        self.onlineAPIKey = onlineAPIKey
        self.targetLanguage = targetLanguage
        self.maxConcurrency = maxConcurrency
        self.temperature = temperature
    }

    /// 获取当前生效的 Base URL
    public var effectiveBaseURL: String {
        switch providerType {
        case .localOllama:
            var url = ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if url.hasSuffix("/") { url.removeLast() }
            if !url.hasSuffix("/v1") { url += "/v1" }
            return url
        case .onlineCustom:
            var url = onlineBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if url.hasSuffix("/") { url.removeLast() }
            return url
        }
    }

    /// 获取当前生效的模型名称
    public var effectiveModel: String {
        switch providerType {
        case .localOllama:
            return ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        case .onlineCustom:
            return onlineModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// 获取当前生效的 API Key
    public var effectiveAPIKey: String {
        switch providerType {
        case .localOllama:
            return "ollama" // Ollama 无需实际 key，但需传递非空字符串
        case .onlineCustom:
            return onlineAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
