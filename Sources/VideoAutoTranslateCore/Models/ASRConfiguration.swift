import Foundation

/// ASR 识别原语言预设
public struct ASRLanguagePreset: Identifiable, Hashable {
    public let code: String
    public let displayName: String
    public var id: String { code }

    public init(code: String, displayName: String) {
        self.code = code
        self.displayName = displayName
    }

    public static let presets: [ASRLanguagePreset] = [
        ASRLanguagePreset(code: "auto", displayName: "自动检测 (Auto)"),
        ASRLanguagePreset(code: "zh", displayName: "中文 / 普通话 (Chinese)"),
        ASRLanguagePreset(code: "en", displayName: "英语 (English)"),
        ASRLanguagePreset(code: "ja", displayName: "日语 (Japanese)"),
        ASRLanguagePreset(code: "ko", displayName: "韩语 (Korean)"),
        ASRLanguagePreset(code: "yue", displayName: "粤语 / 广东话 (Cantonese)"),
        ASRLanguagePreset(code: "fr", displayName: "法语 (French)"),
        ASRLanguagePreset(code: "de", displayName: "德语 (German)"),
        ASRLanguagePreset(code: "es", displayName: "西班牙语 (Spanish)"),
        ASRLanguagePreset(code: "ru", displayName: "俄语 (Russian)")
    ]
}

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
