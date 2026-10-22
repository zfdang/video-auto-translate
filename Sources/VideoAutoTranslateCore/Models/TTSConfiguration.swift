import Foundation

/// 语音合成引擎类型
public enum TTSEngineType: String, Codable, CaseIterable, Identifiable {
    case edgeTTS = "edge_tts"
    case system = "system"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .edgeTTS:
            return "微软 Edge 拟真语音 (推荐·极佳语调韵律)"
        case .system:
            return "macOS 原生语音 (离线保底)"
        }
    }

    public var shortName: String {
        switch self {
        case .edgeTTS: return "Edge TTS"
        case .system: return "系统原生"
        }
    }
}

/// 音色选项模型
public struct TTSVoiceOption: Identifiable, Hashable, Codable {
    public let id: String
    public let name: String
    public let gender: String
    public let locale: String
    public let isRecommended: Bool
    public let engine: TTSEngineType

    public init(id: String, name: String, gender: String, locale: String, isRecommended: Bool = false, engine: TTSEngineType = .edgeTTS) {
        self.id = id
        self.name = name
        self.gender = gender
        self.locale = locale
        self.isRecommended = isRecommended
        self.engine = engine
    }

    /// 预置的常用高质量音色
    public static let presets: [TTSVoiceOption] = [
        // 简体中文
        TTSVoiceOption(id: "zh-CN-YunxiNeural", name: "云希 (热门解说·活力生动·男)", gender: "男", locale: "zh-CN", isRecommended: true, engine: .edgeTTS),
        TTSVoiceOption(id: "zh-CN-XiaoxiaoNeural", name: "晓晓 (亲和自然·温暖温润·女)", gender: "女", locale: "zh-CN", isRecommended: true, engine: .edgeTTS),
        TTSVoiceOption(id: "zh-CN-YunjianNeural", name: "云健 (沉稳专业·纪录片解说·男)", gender: "男", locale: "zh-CN", isRecommended: true, engine: .edgeTTS),
        TTSVoiceOption(id: "zh-CN-XiaoyiNeural", name: "晓伊 (生动活泼·故事朗读·女)", gender: "女", locale: "zh-CN", isRecommended: false, engine: .edgeTTS),
        TTSVoiceOption(id: "zh-CN-YunyangNeural", name: "云扬 (专业大气·新闻播报·男)", gender: "男", locale: "zh-CN", isRecommended: false, engine: .edgeTTS),
        TTSVoiceOption(id: "zh-CN-liaoning-XiaobeiNeural", name: "晓北 (东北口音·幽默生动·女)", gender: "女", locale: "zh-CN", isRecommended: false, engine: .edgeTTS),
        TTSVoiceOption(id: "zh-CN-shaanxi-YifanNeural", name: "一凡 (陕西方言·质朴沉稳·男)", gender: "男", locale: "zh-CN", isRecommended: false, engine: .edgeTTS),

        // 繁体中文
        TTSVoiceOption(id: "zh-TW-HsiaoChenNeural", name: "晓臻 (台湾国语·自然温柔·女)", gender: "女", locale: "zh-TW", isRecommended: true, engine: .edgeTTS),
        TTSVoiceOption(id: "zh-TW-YunJheNeural", name: "云哲 (台湾国语·阳光亲切·男)", gender: "男", locale: "zh-TW", isRecommended: true, engine: .edgeTTS),
        TTSVoiceOption(id: "zh-HK-HiuMaanNeural", name: "晓曼 (粤语·清晰流畅·女)", gender: "女", locale: "zh-HK", isRecommended: true, engine: .edgeTTS),
        TTSVoiceOption(id: "zh-HK-WanLungNeural", name: "云龙 (粤语·沉稳自然·男)", gender: "男", locale: "zh-HK", isRecommended: true, engine: .edgeTTS),

        // 英语
        TTSVoiceOption(id: "en-US-AvaMultilingualNeural", name: "Ava (多语神经网络·自然地道·女)", gender: "女", locale: "en-US", isRecommended: true, engine: .edgeTTS),
        TTSVoiceOption(id: "en-US-AndrewMultilingualNeural", name: "Andrew (多语神经网络·沉稳自信·男)", gender: "男", locale: "en-US", isRecommended: true, engine: .edgeTTS),
        TTSVoiceOption(id: "en-US-AriaNeural", name: "Aria (专业自信·新闻科普·女)", gender: "女", locale: "en-US", isRecommended: true, engine: .edgeTTS),
        TTSVoiceOption(id: "en-US-GuyNeural", name: "Guy (自然热情·随和解说·男)", gender: "男", locale: "en-US", isRecommended: true, engine: .edgeTTS),
        TTSVoiceOption(id: "en-US-JennyNeural", name: "Jenny (友好舒适·日常交流·女)", gender: "女", locale: "en-US", isRecommended: false, engine: .edgeTTS),
        TTSVoiceOption(id: "en-GB-SoniaNeural", name: "Sonia (英式发音·优雅知性·女)", gender: "女", locale: "en-GB", isRecommended: true, engine: .edgeTTS),
        TTSVoiceOption(id: "en-GB-RyanNeural", name: "Ryan (英式发音·醇厚自然·男)", gender: "男", locale: "en-GB", isRecommended: true, engine: .edgeTTS),

        // 日语
        TTSVoiceOption(id: "ja-JP-NanamiNeural", name: "七海 Nanami (温柔清澈·女)", gender: "女", locale: "ja-JP", isRecommended: true, engine: .edgeTTS),
        TTSVoiceOption(id: "ja-JP-KeitaNeural", name: "圭太 Keita (清爽利落·男)", gender: "男", locale: "ja-JP", isRecommended: true, engine: .edgeTTS),

        // 韩语
        TTSVoiceOption(id: "ko-KR-SunHiNeural", name: "善熙 SunHi (清晰亲和·女)", gender: "女", locale: "ko-KR", isRecommended: true, engine: .edgeTTS),
        TTSVoiceOption(id: "ko-KR-InJoonNeural", name: "仁俊 InJoon (磁性沉着·男)", gender: "男", locale: "ko-KR", isRecommended: true, engine: .edgeTTS),

        // 法语
        TTSVoiceOption(id: "fr-FR-DeniseNeural", name: "Denise (优雅地道·女)", gender: "女", locale: "fr-FR", isRecommended: true, engine: .edgeTTS),
        TTSVoiceOption(id: "fr-FR-HenriNeural", name: "Henri (成熟稳重·男)", gender: "男", locale: "fr-FR", isRecommended: true, engine: .edgeTTS),

        // 德语
        TTSVoiceOption(id: "de-DE-KatjaNeural", name: "Katja (严谨清晰·女)", gender: "女", locale: "de-DE", isRecommended: true, engine: .edgeTTS),
        TTSVoiceOption(id: "de-DE-ConradNeural", name: "Conrad (沉稳可靠·男)", gender: "男", locale: "de-DE", isRecommended: true, engine: .edgeTTS),

        // 西班牙语
        TTSVoiceOption(id: "es-ES-ElviraNeural", name: "Elvira (自然明快·女)", gender: "女", locale: "es-ES", isRecommended: true, engine: .edgeTTS),
        TTSVoiceOption(id: "es-ES-AlvaroNeural", name: "Alvaro (醇厚生动·男)", gender: "男", locale: "es-ES", isRecommended: true, engine: .edgeTTS),

        // 俄语
        TTSVoiceOption(id: "ru-RU-SvetlanaNeural", name: "Svetlana (清晰自然·女)", gender: "女", locale: "ru-RU", isRecommended: true, engine: .edgeTTS),
        TTSVoiceOption(id: "ru-RU-DmitryNeural", name: "Dmitry (稳健有力·男)", gender: "男", locale: "ru-RU", isRecommended: true, engine: .edgeTTS),

        // 系统原生音色常用占位
        TTSVoiceOption(id: "zh-CN", name: "系统普通话 (默认)", gender: "通用", locale: "zh-CN", isRecommended: true, engine: .system),
        TTSVoiceOption(id: "en-US", name: "System English (Default)", gender: "通用", locale: "en-US", isRecommended: true, engine: .system),
        TTSVoiceOption(id: "ja-JP", name: "システム日本語 (デフォルト)", gender: "通用", locale: "ja-JP", isRecommended: true, engine: .system),
        TTSVoiceOption(id: "ko-KR", name: "시스템 한국어 (기본값)", gender: "通用", locale: "ko-KR", isRecommended: true, engine: .system)
    ]

