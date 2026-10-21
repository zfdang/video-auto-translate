import Foundation
import CoreMedia
import Combine
import CryptoKit

/// 单行字幕项
public final class SubtitleItem: Identifiable, ObservableObject, Hashable, Equatable, Codable {
    public let id: UUID
    public let sourceStartTime: CMTime
    public let sourceEndTime: CMTime
    // R04 & R29: 编辑修改通知回调，确保人工改写属性即时标记工程为脏
    public var onModified: (() -> Void)?

    @Published public var startTime: CMTime {
        willSet { if startTime != newValue { onModified?() } }
        didSet { if startTime != oldValue { dubbedAudioURL = nil; dubbedAudioSignature = nil } }
    }
    @Published public var endTime: CMTime {
        willSet { if endTime != newValue { onModified?() } }
        didSet { if endTime != oldValue { dubbedAudioURL = nil; dubbedAudioSignature = nil } }
    }
    @Published public var originalText: String {
        willSet { if originalText != newValue { onModified?() } }
        didSet { if originalText != oldValue { words = []; naturalSpeech = nil; dubbedAudioURL = nil; dubbedAudioSignature = nil; translationNeedsReview = !translatedText.isEmpty } }
    }
    @Published public var translatedText: String {
        willSet { if translatedText != newValue { onModified?() } }
        didSet { if translatedText != oldValue { naturalSpeech = nil; dubbedAudioURL = nil; dubbedAudioSignature = nil } }
    }
    @Published public var words: [WordToken] {
        willSet { if words != newValue { onModified?() } }
    }

    // Natural speech is independent of timing and is deliberately not persisted.
    @Published public var naturalSpeech: NaturalSpeechAudio?
    public var currentNaturalSpeech: NaturalSpeechAudio? {
        guard let audio = naturalSpeech, audio.text == translatedText,
              FileManager.default.fileExists(atPath: audio.url.path) else { return nil }
        return audio
    }

    public var dubbingTimingIssue: String? {
        guard let audio = currentNaturalSpeech else { return nil }
        do { _ = try DubbingPacing.rate(naturalDuration: audio.duration, availableDuration: durationSeconds); return nil }
        catch { return error.localizedDescription }
    }

    // 配音缓存状态
    public var dubbedAudioSignature: String?
    @Published public var translationNeedsReview = false {
        willSet { if newValue != translationNeedsReview { onModified?() } }
    }
    @Published public var dubbedAudioURL: URL?
    @Published public var isGeneratingAudio: Bool = false

    public init(
        id: UUID = UUID(),
        startTime: CMTime,
        endTime: CMTime,
        originalText: String,
        translatedText: String = "",
        words: [WordToken] = [],
        dubbedAudioURL: URL? = nil,
        dubbedAudioSignature: String? = nil,
        translationNeedsReview: Bool = false,
        sourceStartTime: CMTime? = nil,
        sourceEndTime: CMTime? = nil,
        naturalSpeech: NaturalSpeechAudio? = nil
    ) {
        self.id = id
        self.naturalSpeech = naturalSpeech
        self.sourceStartTime = sourceStartTime ?? startTime
        self.sourceEndTime = sourceEndTime ?? endTime
        self.startTime = startTime
        self.endTime = endTime
        self.originalText = originalText
        self.translatedText = translatedText
        self.words = words
        self.dubbedAudioURL = dubbedAudioURL
        self.dubbedAudioSignature = dubbedAudioSignature
        self.translationNeedsReview = translationNeedsReview
    }

    public func audioSignature(voice: String) -> String {
        let input = "anchored-pacing-v1|\(translatedText)|\(voice)|\(startTime.value)/\(startTime.timescale)|\(endTime.value)/\(endTime.timescale)"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func hasCurrentAudio(voice: String) -> Bool {
        !translationNeedsReview && dubbedAudioSignature == audioSignature(voice: voice) && dubbedAudioURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
    }

    public func snapshot() -> SubtitleItem {
        SubtitleItem(id: id, startTime: startTime, endTime: endTime, originalText: originalText, translatedText: translatedText, words: words, dubbedAudioURL: dubbedAudioURL, dubbedAudioSignature: dubbedAudioSignature, translationNeedsReview: translationNeedsReview, sourceStartTime: sourceStartTime, sourceEndTime: sourceEndTime, naturalSpeech: naturalSpeech)
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
        case id, startTime, endTime, originalText, translatedText, words, dubbedAudioURL, dubbedAudioSignature, translationNeedsReview, sourceStartTime, sourceEndTime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        let codableStart = try container.decode(CodableCMTime.self, forKey: .startTime)
        let codableEnd = try container.decode(CodableCMTime.self, forKey: .endTime)
        self.sourceStartTime = try container.decodeIfPresent(CodableCMTime.self, forKey: .sourceStartTime)?.cmTime ?? codableStart.cmTime
        self.sourceEndTime = try container.decodeIfPresent(CodableCMTime.self, forKey: .sourceEndTime)?.cmTime ?? codableEnd.cmTime
        self.startTime = codableStart.cmTime
        self.endTime = codableEnd.cmTime
        self.originalText = try container.decode(String.self, forKey: .originalText)
        self.translatedText = try container.decode(String.self, forKey: .translatedText)
        self.words = try container.decode([WordToken].self, forKey: .words)
        self.dubbedAudioURL = try container.decodeIfPresent(URL.self, forKey: .dubbedAudioURL)
        self.dubbedAudioSignature = try container.decodeIfPresent(String.self, forKey: .dubbedAudioSignature)
        self.translationNeedsReview = try container.decodeIfPresent(Bool.self, forKey: .translationNeedsReview) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(CodableCMTime(cmTime: sourceStartTime), forKey: .sourceStartTime)
        try container.encode(CodableCMTime(cmTime: sourceEndTime), forKey: .sourceEndTime)
        try container.encode(CodableCMTime(cmTime: startTime), forKey: .startTime)
        try container.encode(CodableCMTime(cmTime: endTime), forKey: .endTime)
        try container.encode(originalText, forKey: .originalText)
        try container.encode(translatedText, forKey: .translatedText)
        try container.encode(words, forKey: .words)
        try container.encodeIfPresent(dubbedAudioURL, forKey: .dubbedAudioURL)
        try container.encodeIfPresent(dubbedAudioSignature, forKey: .dubbedAudioSignature)
        try container.encode(translationNeedsReview, forKey: .translationNeedsReview)
    }
}
