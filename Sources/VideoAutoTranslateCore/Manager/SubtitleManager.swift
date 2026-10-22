import Foundation
import CoreMedia
import AVFoundation

/// 字幕管理与交互剪辑管理器（核心业务逻辑）
public final class SubtitleManager {
    private let timePitchEngine = TimePitchEngine()

    public init() {}

    public static func characterOffset(in text: String, utf16Offset: Int) -> Int? {
        guard utf16Offset >= 0, utf16Offset <= text.utf16.count,
              let index = String.Index(text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset), within: text),
              index == text.endIndex || text.indices.contains(index) else { return nil }
        return text.distance(from: text.startIndex, to: index)
    }

    /// 依据用户在原文中的光标位置精准执行词级时间戳拆分 (Cmd+B)
    /// 拆字幕只能拆原始字幕，必须传入有效光标下标 (0 < charIndex < text.count)
    /// 翻译的字幕无法切分且不做改动，完整保留在前半句（除非用户后续做再次翻译）
    /// - Parameters:
    ///   - item: 待切分的字幕项
    ///   - charIndex: 光标在 originalText 中的字符下标 (0 ~ count)
    /// - Returns: 切分后的前后两个字幕项
    public func split(item: SubtitleItem, atCharIndex charIndex: Int, translatedParts: (String, String)? = nil) -> (SubtitleItem, SubtitleItem)? {
        let text = item.originalText
        guard charIndex > 0 && charIndex < text.count else { return nil }

        var firstPartText = ""
        var secondPartText = ""
        var splitTime = item.startTime
        var firstWords: [WordToken] = []
        var secondWords: [WordToken] = []

        // 若拥有词级时间序列，根据在文本中的实际出现范围建立拆分提案，吸附到词边界 (FU03)
        if !item.words.isEmpty {
            var wordRanges: [(word: WordToken, range: Range<String.Index>, startOffset: Int, endOffset: Int)] = []
            var searchRange = text.startIndex..<text.endIndex
            for word in item.words {
                var foundRange = text.range(of: word.text, options: [.caseInsensitive], range: searchRange)
                if foundRange == nil {
                    let clean = word.text.trimmingCharacters(in: .punctuationCharacters)
                    if !clean.isEmpty {
                        foundRange = text.range(of: clean, options: [.caseInsensitive], range: searchRange)
                    }
                }
                if let found = foundRange {
                    let start = text.distance(from: text.startIndex, to: found.lowerBound)
                    let end = text.distance(from: text.startIndex, to: found.upperBound)
                    wordRanges.append((word, found, start, end))
                    searchRange = found.upperBound..<text.endIndex
                }
            }

            if wordRanges.count >= 2 {
                // 寻找最符合用户光标意图的切分词边界 (0 <= bestSplitIdx < wordRanges.count - 1)
                let bestSplitIdx = (0..<(wordRanges.count - 1)).min { lhs, rhs in
                    func distance(_ boundary: Int) -> Int {
                        let lower = wordRanges[boundary].endOffset
                        let upper = wordRanges[boundary + 1].startOffset
                        return charIndex < lower ? lower - charIndex : max(0, charIndex - upper)
                    }
                    return distance(lhs) < distance(rhs)
                }!

                firstWords = Array(wordRanges[0...bestSplitIdx].map { $0.word })
                secondWords = Array(wordRanges[(bestSplitIdx + 1)...].map { $0.word })

                // 文本切分点以第二句首词的起始位置为界，完整保留前半句末尾所有标点符号
                let nextWordStartRange = wordRanges[bestSplitIdx + 1].range
                firstPartText = String(text[..<nextWordStartRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                secondPartText = String(text[nextWordStartRange.lowerBound...]).trimmingCharacters(in: .whitespaces)

                // 时间切分点：取左句末词结束时间点 (FU03)
                splitTime = firstWords.last?.endCMTime ?? item.startTime
            } else {
                // 词序列少于 2 个匹配时，回退至字符截断
                let index = text.index(text.startIndex, offsetBy: charIndex)
                firstPartText = String(text[..<index]).trimmingCharacters(in: .whitespaces)
                secondPartText = String(text[index...]).trimmingCharacters(in: .whitespaces)
                let ratio = text.count > 0 ? Double(charIndex) / Double(text.count) : 0.5
                splitTime = CMTimeAdd(item.startTime, CMTime.from(seconds: item.durationSeconds * ratio))
                firstWords = item.words.filter { $0.endCMTime <= splitTime }
                secondWords = item.words.filter { $0.startCMTime >= splitTime }
            }
        } else {
            // 保底机制：无词级序列时按字符比例切分
            let index = text.index(text.startIndex, offsetBy: charIndex)
            firstPartText = String(text[..<index]).trimmingCharacters(in: .whitespaces)
            secondPartText = String(text[index...]).trimmingCharacters(in: .whitespaces)
            let ratio = text.count > 0 ? Double(charIndex) / Double(text.count) : 0.5
            splitTime = CMTimeAdd(item.startTime, CMTime.from(seconds: item.durationSeconds * ratio))
        }

        guard !firstPartText.isEmpty && !secondPartText.isEmpty else { return nil }

        // 保证时间切分点处于有效区间且大于起始时间
        let minStep = CMTime(value: 20, timescale: 1000) // 20ms
        let doubleMinStep = CMTime(value: 40, timescale: 1000) // 40ms
        if item.duration > doubleMinStep {
            let earliest = CMTimeAdd(item.startTime, minStep)
            let latest = CMTimeSubtract(item.endTime, minStep)
            if splitTime < earliest {
                splitTime = earliest
            } else if splitTime > latest {
                splitTime = latest
            }
        } else {
            splitTime = CMTimeAdd(item.startTime, CMTime.from(seconds: item.durationSeconds * 0.5))
        }

        // 翻译的字幕无法切分且不做改动，完整保留在前半句（除非后续用户再次触发翻译）
        let existingTrans = item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let part1Trans: String
        let part2Trans: String
        if let (p1, p2) = translatedParts {
            part1Trans = p1
            part2Trans = p2
        } else if !existingTrans.isEmpty {
            part1Trans = existingTrans
            part2Trans = ""
        } else {
            part1Trans = ""
            part2Trans = ""
        }

        let part1 = SubtitleItem(
            startTime: item.startTime,
            endTime: splitTime,
            originalText: firstPartText,
            translatedText: part1Trans,
            words: firstWords,
            translationNeedsReview: item.translationNeedsReview && !part1Trans.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            sourceStartTime: item.sourceStartTime,
            sourceEndTime: firstWords.last?.endCMTime ?? splitTime
        )

        let part2 = SubtitleItem(
            startTime: splitTime,
            endTime: item.endTime,
            originalText: secondPartText,
            translatedText: part2Trans,
            words: secondWords,
            translationNeedsReview: item.translationNeedsReview && !part2Trans.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            sourceStartTime: secondWords.first?.startCMTime ?? splitTime,
            sourceEndTime: item.sourceEndTime
        )

        return (part1, part2)
    }

    /// 将选中的多条相邻字幕合并为单条 (Cmd+J)
    public func merge(items: [SubtitleItem]) -> SubtitleItem? {
        guard items.count >= 2 else { return nil }

        // 依据起始时间严格排序
        let sorted = items.sorted { $0.startTime < $1.startTime }
        guard let first = sorted.first else { return nil }

        // R15: 计算所有选中区间的最大终点，防止嵌套区间反而缩短总时长
        let minStart = sorted.map { $0.startTime }.min() ?? first.startTime
        let maxEnd = sorted.map { $0.endTime }.max() ?? first.endTime

        let combinedOriginal = sorted.map { $0.originalText.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        let combinedTranslated = sorted.map { $0.translatedText.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let combinedWords = sorted.flatMap { $0.words }.sorted { $0.startCMTime < $1.startCMTime }

        return SubtitleItem(
            startTime: minStart,
            endTime: maxEnd,
            originalText: combinedOriginal,
            translatedText: combinedTranslated,
            words: combinedWords,
            translationNeedsReview: !combinedTranslated.isEmpty && sorted.contains {
                $0.translationNeedsReview || $0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            },
            sourceStartTime: sorted.map(\.sourceStartTime).min(),
            sourceEndTime: sorted.map(\.sourceEndTime).max()
        )
    }

    /// Cache the measured, edge-trimmed normal-speed speech independently of timing.
    public func prepareNaturalSpeech(
        item: SubtitleItem, ttsService: TTSServiceProtocol, voice: String = "zh-CN"
    ) async throws -> NaturalSpeechAudio {
        try Task.checkCancellation()
        guard !item.translationNeedsReview else { throw TTSError.synthesisFailed("译文待复核，请先确认目标语言与内容") }
        let text = item.translatedText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TTSError.emptyText }
        if let cached = item.currentNaturalSpeech, cached.voice == voice { return cached }
        let temp = FileManager.default.temporaryDirectory
        let raw = temp.appendingPathComponent("tts-raw-\(UUID()).wav")
        let trimmed = temp.appendingPathComponent("tts-natural-\(UUID()).wav")
        var retained = false
        defer {
            try? FileManager.default.removeItem(at: raw)
            if !retained { try? FileManager.default.removeItem(at: trimmed) }
        }
        _ = try await ttsService.synthesize(text: text, voice: voice, outputURL: raw)
        try Task.checkCancellation()
        // Check before decoding as well as before installation; stale or failed TTS
        // output must never replace the cache of an edited utterance.
        guard item.translatedText == text, !item.translationNeedsReview else { throw CancellationError() }
        let duration = try NaturalSpeechAudio.trimEdges(inputURL: raw, outputURL: trimmed)
        let audio = NaturalSpeechAudio(url: trimmed, duration: duration, text: text, voice: voice)
        try Task.checkCancellation()
        try await MainActor.run {
            guard item.translatedText == text, !item.translationNeedsReview, !Task.isCancelled else { throw CancellationError() }
            item.naturalSpeech = audio
        }
        retained = true
        return audio
    }

    /// Generation only consumes confirmed audio, or publishes natural/rate-adjusted
    /// speech to fit the subtitle interval.
    public func reDub(
        item: SubtitleItem, ttsService: TTSServiceProtocol, voice: String = "zh-CN"
    ) async throws {
        try Task.checkCancellation()
        if item.hasCurrentAudio(voice: voice) { return }
        await MainActor.run { item.isGeneratingAudio = true }
        defer { Task { @MainActor in item.isGeneratingAudio = false } }
        let signature = item.audioSignature(voice: voice)
        let natural = try await prepareNaturalSpeech(item: item, ttsService: ttsService, voice: voice)
        let rate = try DubbingPacing.rate(naturalDuration: natural.duration, availableDuration: item.durationSeconds)
        try await publishSpeech(item: item, natural: natural, voice: voice, signature: signature, rate: rate)
    }

    /// Called only while constructing an explicit timeline proposal, never by
    /// generation, audition or export. It renders exactly what the user reviews.
    internal func renderMatchedSpeech(item: SubtitleItem, voice: String) async throws {
        if item.hasCurrentAudio(voice: voice) { return }
        guard let natural = item.currentNaturalSpeech, natural.voice == voice else {
            throw TTSError.synthesisFailed("缺少所选音色的实测配音，请重新匹配译文时间轴。")
        }
        let rate = try DubbingPacing.rate(naturalDuration: natural.duration, availableDuration: item.durationSeconds)
        try await publishSpeech(item: item, natural: natural, voice: voice, signature: item.audioSignature(voice: voice), rate: rate)
    }

    private func publishSpeech(item: SubtitleItem, natural: NaturalSpeechAudio, voice: String, signature: String, rate: Double) async throws {
        try Task.checkCancellation()
        guard item.audioSignature(voice: voice) == signature else { throw CancellationError() }
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("dubbed-\(UUID()).wav")
        defer { if item.dubbedAudioURL != result { try? FileManager.default.removeItem(at: result) } }
        if rate == 1 {
            try FileManager.default.copyItem(at: natural.url, to: result)
        } else {
            // Large ratios are exceptional quality warnings, not missing speech.
            // Chain supported render rates without clipping words or moving starts.
            var input = natural.url
            var remainingRate = rate
            var intermediate: [URL] = []
            defer { for url in intermediate { try? FileManager.default.removeItem(at: url) } }
            while remainingRate > 2.5 {
                try Task.checkCancellation()
                let next = FileManager.default.temporaryDirectory.appendingPathComponent("speech-fit-\(UUID()).wav")
                intermediate.append(next)
                try timePitchEngine.changeSpeed(inputURL: input, outputURL: next, rate: 2.5)
                input = next
                let file = try AVAudioFile(forReading: next)
                remainingRate = Double(file.length) / file.processingFormat.sampleRate / item.durationSeconds
            }
            try timePitchEngine.changeSpeed(inputURL: input, outputURL: result, rate: Float(max(1, remainingRate)))
        }
        try Task.checkCancellation()
        let actual = try await AVURLAsset(url: result).load(.duration).secondsValue
        let tolerance = max(DubbingPacing.timeTolerance, 0.06)
        guard actual.isFinite, actual > 0, actual <= item.durationSeconds + tolerance else {
            throw TTSError.synthesisFailed("配音渲染时长超出字幕范围，请重新匹配时间轴后试听。")
        }
        try await MainActor.run {
            guard !Task.isCancelled, item.audioSignature(voice: voice) == signature else { throw CancellationError() }
            item.dubbedAudioURL = result
            item.dubbedAudioSignature = signature
            item.dubbedRate = rate
        }
    }
}
