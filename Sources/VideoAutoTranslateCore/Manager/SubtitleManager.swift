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

    /// 依据用户光标位置精准执行词级时间戳拆分 (Cmd+B)
    /// - Parameters:
    ///   - item: 待切分的字幕项
    ///   - charIndex: 光标在 originalText 中的字符下标 (0 ~ count)
    /// - Returns: 切分后的前后两个字幕项
    public func split(item: SubtitleItem, atCharIndex charIndex: Int) -> (SubtitleItem, SubtitleItem)? {
        let text = item.originalText
        guard charIndex > 0 && charIndex < text.count else { return nil }

        // PRD 规范：单条字幕最低持续时长约束为 100ms，拆分需至少 200ms 总时长 (FU03)
        let minDuration = CMTime(value: 100, timescale: 1000)
        guard item.duration >= CMTime(value: 200, timescale: 1000) else { return nil }

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
                // Select one boundary from the complete set, including the first word.
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
                splitTime = firstWords.last!.endCMTime
            } else {
                // 词序列少于 2 个匹配时，回退至字符截断
                let index = text.index(text.startIndex, offsetBy: charIndex)
                firstPartText = String(text[..<index]).trimmingCharacters(in: .whitespaces)
                secondPartText = String(text[index...]).trimmingCharacters(in: .whitespaces)
                let ratio = Double(charIndex) / Double(text.count)
                splitTime = CMTimeAdd(item.startTime, CMTime.from(seconds: item.durationSeconds * ratio))
                firstWords = item.words.filter { $0.endCMTime <= splitTime }
                secondWords = item.words.filter { $0.startCMTime >= splitTime }
            }
        } else {
            // 保底机制：无词级序列时按字符比例切分
            let index = text.index(text.startIndex, offsetBy: charIndex)
            firstPartText = String(text[..<index]).trimmingCharacters(in: .whitespaces)
            secondPartText = String(text[index...]).trimmingCharacters(in: .whitespaces)
            let ratio = Double(charIndex) / Double(text.count)
            splitTime = CMTimeAdd(item.startTime, CMTime.from(seconds: item.durationSeconds * ratio))
        }

        guard !firstPartText.isEmpty, !secondPartText.isEmpty else { return nil }

        // 确保切分点严格位于 [startTime + minDuration, endTime - minDuration] 内部，防止 0 时长 (R06)
        let earliestValid = CMTimeAdd(item.startTime, minDuration)
        let latestValid = CMTimeSubtract(item.endTime, minDuration)

        if !item.words.isEmpty && (splitTime < earliestValid || splitTime > latestValid) {
            return nil // Never move a physical word boundary independently of its text.
        }
        if splitTime < earliestValid {
            splitTime = earliestValid
        } else if splitTime > latestValid {
            splitTime = latestValid
        }

        // R05: 保存人工译文成果，将原译文保留在前半句，防止拆分直接清空丢失劳动成果
        let existingTrans = item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let (part1Trans, part2Trans): (String, String)
        if !existingTrans.isEmpty {
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
            words: firstWords
        )

        let part2 = SubtitleItem(
            startTime: splitTime,
            endTime: item.endTime,
            originalText: secondPartText,
            translatedText: part2Trans,
            words: secondWords
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
            words: combinedWords
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
        let textToSpeak = item.translatedText.isEmpty ? item.originalText : item.translatedText
        guard !textToSpeak.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
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

        // 1. 合成原始语速语音
        _ = try await ttsService.synthesize(text: textToSpeak, voice: voice, outputURL: rawTTSURL)

        // 2. 检测语音实际发音时长
        let rawAsset = AVURLAsset(url: rawTTSURL)
        let rawDuration = try await rawAsset.load(.duration)
        let targetDuration = item.duration

        // 3. 计算语速伸缩比率 R = rawDuration / targetDuration
        let rate = Float(rawDuration.secondsValue / max(0.2, targetDuration.secondsValue))

        // 4. 音调不变语速缩放（带安全降级）
        do {
            try timePitchEngine.changeSpeed(inputURL: rawTTSURL, outputURL: finalStretchedURL, rate: rate)
            await MainActor.run {
                guard !Task.isCancelled, item.audioSignature(voice: voice) == signature else { return }
                item.dubbedAudioURL = finalStretchedURL
                item.dubbedAudioSignature = signature
            }
        } catch {
            // 伸缩引擎异常时优雅降级：直接采用高质量原生合成音频，杜绝单句异常中断全篇配音
            await MainActor.run {
                guard !Task.isCancelled, item.audioSignature(voice: voice) == signature else { return }
                item.dubbedAudioURL = rawTTSURL
                item.dubbedAudioSignature = signature
            }
        }
    }
}
