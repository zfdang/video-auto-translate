import Foundation

/// 目标语言预设项
public struct TargetLanguagePreset: Identifiable, Hashable {
    public let code: String
    public let name: String

    public var id: String { name }

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }

    public static let defaultPresets: [TargetLanguagePreset] = [
        TargetLanguagePreset(code: "zh-Hans", name: "简体中文 (Simplified Chinese)"),
        TargetLanguagePreset(code: "en", name: "英语 (English)"),
        TargetLanguagePreset(code: "ja", name: "日语 (Japanese)"),
        TargetLanguagePreset(code: "ko", name: "韩语 (Korean)"),
        TargetLanguagePreset(code: "zh-Hant", name: "繁体中文 (Traditional Chinese)"),
        TargetLanguagePreset(code: "fr", name: "法语 (French)"),
        TargetLanguagePreset(code: "de", name: "德语 (German)"),
        TargetLanguagePreset(code: "es", name: "西班牙语 (Spanish)"),
        TargetLanguagePreset(code: "ru", name: "俄语 (Russian)"),
        TargetLanguagePreset(code: "pt", name: "葡萄牙语 (Portuguese)"),
        TargetLanguagePreset(code: "it", name: "意大利语 (Italian)"),
        TargetLanguagePreset(code: "ar", name: "阿拉伯语 (Arabic)"),
        TargetLanguagePreset(code: "th", name: "泰语 (Thai)"),
        TargetLanguagePreset(code: "vi", name: "越南语 (Vietnamese)")
    ]
}

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
        targetLanguage: String = "简体中文 (Simplified Chinese)",
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

    /// R19: 依据当前所选目标语言解析对应的系统语音合成音色 BCP-47 代码
    public var targetLanguageVoiceCode: String {
        let trimmed = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        let matched = TargetLanguagePreset.defaultPresets.first {
            $0.name == trimmed ||
            $0.code.lowercased() == lower ||
            $0.name.localizedCaseInsensitiveContains(trimmed) ||
            trimmed.localizedCaseInsensitiveContains($0.name)
        }
        guard let code = matched?.code else {
            if trimmed.contains("中") || trimmed.contains("华") || lower.hasPrefix("zh") || lower.contains("chinese") { return "zh-CN" }
            if trimmed.contains("法") || lower.hasPrefix("fr") || lower == "french" { return "fr-FR" }
            if trimmed.contains("德") || lower.hasPrefix("de") || lower == "german" { return "de-DE" }
            if trimmed.contains("西") || lower.hasPrefix("es") || lower == "spanish" { return "es-ES" }
            if trimmed.contains("日") || lower.hasPrefix("ja") || lower == "japanese" { return "ja-JP" }
            if trimmed.contains("韩") || lower.hasPrefix("ko") || lower == "korean" { return "ko-KR" }
            if trimmed.contains("俄") || lower.hasPrefix("ru") || lower == "russian" { return "ru-RU" }
            if trimmed.contains("意") || lower.hasPrefix("it") || lower == "italian" { return "it-IT" }
            if trimmed.contains("葡") || lower.hasPrefix("pt") || lower == "portuguese" { return "pt-BR" }
            if trimmed.contains("英") || lower.hasPrefix("en") || lower == "english" { return "en-US" }
            return "zh-CN"
        }
        switch code {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "en": return "en-US"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "es": return "es-ES"
        case "ru": return "ru-RU"
        case "pt": return "pt-BR"
        case "it": return "it-IT"
        case "ar": return "ar-SA"
        case "th": return "th-TH"
        case "vi": return "vi-VN"
        default: return code
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
