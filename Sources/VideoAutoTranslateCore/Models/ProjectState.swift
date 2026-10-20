import Foundation

/// 持久化工程文档模型 (R04: 支持 .vatproject 序列化存储与恢复)
public struct ProjectDocument: Codable {
    public var version: Int = 1
    public var videoPath: String?
    public var subtitles: [SubtitleItem]
    public var llmConfig: LLMConfiguration
    public var asrConfig: ASRConfiguration

    public init(
        version: Int = 1,
        videoPath: String? = nil,
        subtitles: [SubtitleItem] = [],
        llmConfig: LLMConfiguration = LLMConfiguration(),
        asrConfig: ASRConfiguration = ASRConfiguration()
    ) {
        self.version = version
        self.videoPath = videoPath
        self.subtitles = subtitles
        self.llmConfig = llmConfig
        self.asrConfig = asrConfig
    }
}

/// 项目当前处理状态与数据持有
public struct ProjectState: Equatable {
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

    /// R04: 导出工程持久化数据
    public func encodeDocument() throws -> Data {
        let doc = ProjectDocument(
            version: 1,
            videoPath: videoURL?.path,
            subtitles: subtitles,
            llmConfig: llmConfig,
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

    /// R04: 从持久化数据恢复工程
    public mutating func restore(from document: ProjectDocument) {
        if let path = document.videoPath {
            self.videoURL = URL(fileURLWithPath: path)
        }
        self.subtitles = document.subtitles
        self.llmConfig = document.llmConfig
        self.asrConfig = document.asrConfig
        self.isDirty = false
    }
}
