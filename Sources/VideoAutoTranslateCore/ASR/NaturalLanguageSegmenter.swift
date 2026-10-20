import Foundation
import CoreMedia
import NaturalLanguage

/// 基于 Apple NaturalLanguage.framework 的语义字幕规整断句器
public final class NaturalLanguageSegmenter {
    public init() {}

    /// 针对识别出的粗颗粒度词序列，依据语义边界和停顿时间规整切分为标准单行字幕
    /// - Parameters:
    ///   - tokens: 词级时间戳序列
    ///   - maxCharsPerLine: 单行最大字符数（中文建议 22，西文建议 42）
    ///   - maxPauseGapSeconds: 判定切分断句的最大静音停顿阈值（默认 0.35 秒）
    public func segment(
        tokens: [WordToken],
        maxCharsPerLine: Int = 24,
        maxPauseGapSeconds: Double = 0.35
    ) -> [SubtitleItem] {
        guard !tokens.isEmpty else { return [] }

        var result: [SubtitleItem] = []
        var currentTokens: [WordToken] = []
        var currentChars = 0

        for (index, token) in tokens.enumerated() {
            currentTokens.append(token)
            currentChars += token.text.count

            let isLast = (index == tokens.count - 1)
            var shouldSplit = false

            if isLast {
                shouldSplit = true
            } else {
                let nextToken = tokens[index + 1]
                let pauseGap = nextToken.startCMTime.secondsValue - token.endCMTime.secondsValue

                // 规则 1: 停顿大于阈值切分
                if pauseGap >= maxPauseGapSeconds {
                    shouldSplit = true
                }
                // 规则 2: 当前词末尾是句子终结标点符号（。！？.!?）
                else if token.text.contains(where: { "。！？.!?".contains($0) }) {
                    shouldSplit = true
                }
                // 规则 3: 字符数达到单行上限
                else if currentChars >= maxCharsPerLine {
                    shouldSplit = true
                }
            }

            if shouldSplit && !currentTokens.isEmpty {
                let startTime = currentTokens.first!.startCMTime
                let endTime = currentTokens.last!.endCMTime
                let lineText = currentTokens.map { $0.text }.joined(separator: " ")
                    .replacingOccurrences(of: "  ", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let item = SubtitleItem(
                    startTime: startTime,
                    endTime: endTime,
                    originalText: lineText,
                    words: currentTokens
                )
                result.append(item)

                currentTokens.removeAll()
                currentChars = 0
            }
        }

        return result
    }
}
