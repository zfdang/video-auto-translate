import Foundation
import CoreMedia

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

        let index = text.index(text.startIndex, offsetBy: charIndex)
        let firstPartText = String(text[..<index]).trimmingCharacters(in: .whitespaces)
        let secondPartText = String(text[index...]).trimmingCharacters(in: .whitespaces)

        guard !firstPartText.isEmpty, !secondPartText.isEmpty else { return nil }

        // 若拥有精准的词级时间戳序列，则根据词长度累计找到最佳切分时间
        var accumulated = 0
        var splitTime = item.startTime
        var firstWords: [WordToken] = []
        var secondWords: [WordToken] = []

        if !item.words.isEmpty {
            for word in item.words {
                accumulated += word.text.count
                if accumulated <= charIndex {
                    firstWords.append(word)
                    splitTime = word.endCMTime
                } else {
                    secondWords.append(word)
                }
            }
        } else {
            // 保底机制：按字符比例估算切分点
            let ratio = Double(charIndex) / Double(text.count)
            let durationSeconds = item.durationSeconds
            splitTime = CMTimeAdd(item.startTime, CMTime.from(seconds: durationSeconds * ratio))
        }

        // 确保切分点严格位于 [startTime, endTime] 内部
        if splitTime <= item.startTime || splitTime >= item.endTime {
            splitTime = CMTimeAdd(item.startTime, CMTime(value: item.duration.value / 2, timescale: item.duration.timescale))
        }

        let part1 = SubtitleItem(
            startTime: item.startTime,
            endTime: splitTime,
            originalText: firstPartText,
            translatedText: "",
            words: firstWords
        )

        let part2 = SubtitleItem(
            startTime: splitTime,
            endTime: item.endTime,
            originalText: secondPartText,
            translatedText: "",
            words: secondWords
        )

        return (part1, part2)
    }

    /// 将选中的多条相邻字幕合并为单条 (Cmd+J)
    public func merge(items: [SubtitleItem]) -> SubtitleItem? {
        guard items.count >= 2 else { return nil }

        // 依据起始时间严格排序
        let sorted = items.sorted { $0.startTime < $1.startTime }
        guard let first = sorted.first, let last = sorted.last else { return nil }

        let combinedOriginal = sorted.map { $0.originalText.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        let combinedTranslated = sorted.map { $0.translatedText.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let combinedWords = sorted.flatMap { $0.words }

        return SubtitleItem(
            startTime: first.startTime,
            endTime: last.endTime,
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
import AVFoundation
