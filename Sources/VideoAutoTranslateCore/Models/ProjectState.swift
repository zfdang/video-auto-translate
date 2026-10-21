import Foundation

/// 持久化工程文档模型 (R04: 支持 .vatproject 序列化存储与恢复)
public struct ProjectDocument: Codable {
    public var unalignedTranscript: String?
    public var version: Int = 1
    public var videoPath: String?
    public var subtitles: [SubtitleItem]
    public var llmConfig: LLMConfiguration
    public var asrConfig: ASRConfiguration

    public init(
        unalignedTranscript: String? = nil,
        version: Int = 1,
        videoPath: String? = nil,
        subtitles: [SubtitleItem] = [],
        llmConfig: LLMConfiguration = LLMConfiguration(),
        asrConfig: ASRConfiguration = ASRConfiguration()
    ) {
        self.unalignedTranscript = unalignedTranscript
        self.version = version
        self.videoPath = videoPath
        self.subtitles = subtitles
        self.llmConfig = llmConfig
        self.asrConfig = asrConfig
    }
}

/// 项目当前处理状态与数据持有
public struct ProjectState: Equatable {
    public var unalignedTranscript: String?
    public var videoURL: URL?
    public var audioURL: URL?
    public var subtitles: [SubtitleItem] = []
    public var selectedSubtitleID: UUID?
    /// R30: 播放高亮 ID 与用户编辑选择 ID 分离，防止播放时自动滚动抢占焦点
    public var playingSubtitleID: UUID?
    /// R04: 标记工程是否存在未保存的脏状态修改
    public var isDirty: Bool = false

    public var isProcessing: Bool = false
    public var currentStepName: String = ""
    public var progress: Double = 0.0

    public var llmConfig: LLMConfiguration = LLMConfiguration()
    public var asrConfig: ASRConfiguration = ASRConfiguration()
    public var modelStorageConfig: ModelStorageConfig = ModelStorageConfig()

    public init(videoURL: URL? = nil, subtitles: [SubtitleItem] = []) {
        self.videoURL = videoURL
        self.subtitles = subtitles
    }

    /// 重置工程状态
    public mutating func reset() {
        unalignedTranscript = nil
        videoURL = nil
        audioURL = nil
        subtitles.removeAll()
        selectedSubtitleID = nil
        playingSubtitleID = nil
        isDirty = false
        isProcessing = false
        currentStepName = ""
        progress = 0.0
    }

    /// R04 / FU04: 导出工程持久化数据（自动剔除敏感 API Key，杜绝明文凭据泄露）
    public func encodeDocument() throws -> Data {
        var safeLLMConfig = llmConfig
        safeLLMConfig.onlineAPIKey = ""

        let doc = ProjectDocument(
            unalignedTranscript: unalignedTranscript,
            version: 1,
            videoPath: videoURL?.path,
            subtitles: subtitles,
            llmConfig: safeLLMConfig,
            asrConfig: asrConfig
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        return try encoder.encode(doc)
    }

    /// R04: 解析工程持久化数据
    public static func decodeDocument(from data: Data) throws -> ProjectDocument {
        let decoder = JSONDecoder()
        return try decoder.decode(ProjectDocument.self, from: data)
    }

    /// R04 / FU04: 从持久化数据恢复工程（保留本地既有在线凭据）
    public mutating func restore(from document: ProjectDocument) {
        if let path = document.videoPath {
            self.videoURL = URL(fileURLWithPath: path)
        }
        self.unalignedTranscript = document.unalignedTranscript
        self.subtitles = document.subtitles
        let existingKey = self.llmConfig.onlineAPIKey
        self.llmConfig = document.llmConfig
        if !existingKey.isEmpty && self.llmConfig.onlineAPIKey.isEmpty {
            self.llmConfig.onlineAPIKey = existingKey
        }
        self.asrConfig = document.asrConfig
        self.isDirty = false
    }
}
