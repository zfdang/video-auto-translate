import Foundation

/// 项目当前处理状态与数据持有
public final class ProjectState: ObservableObject {
    @Published public var videoURL: URL?
    @Published public var audioURL: URL?
    @Published public var subtitles: [SubtitleItem] = []
    @Published public var selectedSubtitleID: UUID?

    @Published public var isProcessing: Bool = false
    @Published public var currentStepName: String = ""
    @Published public var progress: Double = 0.0

    @Published public var llmConfig: LLMConfiguration = LLMConfiguration()
    @Published public var asrConfig: ASRConfiguration = ASRConfiguration()
    @Published public var modelStorageConfig: ModelStorageConfig = ModelStorageConfig()

    public init(videoURL: URL? = nil, subtitles: [SubtitleItem] = []) {
        self.videoURL = videoURL
        self.subtitles = subtitles
    }

    /// 重置工程状态
    public func reset() {
        videoURL = nil
        audioURL = nil
        subtitles.removeAll()
        selectedSubtitleID = nil
        isProcessing = false
        currentStepName = ""
        progress = 0.0
    }
}
