import Foundation
import CoreMedia
import AVFoundation

/// 根据目标语言译文文字量与期望发音时长，匹配并重构时间轴的智能引擎
public final class TimelineAligner {
    public init() {}

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
            return max(0.65, baseDuration + 0.25)
        } else {
            // 西文/拉丁语系：按有效词数计算，舒适朗读语速约为每秒 2.5 ~ 2.8 个词
            let words = clean.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            let wordCount = max(1, words.count)
            let baseDuration = Double(wordCount) / 2.6
            return max(0.65, baseDuration + 0.25)
        }
    }

    /// 获取单条字幕在译文期望下的发音基准时长
    public func expectedDurationForSubtitle(_ item: SubtitleItem, language: String = "zh") -> Double {
        let text = item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? item.originalText
            : item.translatedText
        return Self.estimateNaturalDuration(text: text, language: language)
    }

    /// 核心算法：匹配译文时间轴 (Match Timeline to Translation)
    /// 原文与译文一一对应关系保持完全不变，仅将时间轴重构为与期望中的译文语音时间轴一致
    /// - Parameters:
    ///   - items: 原始字幕列表（含原文与已翻译译文）
    ///   - language: 目标译文语言
    ///   - naturalPauseSeconds: 句子间自然呼吸与语气停顿（默认 0.20 秒）
    ///   - videoDuration: 视频总时长（可选安全边界保护）
    /// - Returns: 原文译文一一对应、时间轴契合译文自然语速的新字幕列表
    public func matchTimelineToTranslation(
        items: [SubtitleItem],
        language: String = "zh",
        naturalPauseSeconds: Double = 0.20,
        videoDuration: Double? = nil
    ) -> [SubtitleItem] {
        guard !items.isEmpty else { return [] }

        var result: [SubtitleItem] = []

        // 第一句的起始时间：以原视频说话人第一次开讲的时间为基准点
        var currentStart = items[0].startTime.secondsValue

        for (i, orig) in items.enumerated() {
            let naturalDur = expectedDurationForSubtitle(orig, language: language)

            if i > 0 {
                let prevOrig = items[i - 1]
                let origGap = orig.startTime.secondsValue - prevOrig.endTime.secondsValue

                // 若原视频在此处有明显安静的空隙（大于 0.4 秒），尽量尊重原画面的停顿节奏
                if origGap >= 0.4 {
                    // 如果上一句译文已经说完，并且空隙还在，则在原发音点开始；否则紧随上一句自然停顿后开始
                    currentStart = max(orig.startTime.secondsValue, currentStart + naturalPauseSeconds)
                } else {
                    // 原视频紧凑对话：按自然句子换气停顿平滑衔接
                    currentStart = currentStart + naturalPauseSeconds
                }
            }

            let calculatedEnd = currentStart + naturalDur

            // 保持原文、译文、ID、词序列一一对应不变，仅赋予契合译文语速的新时间轴
            let matchedItem = SubtitleItem(
                id: orig.id,
                startTime: CMTime.from(seconds: max(0, currentStart)),
                endTime: CMTime.from(seconds: calculatedEnd),
                originalText: orig.originalText,
                translatedText: orig.translatedText,
                words: orig.words,
                dubbedAudioURL: nil // 时间轴已改变，重置旧切片以便后续生成 1.0x 完美语速配音
            )
            result.append(matchedItem)

            currentStart = calculatedEnd
        }

        // 若指定了视频总时长且末尾超限，轻度等比弹性压缩以确保不超出视频边界
        if let maxDuration = videoDuration, let lastEnd = result.last?.endTime.secondsValue, lastEnd > maxDuration {
            result = fitWithinDuration(items: result, maxDuration: maxDuration)
        }

        return enforceStrictConstraints(result)
    }

    /// 使用大模型 (LLM) 进行语义感知的译文时间轴精细匹配
    /// - Parameters:
    ///   - items: 原始字幕项列表
    ///   - config: 大模型配置
    ///   - client: OpenAI API 客户端
    ///   - videoDuration: 视频总时长
    public func matchTimelineWithLLM(
        items: [SubtitleItem],
        config: LLMConfiguration,
        client: OpenAICompatibleClient,
        videoDuration: Double? = nil
    ) async -> [SubtitleItem] {
        guard !items.isEmpty else { return items }

        // 先获取确定性匹配结果作为基准
        let baseMatched = matchTimelineToTranslation(items: items, language: config.targetLanguage, videoDuration: videoDuration)

        // 构造提示词请求大模型在各句语义停顿上进行细致微调
        var inputData: [[String: Any]] = []
        for (idx, item) in baseMatched.enumerated() {
            inputData.append([
                "id": idx,
                "orig": item.originalText,
                "trans": item.translatedText,
                "start": round(item.startTime.secondsValue * 100) / 100,
                "end": round(item.endTime.secondsValue * 100) / 100,
                "dur": round(item.durationSeconds * 100) / 100
            ])
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: inputData, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return baseMatched
        }

        let systemPrompt = """
        You are an expert audio-visual dubbing supervisor.
        The timeline is being re-aligned to match the natural speaking duration of the TRANSLATED text (not bound to the original audio).
        Original text and translated text MUST remain strictly 1-to-1 matched.
        Refine the [start, end] seconds for each subtitle:
        1. Keep speaking duration natural for each sentence's translated text (around 3.8-4.2 chars/sec for Chinese, 2.6 words/sec for English).
        2. Give slightly more pause after major sentence conclusions (like period, exclamation mark), and shorter pauses for commas.
        3. Maintain strict chronological sequence: start[i] >= end[i-1] + 0.08 (ABSOLUTELY NO OVERLAPPING).
        4. Do NOT drop, merge, or change any subtitle row.
        5. Return ONLY a valid JSON object matching:
        {
          "subtitles": [
            {"id": 0, "start": 0.16, "end": 1.25},
            {"id": 1, "start": 1.45, "end": 3.10}
          ]
        }
        """

        let userPrompt = "Refine the translation-matched timeline for the following subtitles:\n\(jsonString)"
        let messages = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]

        do {
            let responseText = try await client.chatCompletion(
                model: config.effectiveModel,
                messages: messages,
                temperature: 0.1,
                responseFormatJSON: true
            )

            if let parsed = parseLLMTimeline(from: responseText, originalItems: baseMatched, language: config.targetLanguage) {
                return enforceStrictConstraints(parsed)
            }
        } catch {
            // 大模型异常时平滑使用确定性匹配结果
        }

        return baseMatched
    }

    // MARK: - 内部辅助方法

    /// 解析大模型返回的时间轴数据，并施加发音自然时长的保底校验
    private func parseLLMTimeline(
        from response: String,
        originalItems: [SubtitleItem],
        language: String
    ) -> [SubtitleItem]? {
        guard let data = response.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            return nil
        }

        struct LLMTimelineResponse: Codable {
            struct Item: Codable {
                let id: Int
                let start: Double
                let end: Double
            }
            let subtitles: [Item]
        }

        guard let decoded = try? JSONDecoder().decode(LLMTimelineResponse.self, from: data) else {
            return nil
        }

        let map = Dictionary(uniqueKeysWithValues: decoded.subtitles.map { ($0.id, ($0.start, $0.end)) })
        var result: [SubtitleItem] = []
        var lastEnd = 0.0

        for (idx, orig) in originalItems.enumerated() {
            let naturalDur = expectedDurationForSubtitle(orig, language: language)

            if let timing = map[idx] {
                let requestedDur = timing.1 - timing.0
                // 保底防错：大模型输出时长绝不能比自然舒适时长缩短 10% 以上，防止语音被压成冲刺语速
                let safeDur = max(naturalDur * 0.90, requestedDur)
                let safeStart = max(lastEnd + 0.08, timing.0)
                let safeEnd = safeStart + safeDur

                result.append(SubtitleItem(
                    id: orig.id,
                    startTime: CMTime.from(seconds: max(0, safeStart)),
                    endTime: CMTime.from(seconds: safeEnd),
                    originalText: orig.originalText,
                    translatedText: orig.translatedText,
                    words: orig.words,
                    dubbedAudioURL: nil
                ))
                lastEnd = safeEnd
            } else {
                let start = max(lastEnd + 0.08, orig.startTime.secondsValue)
                let end = start + naturalDur
                result.append(SubtitleItem(
                    id: orig.id,
                    startTime: CMTime.from(seconds: start),
                    endTime: CMTime.from(seconds: end),
                    originalText: orig.originalText,
                    translatedText: orig.translatedText,
                    words: orig.words,
                    dubbedAudioURL: nil
                ))
                lastEnd = end
            }
        }

        return result.count == originalItems.count ? result : nil
    }

    /// 弹性缩放以确保整体不超过视频最大时长
    private func fitWithinDuration(items: [SubtitleItem], maxDuration: Double) -> [SubtitleItem] {
        guard let firstStart = items.first?.startTime.secondsValue,
              let lastEnd = items.last?.endTime.secondsValue,
              lastEnd > maxDuration else {
            return items
        }

        let currentSpan = lastEnd - firstStart
        guard currentSpan > 1.0 else { return items }

        let targetSpan = max(1.0, maxDuration - firstStart)
        let scale = targetSpan / currentSpan

        var adjusted: [SubtitleItem] = []
        for item in items {
            let relStart = (item.startTime.secondsValue - firstStart) * scale
            let relEnd = (item.endTime.secondsValue - firstStart) * scale
            adjusted.append(SubtitleItem(
                id: item.id,
                startTime: CMTime.from(seconds: firstStart + relStart),
                endTime: CMTime.from(seconds: firstStart + relEnd),
                originalText: item.originalText,
                translatedText: item.translatedText,
                words: item.words,
                dubbedAudioURL: nil
            ))
        }
        return adjusted
    }

    /// 确定性约束校验器：杜绝字幕重合、保障发音持续时长
    private func enforceStrictConstraints(_ items: [SubtitleItem]) -> [SubtitleItem] {
        guard !items.isEmpty else { return [] }

        var sanitized: [SubtitleItem] = []
        var lastEnd = 0.0

        for (i, item) in items.enumerated() {
            var start = item.startTime.secondsValue
            var end = item.endTime.secondsValue

            // 1. 杜绝上一句与下一句重叠交叉 (保持至少 40ms 间距)
            if i > 0 && start < lastEnd + 0.04 {
                start = lastEnd + 0.04
            }

            // 2. 保证单句至少持续 200ms
            if end < start + 0.20 {
                end = start + 0.20
            }

            let validItem = SubtitleItem(
                id: item.id,
                startTime: CMTime.from(seconds: start),
                endTime: CMTime.from(seconds: end),
                originalText: item.originalText,
                translatedText: item.translatedText,
                words: item.words,
                dubbedAudioURL: nil
            )
            sanitized.append(validItem)
            lastEnd = end
        }

        return sanitized
    }
}
