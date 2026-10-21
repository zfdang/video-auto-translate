import Foundation
import CoreMedia

/// 根据目标语言翻译后文字量，校对并重新调整时间轴的智能平滑引擎
public final class TimelineAligner {
    public init() {}

    /// 估算特定语言文本的自然舒适发音时长 (秒)
    public static func estimateNaturalDuration(text: String, language: String = "zh") -> Double {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return 0.5 }

        let isCJK = language.lowercased().hasPrefix("zh") ||
                    language.lowercased().hasPrefix("ja") ||
                    language.lowercased().hasPrefix("ko") ||
                    clean.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }

        if isCJK {
            // 中文/日文/韩文：舒适朗读语速约为每秒 4.0 ~ 4.5 个字
            // 加上标点符号与呼吸微停顿基底 (0.25 秒)
            let charCount = clean.filter { !$0.isWhitespace }.count
            let baseDuration = Double(charCount) / 4.2
            return max(0.6, baseDuration + 0.25)
        } else {
            // 西文/拉丁语系：按词数估算，舒适语速约为每秒 2.6 ~ 3.0 个词
            let words = clean.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            let wordCount = max(1, words.count)
            let baseDuration = Double(wordCount) / 2.8
            return max(0.6, baseDuration + 0.25)
        }
    }

    /// 确定性语速平滑对齐算法 (将相邻对话与静音空隙弹性分配给文字较长的译文，使语速趋向稳定均衡)
    /// - Parameters:
    ///   - items: 原始字幕项列表
    ///   - language: 目标语种
    ///   - maxBridgeGapSeconds: 可作为同一对话簇借调时长的最大间隔（默认 2.0 秒）
    /// - Returns: 时间轴重调后的字幕项列表
    public func alignTimelineDeterministically(
        items: [SubtitleItem],
        language: String = "zh",
        maxBridgeGapSeconds: Double = 2.0
    ) -> [SubtitleItem] {
        guard items.count >= 2 else { return items }

        var result: [SubtitleItem] = []
        var cluster: [SubtitleItem] = [items[0]]

        for i in 1..<items.count {
            let prev = items[i - 1]
            let curr = items[i]
            let gap = curr.startTime.secondsValue - prev.endTime.secondsValue

            // 若前后两句间隔在合理对话停顿内 (<= maxBridgeGapSeconds)，且无严重逆序，划入同一调整簇
            if gap >= -0.05 && gap <= maxBridgeGapSeconds {
                cluster.append(curr)
            } else {
                result.append(contentsOf: smoothCluster(cluster, language: language))
                cluster = [curr]
            }
        }

        if !cluster.isEmpty {
            result.append(contentsOf: smoothCluster(cluster, language: language))
        }

        return enforceStrictConstraints(result)
    }

    /// 使用本地大模型 (LLM) 进行语义感知的时间轴平衡校对
    public func alignTimelineWithLLM(
        items: [SubtitleItem],
        config: LLMConfiguration,
        client: OpenAICompatibleClient
    ) async -> [SubtitleItem] {
        guard !items.isEmpty else { return items }

        // 构造简明紧凑的提示词，便于本地 1.5B/7B 模型快速稳定输出 JSON
        var inputData: [[String: Any]] = []
        for (idx, item) in items.enumerated() {
            let targetText = item.translatedText.isEmpty ? item.originalText : item.translatedText
            let ideal = Self.estimateNaturalDuration(text: targetText, language: config.targetLanguage)
            inputData.append([
                "id": idx,
                "start": round(item.startTime.secondsValue * 100) / 100,
                "end": round(item.endTime.secondsValue * 100) / 100,
                "orig": item.originalText,
                "trans": targetText,
                "ideal_sec": round(ideal * 100) / 100
            ])
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: inputData, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return alignTimelineDeterministically(items: items, language: config.targetLanguage)
        }

        let systemPrompt = """
        You are an expert audio-visual dubbing editor.
        The translated subtitles often have different lengths from the original speech, causing text-to-speech dubbing to sound either unnaturally rushed or dragging.
        Adjust the [start, end] seconds for each subtitle to balance the speaking pace naturally:
        1. Borrow idle pauses between sentences to give longer translations enough time to speak comfortably.
        2. Strictly preserve sequential order: start[i] must be >= end[i-1] + 0.05 (NO OVERLAPPING).
        3. Do not change the overall start of the first subtitle or end of the last subtitle by more than 1.5s.
        4. Return ONLY a valid JSON object matching this schema:
        {
          "subtitles": [
            {"id": 0, "start": 0.08, "end": 1.25},
            {"id": 1, "start": 1.35, "end": 2.80}
          ]
        }
        """

        let userPrompt = "Rebalance the timeline for the following \(config.targetLanguage) subtitles:\n\(jsonString)"
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

            if let parsed = parseLLMTimeline(from: responseText, originalItems: items) {
                return enforceStrictConstraints(parsed)
            }
        } catch {
            // 大模型调用异常时，平滑回退至本地确定性自适应平衡算法
        }

        return alignTimelineDeterministically(items: items, language: config.targetLanguage)
    }

    // MARK: - 内部私有处理方法

    /// 对连续对话簇内部进行语速平滑重分配
    private func smoothCluster(_ cluster: [SubtitleItem], language: String) -> [SubtitleItem] {
        guard cluster.count >= 2 else { return cluster }

        let clusterStart = cluster.first!.startTime.secondsValue
        let clusterEnd = cluster.last!.endTime.secondsValue
        let totalClusterSpan = clusterEnd - clusterStart
        guard totalClusterSpan > 0.4 else { return cluster }

        // 计算每条译文的理想发音时长
        let idealDurations = cluster.map { item -> Double in
            let text = item.translatedText.isEmpty ? item.originalText : item.translatedText
            return Self.estimateNaturalDuration(text: text, language: language)
        }
        let totalIdeal = idealDurations.reduce(0, +)
        guard totalIdeal > 0 else { return cluster }

        // 预留句子间的微小呼吸停顿 (50ms ~ 100ms)
        let pausePerBoundary = 0.08
        let totalPauses = Double(cluster.count - 1) * pausePerBoundary
        let availableSpeechSpan = max(Double(cluster.count) * 0.2, totalClusterSpan - totalPauses)

        // 按文字量理想比例将可用时长分配给各句
        var allocatedDurations = idealDurations.map { ideal in
            (ideal / totalIdeal) * availableSpeechSpan
        }

        // 确保单句最低持续时长不低于 200ms
        for i in 0..<allocatedDurations.count {
            if allocatedDurations[i] < 0.2 {
                allocatedDurations[i] = 0.2
            }
        }

        // 重新构建时间轴
        var smoothed: [SubtitleItem] = []
        var currentTime = clusterStart

        for (idx, item) in cluster.enumerated() {
            let dur = allocatedDurations[idx]
            let start = currentTime
            let end = (idx == cluster.count - 1) ? clusterEnd : min(clusterEnd, start + dur)

            let newItem = SubtitleItem(
                id: item.id,
                startTime: CMTime.from(seconds: max(0, start)),
                endTime: CMTime.from(seconds: max(start + 0.15, end)),
                originalText: item.originalText,
                translatedText: item.translatedText,
                words: item.words
            )
            smoothed.append(newItem)
            currentTime = end + pausePerBoundary
        }

        return smoothed
    }

    /// 解析大模型返回的时间轴数据
    private func parseLLMTimeline(from response: String, originalItems: [SubtitleItem]) -> [SubtitleItem]? {
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

        for (idx, orig) in originalItems.enumerated() {
            if let timing = map[idx], timing.1 > timing.0 + 0.15 {
                result.append(SubtitleItem(
                    id: orig.id,
                    startTime: CMTime.from(seconds: max(0, timing.0)),
                    endTime: CMTime.from(seconds: max(timing.0 + 0.15, timing.1)),
                    originalText: orig.originalText,
                    translatedText: orig.translatedText,
                    words: orig.words
                ))
            } else {
                result.append(orig)
            }
        }

        return result.count == originalItems.count ? result : nil
    }

    /// 确定性约束校验器：强制消除字幕重合交叠、修复逆序并保障单句最小持续时长
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
                words: item.words
            )
            sanitized.append(validItem)
            lastEnd = end
        }

        return sanitized
    }
}
