import Foundation

/// 项目当前处理状态与数据持有
public struct ProjectState: Equatable {
    public var videoURL: URL?
    public var audioURL: URL?
    public var subtitles: [SubtitleItem] = []
    public var selectedSubtitleID: UUID?

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
        isProcessing = false
        currentStepName = ""
        progress = 0.0
    }
}
