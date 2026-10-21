import Foundation
import CoreMedia

/// Anchors short contexts to the video while balancing utterance timing inside them.
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

    /// A context shares one speech budget. Only its outer source boundaries are
    /// fixed; internal utterances can move to balance their measured speaking rate.
    /// No speech, gap or timing debt crosses a context boundary.
    public func matchTimelineToTranslation(
        items: [SubtitleItem], language: String = "zh", videoDuration: Double? = nil,
        contextGroups: [[UUID]]? = nil
    ) -> [SubtitleItem] {
        guard let sourceEnds = validatedSourceEnds(items, videoDuration: videoDuration) else { return items }
        let clusters = validatedGroups(contextGroups, items: items)
            ?? localGroups(items: items)
        var output: [SubtitleItem] = []
        for cluster in clusters {
            let first = cluster.first!, last = cluster.last!
            let begin = items[first].sourceStartTime.secondsValue
            let finish = sourceEnds[last].secondsValue
            let span = finish - begin
            let natural = cluster.map { index in
                items[index].translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? sourceEnds[index].secondsValue - items[index].sourceStartTime.secondsValue
                    : expectedDurationForSubtitle(items[index], language: language)
            }
            var pauses = cluster.dropLast().map { index in
                min(0.12, max(0.04, items[index + 1].sourceStartTime.secondsValue - sourceEnds[index].secondsValue))
            }
            let totalPause = pauses.reduce(0, +)
            let pauseScale = totalPause > 0 ? min(1, span * 0.08 / totalPause) : 1
            pauses = pauses.map { $0 * pauseScale }
            let budget = span - pauses.reduce(0, +)
            let commonRate = max(1, natural.reduce(0, +) / budget)
            let durations = natural.map { $0 / commonRate }
            // When natural speech fits, retain original internal positions where
            // possible, distributing silence instead of rushing all rows forward.
            var latest = Array(repeating: finish, count: cluster.count)
            latest[cluster.count - 1] = finish - durations.last!
            if cluster.count > 1 {
                for i in stride(from: cluster.count - 2, through: 0, by: -1) {
                    latest[i] = latest[i + 1] - pauses[i] - durations[i]
                }
            }
            var previousEnd = begin
            for (position, index) in cluster.enumerated() {
                let earliest = position == 0 ? begin : previousEnd + pauses[position - 1]
                let start = position == 0 ? begin
                    : max(earliest, min(items[index].sourceStartTime.secondsValue, latest[position]))
                let end = position == cluster.count - 1 ? finish : start + durations[position]
                let row = items[index].snapshot()
                row.timingContext = (items[first].sourceStartTime, sourceEnds[last])
                row.startTime = position == 0 ? items[first].sourceStartTime : .from(seconds: start)
                row.endTime = position == cluster.count - 1 ? sourceEnds[last] : .from(seconds: end)
                output.append(row)
                previousEnd = end
            }
        }
        return output
    }

    private func validatedGroups(_ groups: [[UUID]]?, items: [SubtitleItem]) -> [[Int]]? {
        guard let groups, groups.allSatisfy({ !$0.isEmpty }), groups.flatMap({ $0 }) == items.map(\.id) else { return nil }
        var offset = 0
        var result: [[Int]] = []
        for group in groups {
            let indices = Array(offset..<(offset + group.count))
            if group.count > 1 {
                guard items[indices.last!].sourceEndTime.secondsValue - items[offset].sourceStartTime.secondsValue <= 16 else { return nil }
                for index in indices.dropFirst() where isContextGap(items[index - 1], items[index]) { return nil }
            }
            result.append(indices)
            offset += group.count
        }
        return result
    }

    private func isContextGap(_ left: SubtitleItem, _ right: SubtitleItem) -> Bool {
        CMTimeSubtract(right.sourceStartTime, left.sourceEndTime) >= CMTime(value: 65, timescale: 100)
    }

    private func localGroups(items: [SubtitleItem]) -> [[Int]] {
        var groups: [[Int]] = []
        for index in items.indices {
            if let current = groups.last, let first = current.first, let previous = current.last,
               current.count < 5, !isContextGap(items[previous], items[index]),
               items[index].sourceEndTime.secondsValue - items[first].sourceStartTime.secondsValue <= 16 {
                groups[groups.count - 1].append(index)
            } else { groups.append([index]) }
        }
        // A row-count limit must not isolate the last closing remark. Rebalance
        // the two adjacent groups while retaining their combined outer boundary.
        for index in groups.indices.dropFirst() {
            guard groups[index].count == 1, groups[index - 1].count >= 3,
                  let moved = groups[index - 1].last, let last = groups[index].last,
                  !isContextGap(items[moved], items[groups[index][0]]),
                  items[last].sourceEndTime.secondsValue - items[moved].sourceStartTime.secondsValue <= 16 else { continue }
            groups[index - 1].removeLast()
            groups[index].insert(moved, at: 0)
        }
        return groups
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
        planContexts: (([SpeechClusterEntry]) async throws -> [[UUID]])? = nil,
        status: @MainActor (String) -> Void = { _ in },
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
        var contexts: [[UUID]]?
        if let planContexts {
            await status("正在识别局部语境…")
            do {
                contexts = try await planContexts(measured.map {
                    SpeechClusterEntry(id: $0.id, source: $0.originalText, translation: $0.translatedText,
                        start: $0.sourceStartTime.secondsValue, end: $0.sourceEndTime.secondsValue,
                        naturalDuration: expectedDurationForSubtitle($0, language: language))
                })
            } catch { try Task.checkCancellation() }
        }
        let planned = matchTimelineToTranslation(items: measured, language: language, videoDuration: videoDuration, contextGroups: contexts)
        var rendered: [URL] = []
        var completed = false
        defer {
            if !completed { for url in rendered { try? FileManager.default.removeItem(at: url) } }
        }
        for (index, row) in planned.enumerated() where row.currentNaturalSpeech != nil {
            try Task.checkCancellation()
            await status("准备匹配配音 \(index + 1)/\(planned.count)")
            // Pacing is advisory: every translated sentence gets playable audio.
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