    /// 根据语言和引擎筛选音色列表
    public static func voices(for targetLanguage: String, engine: TTSEngineType) -> [TTSVoiceOption] {
        let trimmed = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let langPrefix: String
        if trimmed.contains("中") || trimmed.contains("华") || trimmed.hasPrefix("zh") || trimmed.contains("chinese") {
            langPrefix = "zh"
        } else if trimmed.contains("英") || trimmed.hasPrefix("en") || trimmed.contains("english") {
            langPrefix = "en"
        } else if trimmed.contains("日") || trimmed.hasPrefix("ja") || trimmed.contains("japanese") {
            langPrefix = "ja"
        } else if trimmed.contains("韩") || trimmed.hasPrefix("ko") || trimmed.contains("korean") {
            langPrefix = "ko"
        } else if trimmed.contains("法") || trimmed.hasPrefix("fr") || trimmed.contains("french") {
            langPrefix = "fr"
        } else if trimmed.contains("德") || trimmed.hasPrefix("de") || trimmed.contains("german") {
            langPrefix = "de"
        } else if trimmed.contains("西") || trimmed.hasPrefix("es") || trimmed.contains("spanish") {
            langPrefix = "es"
        } else if trimmed.contains("俄") || trimmed.hasPrefix("ru") || trimmed.contains("russian") {
            langPrefix = "ru"
        } else {
            langPrefix = "zh"
        }

        let matched = presets.filter { $0.engine == engine && $0.locale.lowercased().hasPrefix(langPrefix) }
        return matched.isEmpty ? presets.filter { $0.engine == engine } : matched
    }
}

