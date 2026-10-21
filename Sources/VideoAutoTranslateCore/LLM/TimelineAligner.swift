import Foundation
import CoreMedia

/// Keeps every utterance at its immutable source anchor; timing is never accumulated.
public final class TimelineAligner {
    public init() {}

    public static func pacingIssues(items: [SubtitleItem], language: String) -> Set<UUID> {
        Set(items.filter {
            let duration = $0.currentNaturalSpeech?.duration
                ?? estimateNaturalDuration(text: $0.translatedText.isEmpty ? $0.originalText : $0.translatedText, language: language)
            return duration > $0.durationSeconds * DubbingPacing.maximumRate + DubbingPacing.timeTolerance
        }.map(\.id))
    }

    /// 估算特定语言文本的自然舒适发音时长 (秒)
    /// - Parameters:
    ///   - text: 文本内容
    ///   - language: 目标语言代码（如 "zh"、"en"、"ja" 等）
    /// - Returns: 自然舒适语速下的朗读秒数（含轻微起伏余量）
    public static func estimateNaturalDuration(text: String, language: String = "zh") -> Double {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return 0.5 }

        let isCJK = language.lowercased().hasPrefix("zh") ||
                    language.lowercased().hasPrefix("ja") ||
                    language.lowercased().hasPrefix("ko") ||
                    clean.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }

        if isCJK {
            // 中文/日文/韩文：舒适朗读语速约为每秒 3.8 ~ 4.2 个字
            // 基础换气/轻停顿基底 0.25 秒
            let charCount = clean.filter { !$0.isWhitespace }.count
            let baseDuration = Double(charCount) / 3.9
            return max(0.60, baseDuration + 0.22)
        } else {
            // 西文/拉丁语系：按有效词数计算，舒适朗读语速约为每秒 2.5 ~ 2.8 个词
            let words = clean.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            let wordCount = max(1, words.count)
            let baseDuration = Double(wordCount) / 2.6
            return max(0.60, baseDuration + 0.22)
        }
    }


    public func expectedDurationForSubtitle(_ item: SubtitleItem, language: String = "zh") -> Double {
        item.currentNaturalSpeech?.duration ?? Self.estimateNaturalDuration(
            text: item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? item.originalText : item.translatedText, language: language)
    }

    /// Short speech leaves silence in place. Long speech can borrow at most 500ms
    /// after its source interval, without moving the following utterance.
    /// Text estimates are for offline suggestions only; the app measures TTS first.
    /// Source overlaps up to 30ms reduce the preceding usable interval only.
    /// Without videoDuration, the final utterance cannot borrow beyond its source end.
    public func matchTimelineToTranslation(
        items: [SubtitleItem], language: String = "zh", videoDuration: Double? = nil
    ) -> [SubtitleItem] {
        guard let sourceEnds = validatedSourceEnds(items, videoDuration: videoDuration) else { return items }
        return items.enumerated().map { index, item in
            let start = item.sourceStartTime.secondsValue
            let sourceEnd = sourceEnds[index].secondsValue
            let nextStart = index + 1 < items.count ? items[index + 1].sourceStartTime.secondsValue : videoDuration
            let gap = nextStart.map { max(0, $0 - sourceEnd) } ?? 0
            let pause = min(0.08, gap)
            var latestEnd = sourceEnd + min(0.5, max(0, gap - pause))
            if let videoDuration { latestEnd = min(latestEnd, videoDuration) }
            let natural = item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? sourceEnd - start : expectedDurationForSubtitle(item, language: language)
            let end = min(latestEnd, start + max(0.1, natural))
            let result = item.snapshot()
            result.startTime = item.sourceStartTime
            result.endTime = .from(seconds: end)
            if index + 1 < items.count {
                // Keep sub-millisecond anchors exact when the proposed end rounds up.
                result.endTime = min(result.endTime, items[index + 1].sourceStartTime)
            }
            return result
        }
    }

    /// No timestamp-generating language model participates in scheduling.
    /// Kept as a source-compatible entry point for existing clients.
    public func matchTimelineWithLLM(
        items: [SubtitleItem], config: LLMConfiguration, client: OpenAICompatibleClient,
        videoDuration: Double? = nil
    ) async -> [SubtitleItem] {
        matchTimelineToTranslation(items: items, language: config.targetLanguage, videoDuration: videoDuration)
    }

    /// Measures normal-speed audio on isolated snapshots; failures never substitute
    /// a character estimate for a successfully measured dubbing proposal.
    public func matchTimelineUsingSpeech(
        items: [SubtitleItem], language: String, voice: String,
        ttsService: TTSServiceProtocol, manager: SubtitleManager,
        videoDuration: Double,
        progress: @MainActor (Int, Int) -> Void = { _, _ in }
    ) async throws -> [SubtitleItem] {
        guard validatedSourceEnds(items, videoDuration: videoDuration) != nil else {
            throw TTSError.synthesisFailed("原始时间重叠超过 30ms、修正后不足 100ms、存在无效值或超出视频范围，无法自动匹配；请重新分句或跳过匹配进行手动调时。")
        }
        let measured = items.map { $0.snapshot() }
        for (index, row) in measured.enumerated() {
            try Task.checkCancellation()
            guard !row.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            _ = try await manager.prepareNaturalSpeech(item: row, ttsService: ttsService, voice: voice)
            await progress(index + 1, measured.count)
        }
        try Task.checkCancellation()
        let planned = matchTimelineToTranslation(items: measured, language: language, videoDuration: videoDuration)
        var rendered: [URL] = []
        var completed = false
        defer {
            if !completed { for url in rendered { try? FileManager.default.removeItem(at: url) } }
        }
        for row in planned where row.currentNaturalSpeech != nil {
            try Task.checkCancellation()
            // Infeasible sentences remain reviewable conflicts. Do not render a
            // rushed substitute or shift another sentence to hide the problem.
            guard row.dubbingTimingIssue == nil else {
                row.dubbedAudioURL = nil
                row.dubbedAudioSignature = nil
                continue
            }
            let previousURL = row.dubbedAudioURL
            try await manager.renderMatchedSpeech(item: row, voice: voice)
            if let url = row.dubbedAudioURL, url != previousURL { rendered.append(url) }
        }
        try Task.checkCancellation()
        completed = true
        return planned
    }

    /// Validate and normalize usable ends without rewriting immutable ASR anchors.
    /// Compare overlap as CMTime so exactly 30ms is accepted at any time offset.
    private func validatedSourceEnds(_ items: [SubtitleItem], videoDuration: Double?) -> [CMTime]? {
        if let videoDuration, !videoDuration.isFinite || videoDuration <= 0 { return nil }
        let overlapTolerance = CMTime(value: 30, timescale: 1000)
        var ends: [CMTime] = []
        for (index, item) in items.enumerated() {
            let start = CMTimeGetSeconds(item.sourceStartTime)
            let end = CMTimeGetSeconds(item.sourceEndTime)
            guard start.isFinite, end.isFinite, start >= 0,
                  end - start >= 0.0999, videoDuration.map({ end <= $0 }) ?? true else { return nil }
            if let previousEnd = ends.last, item.sourceStartTime < previousEnd {
                guard CMTimeSubtract(previousEnd, item.sourceStartTime) <= overlapTolerance,
                      start - items[index - 1].sourceStartTime.secondsValue >= 0.0999 else { return nil }
                ends[index - 1] = item.sourceStartTime
            }
            ends.append(item.sourceEndTime)
        }
        return ends
    }
}
