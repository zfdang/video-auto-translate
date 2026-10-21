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
    ///   - maxPauseGapSeconds: 判定切分断句的最大静音停顿阈值（默认 0.65 秒）
    public func segment(
        tokens: [WordToken],
        maxCharsPerLine: Int = 42,
        maxPauseGapSeconds: Double = 0.65
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

                // 规则 1: 停顿大于阈值切分 (放宽到 0.65 秒，避免正常说话短暂停顿被打断)
                if pauseGap >= maxPauseGapSeconds {
                    shouldSplit = true
                }
                // 规则 2: 当前词末尾是句子终结标点符号（。！？.!?）
                else if token.text.contains(where: { "。！？.!?".contains($0) }) {
                    shouldSplit = true
                }
                // 规则 3: 字符数达到单行上限
                else if currentChars >= maxCharsPerLine {
                    // 若当前词为常见紧密修饰词或介词，避免生硬切断（如 very, too, the, a, of）
                    let lower = token.text.lowercased().trimmingCharacters(in: .punctuationCharacters)
                    let modifiers = ["very", "too", "more", "most", "the", "a", "an", "to", "of", "and", "in", "on", "at", "for", "with", "so"]
                    if modifiers.contains(lower) && currentChars < maxCharsPerLine + 12 {
                        shouldSplit = false
                    } else {
                        shouldSplit = true
                    }
                }
            }

            if shouldSplit && !currentTokens.isEmpty {
                let startTime = currentTokens.first!.startCMTime
                let endTime = currentTokens.last!.endCMTime
                let lineText = Self.joinTokensText(currentTokens)

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

    /// 智能拼接词条文本（支持中日文紧凑排版与西文空格间隔）
    public static func joinTokensText(_ tokens: [WordToken]) -> String {
        guard !tokens.isEmpty else { return "" }
        var result = ""
        for (i, token) in tokens.enumerated() {
            let text = token.text
            if i == 0 {
                result += text
                continue
            }
            let prev = tokens[i - 1].text
            let prevLast = prev.last
            let currFirst = text.first
            let isCJK = { (c: Character?) -> Bool in
                guard let u = c?.unicodeScalars.first?.value else { return false }
                return (0x4E00...0x9FFF).contains(u) || (0x3040...0x30FF).contains(u)
            }
            if let p = prevLast, let c = currFirst, isCJK(p) && isCJK(c) {
                result += text
            } else {
                result += " " + text
            }
        }
        return result.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