/// 语音合成完整配置
public struct TTSConfiguration: Codable, Equatable {
    public var engineType: TTSEngineType = .edgeTTS
    public var selectedVoice: String = "zh-CN-YunxiNeural"
    public var speechRate: Double = 1.0

    public init(
        engineType: TTSEngineType = .edgeTTS,
        selectedVoice: String = "zh-CN-YunxiNeural",
        speechRate: Double = 1.0
    ) {
        self.engineType = engineType
        self.selectedVoice = selectedVoice
        self.speechRate = speechRate
    }

    /// 依据目标语言与当前引擎解析最适音色
    public func effectiveVoice(for targetLanguage: String) -> String {
        if engineType == .system {
            // 系统原生引擎直接返回语言代码，如 "zh-CN"
            let voices = TTSVoiceOption.voices(for: targetLanguage, engine: .system)
            return voices.first?.id ?? "zh-CN"
        }

        // Edge TTS: 优先检查当前所选音色是否与目标语言匹配
        let candidates = TTSVoiceOption.voices(for: targetLanguage, engine: .edgeTTS)
        if candidates.contains(where: { $0.id == selectedVoice }) {
            return selectedVoice
        }

        // 如果不匹配目标语言，取该语言的首选推荐音色
        if let recommended = candidates.first(where: { $0.isRecommended }) {
            return recommended.id
        }
        return candidates.first?.id ?? "zh-CN-YunxiNeural"
    }
}
