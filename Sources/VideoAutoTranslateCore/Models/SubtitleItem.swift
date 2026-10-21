import Foundation
import CoreMedia
import Combine

/// 单行字幕项
public final class SubtitleItem: Identifiable, ObservableObject, Hashable, Equatable, Codable {
    public let id: UUID
    // R04 & R29: 编辑修改通知回调，确保人工改写属性即时标记工程为脏
    public var onModified: (() -> Void)?

    @Published public var startTime: CMTime {
        willSet { if startTime != newValue { onModified?() } }
    }
    @Published public var endTime: CMTime {
        willSet { if endTime != newValue { onModified?() } }
    }
    @Published public var originalText: String {
        willSet { if originalText != newValue { onModified?() } }
    }
    @Published public var translatedText: String {
        willSet { if translatedText != newValue { onModified?() } }
    }
    @Published public var words: [WordToken] {
        willSet { if words != newValue { onModified?() } }
    }

    // 配音缓存状态
    @Published public var dubbedAudioURL: URL?
    @Published public var isGeneratingAudio: Bool = false

    public init(
        id: UUID = UUID(),
        startTime: CMTime,
        endTime: CMTime,
        originalText: String,
        translatedText: String = "",
        words: [WordToken] = [],
        dubbedAudioURL: URL? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.originalText = originalText
        self.translatedText = translatedText
        self.words = words
        self.dubbedAudioURL = dubbedAudioURL
    }

    public var duration: CMTime {
        CMTimeSubtract(endTime, startTime)
    }

    public var durationSeconds: Double {
        duration.secondsValue
    }

    // MARK: - Equatable & Hashable
    public static func == (lhs: SubtitleItem, rhs: SubtitleItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.startTime == rhs.startTime &&
        lhs.endTime == rhs.endTime &&
        lhs.originalText == rhs.originalText &&
        lhs.translatedText == rhs.translatedText
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - Codable
    enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, originalText, translatedText, words, dubbedAudioURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        let codableStart = try container.decode(CodableCMTime.self, forKey: .startTime)
        let codableEnd = try container.decode(CodableCMTime.self, forKey: .endTime)
        self.startTime = codableStart.cmTime
        self.endTime = codableEnd.cmTime
        self.originalText = try container.decode(String.self, forKey: .originalText)
        self.translatedText = try container.decode(String.self, forKey: .translatedText)
        self.words = try container.decode([WordToken].self, forKey: .words)
        self.dubbedAudioURL = try container.decodeIfPresent(URL.self, forKey: .dubbedAudioURL)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(CodableCMTime(cmTime: startTime), forKey: .startTime)
        try container.encode(CodableCMTime(cmTime: endTime), forKey: .endTime)
        try container.encode(originalText, forKey: .originalText)
        try container.encode(translatedText, forKey: .translatedText)
        try container.encode(words, forKey: .words)
        try container.encodeIfPresent(dubbedAudioURL, forKey: .dubbedAudioURL)
    }
}
