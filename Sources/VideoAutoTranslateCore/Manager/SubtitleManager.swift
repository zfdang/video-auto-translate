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

    /// 寻找字符串最自然的断句下标（优先标点、空格，其次中点）
    public static func findNaturalSplitIndex(in text: String) -> Int {
        let count = text.count
        guard count > 1 else { return max(1, count) }
        let mid = count / 2
        let chars = Array(text)
        let punctuations: Set<Character> = [" ", "，", "。", "；", "！", "？", "、", ",", ";", "!", "?"]

        var bestIdx = mid
        var minDiff = Int.max
        let window = max(1, count / 3)
        for offset in -window...window {
            let idx = mid + offset
            if idx > 0 && idx < chars.count {
                if punctuations.contains(chars[idx]) {
                    let diff = abs(offset)
                    if diff < minDiff {
                        minDiff = diff
                        bestIdx = idx + 1
                    }
                }
            }
        }
        return max(1, min(count - 1, bestIdx))
    }

    /// 将已有的译文按时间比例智能切分为两段（优先吸附中英文标点）
    public static func splitTranslatedText(_ text: String, ratio: Double) -> (String, String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return ("", "") }
        if clean.count == 1 {
            return (clean, "")
        }
        let clampedRatio = max(0.05, min(0.95, ratio))
        let targetIndex = max(1, min(clean.count - 1, Int(round(Double(clean.count) * clampedRatio))))
        let chars = Array(clean)
        let punctuations: Set<Character> = ["，", "。", "；", "！", "？", "、", ",", ";", "!", "?", " "]

        var bestIndex = targetIndex
        var minDiff = Int.max
        let window = max(1, clean.count / 4)
        for offset in -window...window {
            let idx = targetIndex + offset
            if idx > 0 && idx < chars.count {
                if punctuations.contains(chars[idx - 1]) {
                    let diff = abs(offset)
                    if diff < minDiff {
                        minDiff = diff
                        bestIndex = idx
                    }
                }
            }
        }

        var p1 = String(chars[0..<bestIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        var p2 = String(chars[bestIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if p1.isEmpty {
            p1 = String(chars[0..<1])
            p2 = String(chars[1...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (p1, p2)
    }

    /// 依据用户光标位置精准执行词级时间戳拆分 (Cmd+B)
    /// 无论何时均允许拆分：有译文时自适应切分译文，无精确光标时中点自然切分
    /// - Parameters:
    ///   - item: 待切分的字幕项
    ///   - charIndex: 光标在 originalText 中的字符下标 (0 ~ count)
    /// - Returns: 切分后的前后两个字幕项
    public func split(item: SubtitleItem, atCharIndex charIndex: Int, translatedParts: (String, String)? = nil) -> (SubtitleItem, SubtitleItem)? {
        let text = item.originalText

        let splitIdx: Int
        if text.count <= 1 {
            splitIdx = text.count
        } else if charIndex > 0 && charIndex < text.count {
            splitIdx = charIndex
        } else {
            splitIdx = Self.findNaturalSplitIndex(in: text)
        }

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
                        return splitIdx < lower ? lower - splitIdx : max(0, splitIdx - upper)
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
                let index = text.index(text.startIndex, offsetBy: splitIdx)
                firstPartText = String(text[..<index]).trimmingCharacters(in: .whitespaces)
                secondPartText = String(text[index...]).trimmingCharacters(in: .whitespaces)
                let ratio = text.count > 0 ? Double(splitIdx) / Double(text.count) : 0.5
                splitTime = CMTimeAdd(item.startTime, CMTime.from(seconds: item.durationSeconds * ratio))
                firstWords = item.words.filter { $0.endCMTime <= splitTime }
                secondWords = item.words.filter { $0.startCMTime >= splitTime }
            }
        } else {
            // 保底机制：无词级序列时按字符比例切分
            let index = text.index(text.startIndex, offsetBy: splitIdx)
            firstPartText = String(text[..<index]).trimmingCharacters(in: .whitespaces)
            secondPartText = String(text[index...]).trimmingCharacters(in: .whitespaces)
            let ratio = text.count > 0 ? Double(splitIdx) / Double(text.count) : 0.5
            splitTime = CMTimeAdd(item.startTime, CMTime.from(seconds: item.durationSeconds * ratio))
        }

        // 确保两段文本不完全为空
        if firstPartText.isEmpty && secondPartText.isEmpty {
            firstPartText = text
        } else if firstPartText.isEmpty {
            firstPartText = String(secondPartText.prefix(max(1, secondPartText.count / 2)))
            secondPartText = String(secondPartText.dropFirst(firstPartText.count)).trimmingCharacters(in: .whitespaces)
        } else if secondPartText.isEmpty {
            let half = max(1, firstPartText.count / 2)
            let orig = firstPartText
            firstPartText = String(orig.prefix(half)).trimmingCharacters(in: .whitespaces)
            secondPartText = String(orig.dropFirst(half)).trimmingCharacters(in: .whitespaces)
        }

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

        // 无论何时，处理已有译文（优先使用传入的切分结果，否则自适应比例分割译文）
        let existingTrans = item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let part1Trans: String
        let part2Trans: String
        if let (p1, p2) = translatedParts {
            part1Trans = p1
            part2Trans = p2
        } else if !existingTrans.isEmpty {
            let ratio = item.durationSeconds > 0 ? max(0.1, min(0.9, (splitTime - item.startTime).secondsValue / item.durationSeconds)) : 0.5
            let splitTrans = Self.splitTranslatedText(existingTrans, ratio: ratio)
            part1Trans = splitTrans.0
            part2Trans = splitTrans.1
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
            sourceStartTime: item.sourceStartTime,
            sourceEndTime: firstWords.last?.endCMTime ?? splitTime
        )

        let part2 = SubtitleItem(
            startTime: splitTime,
            endTime: item.endTime,
            originalText: secondPartText,
            translatedText: part2Trans,
            words: secondWords,
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
            sourceStartTime: sorted.map(\.sourceStartTime).min(),
            sourceEndTime: sorted.map(\.sourceEndTime).max()
        )
    }

    /// 单句增量快速重配音与语速自动缩放（0.5秒内快速试听）
    /// - Parameters:
    ///   - item: 需更新配音的单条字幕
    ///   - ttsService: 语音合成服务
    ///   - voice: 配音音色标识
    public func reDub(
        item: SubtitleItem,
        ttsService: TTSServiceProtocol,
        voice: String = "zh-CN"
    ) async throws {
        let textToSpeak = item.translatedText
        guard !item.translationNeedsReview else { throw TTSError.synthesisFailed("译文待复核，请先确认目标语言与内容") }
        guard !textToSpeak.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TTSError.emptyText
        }

        await MainActor.run {
            item.isGeneratingAudio = true
        }

        defer {
            Task { @MainActor in
                item.isGeneratingAudio = false
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
        let signature = item.audioSignature(voice: voice)
        let requestID = UUID().uuidString
        let rawTTSURL = tempDir.appendingPathComponent("raw_tts_\(requestID).wav")
        let finalStretchedURL = tempDir.appendingPathComponent("dubbed_\(requestID).wav")

        defer {
            if item.dubbedAudioURL != rawTTSURL { try? FileManager.default.removeItem(at: rawTTSURL) }
            if item.dubbedAudioURL != finalStretchedURL { try? FileManager.default.removeItem(at: finalStretchedURL) }
        }
        // 1. 合成原始语速语音
        _ = try await ttsService.synthesize(text: textToSpeak, voice: voice, outputURL: rawTTSURL)

        try Task.checkCancellation()
        guard item.audioSignature(voice: voice) == signature else { throw CancellationError() }
        // 2. 检测语音实际发音时长
        let rawAsset = AVURLAsset(url: rawTTSURL)
        let rawDuration = try await rawAsset.load(.duration)
        let targetDuration = item.duration

        // 3. 计算语速伸缩比率 R = rawDuration / targetDuration
        let rate = Float(rawDuration.secondsValue / max(0.2, targetDuration.secondsValue))

        // Fall back only to complete audio which still fits the confirmed display interval.
        var resultURL = finalStretchedURL
        do { try timePitchEngine.changeSpeed(inputURL: rawTTSURL, outputURL: finalStretchedURL, rate: rate) }
        catch { resultURL = rawTTSURL }
        try Task.checkCancellation()
        let actual = try await AVURLAsset(url: resultURL).load(.duration).secondsValue
        guard actual > 0 else {
            throw TTSError.synthesisFailed("配音音频生成异常，未获取到有效音频数据")
        }
        guard item.audioSignature(voice: voice) == signature else { throw CancellationError() }
        let completedURL = resultURL
        await MainActor.run {
            guard !Task.isCancelled, item.audioSignature(voice: voice) == signature else { return }
            item.dubbedAudioURL = completedURL
            item.dubbedAudioSignature = signature
        }
        guard item.hasCurrentAudio(voice: voice) else { throw CancellationError() }
    }
}
