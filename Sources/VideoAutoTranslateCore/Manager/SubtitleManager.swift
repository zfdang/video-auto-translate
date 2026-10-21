import Foundation
import CoreMedia
import AVFoundation

/// 字幕管理与交互剪辑管理器（核心业务逻辑）
public final class SubtitleManager {
    private let timePitchEngine = TimePitchEngine()

    public init() {}

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
                if let found = text.range(of: word.text, options: [], range: searchRange) {
                    let start = text.distance(from: text.startIndex, to: found.lowerBound)
                    let end = text.distance(from: text.startIndex, to: found.upperBound)
                    wordRanges.append((word, found, start, end))
                    searchRange = found.upperBound..<text.endIndex
                }
            }

            if wordRanges.count >= 2 {
                // 寻找最接近用户光标的词间边界（必须确保左右各至少拥有一个词）
                var bestSplitIdx = 0
                var minDistance = Int.max

                for i in 0..<(wordRanges.count - 1) {
                    let boundary = wordRanges[i].endOffset
                    let dist = abs(charIndex - boundary)
                    if dist < minDistance {
                        minDistance = dist
                        bestSplitIdx = i
                    }
                }

                firstWords = wordRanges[0...bestSplitIdx].map { $0.word }
                secondWords = wordRanges[(bestSplitIdx + 1)...].map { $0.word }

                // 文字切分点严格吸附至词边界，杜绝词内斩断导致文本与 Token 脱节 (FU03)
                let splitStrIndex = wordRanges[bestSplitIdx].range.upperBound
                firstPartText = String(text[..<splitStrIndex]).trimmingCharacters(in: .whitespaces)
                secondPartText = String(text[splitStrIndex...]).trimmingCharacters(in: .whitespaces)

                // 时间切分点：取左句末词结束时间点
                splitTime = firstWords.last!.endCMTime
            } else {
                // 词序列少于 2 个时，回退至字符截断
                let index = text.index(text.startIndex, offsetBy: charIndex)
                firstPartText = String(text[..<index]).trimmingCharacters(in: .whitespaces)
                secondPartText = String(text[index...]).trimmingCharacters(in: .whitespaces)
                let ratio = Double(charIndex) / Double(text.count)
                splitTime = CMTimeAdd(item.startTime, CMTime.from(seconds: item.durationSeconds * ratio))
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
        let rawTTSURL = tempDir.appendingPathComponent("raw_tts_\(item.id.uuidString).wav")
        let finalStretchedURL = tempDir.appendingPathComponent("dubbed_\(item.id.uuidString).wav")

        // 1. 合成原始语速语音
        _ = try await ttsService.synthesize(text: textToSpeak, voice: voice, outputURL: rawTTSURL)

        // 2. 检测语音实际发音时长
        let rawAsset = AVURLAsset(url: rawTTSURL)
        let rawDuration = try await rawAsset.load(.duration)
        let targetDuration = item.duration

        // 3. 计算语速伸缩比率 R = rawDuration / targetDuration
        let rate = Float(rawDuration.secondsValue / max(0.2, targetDuration.secondsValue))

        // 4. 音调不变语速缩放
        try timePitchEngine.changeSpeed(inputURL: rawTTSURL, outputURL: finalStretchedURL, rate: rate)

        await MainActor.run {
            item.dubbedAudioURL = finalStretchedURL
        }
    }
}
