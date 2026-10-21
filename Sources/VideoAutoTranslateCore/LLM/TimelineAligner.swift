import Foundation
import CoreMedia
import AVFoundation

/// 根据目标语言译文文字量与期望发音时长，匹配并重构时间轴的智能引擎
/// 采用“基于局部语音段/对话簇（Speech Clusters）自适应平滑”架构：
/// 1. 彻底避免在整个视频范围内做全局平均或无限累积延后，杜绝音画严重脱节；
/// 2. 原视频存在自然停顿（>=0.65s）处进行物理分簇，各簇起点严格锚定对应原声位置；
/// 3. 仅在局部簇内小范围根据译文字数做语速平衡，既避免个别句子极度急促，又避免短译文慢放拖沓。
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
            return max(0.60, baseDuration + 0.22)
        } else {
            // 西文/拉丁语系：按有效词数计算，舒适朗读语速约为每秒 2.5 ~ 2.8 个词
            let words = clean.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            let wordCount = max(1, words.count)
            let baseDuration = Double(wordCount) / 2.6
            return max(0.60, baseDuration + 0.22)
        }
    }

    /// 获取单条字幕在译文期望下的发音基准时长
    public func expectedDurationForSubtitle(_ item: SubtitleItem, language: String = "zh") -> Double {
        let text = item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? item.originalText
            : item.translatedText
        return Self.estimateNaturalDuration(text: text, language: language)
    }

    /// 核心算法：基于局部语音段/对话簇（Speech Clusters）的译文时间轴自适应平滑匹配
    /// - 原文与译文 1:1 严格对应关系保持完全不变；
    /// - 绝不进行全视频全局平均或累积时移，避免音画与视频内容脱节；
    /// - 在原视频自然停顿处进行物理分簇，簇起点严格锚定原声位置；
    /// - 仅在局部簇内根据译文字数与期望时长分配发音时间，兼顾自然语速与音画对齐。
    /// - Parameters:
    ///   - items: 原始字幕列表（含原文与已翻译译文）
    ///   - language: 目标译文语言
    ///   - clusterGapThreshold: 自然分簇静音阈值（默认 0.65 秒，原视频有停顿即切分独立簇）
    ///   - maxClusterItems: 单簇最大容纳字幕行数（默认 5 行，防止长单口相声无停顿导致范围过大）
    ///   - maxClusterDuration: 单簇最大时间跨度（默认 16 秒）
    ///   - naturalPauseSeconds: 簇内句子间自然呼吸与换气停顿（默认 0.16 秒）
    ///   - videoDuration: 视频总时长（可选安全边界保护）
    /// - Returns: 原文译文一一对应、各簇音画精确对齐、局部语速平滑自然的新字幕列表
    public func matchTimelineToTranslation(
        items: [SubtitleItem],
        language: String = "zh",
        clusterGapThreshold: Double = 0.65,
        maxClusterItems: Int = 5,
        maxClusterDuration: Double = 16.0,
        naturalPauseSeconds: Double = 0.16,
        videoDuration: Double? = nil
    ) -> [SubtitleItem] {
        guard !items.isEmpty else { return [] }

        // 1. 按照原视频时间顺序与停顿特性切分为独立的局部对话簇 (Speech Clusters)
        let clusters = partitionIntoClusters(
            items: items,
            gapThreshold: clusterGapThreshold,
            maxItems: maxClusterItems,
            maxDuration: maxClusterDuration
        )

        var alignedItems: [SubtitleItem] = []
        var previousClusterActualEnd: Double = 0.0

        for (clusterIndex, cluster) in clusters.enumerated() {
            let nextClusterOrigStart: Double
            if clusterIndex + 1 < clusters.count {
                nextClusterOrigStart = clusters[clusterIndex + 1].first!.startTime.secondsValue
            } else if let vidDur = videoDuration, vidDur > cluster.last!.endTime.secondsValue {
                nextClusterOrigStart = vidDur
            } else {
                nextClusterOrigStart = cluster.last!.endTime.secondsValue + 3.0
            }

            let alignedCluster = alignCluster(
                cluster: cluster,
                language: language,
                naturalPauseSeconds: naturalPauseSeconds,
                prevActualEnd: previousClusterActualEnd,
                nextOrigStart: nextClusterOrigStart,
                videoDuration: videoDuration
            )

            alignedItems.append(contentsOf: alignedCluster)
            if let lastItem = alignedCluster.last {
                previousClusterActualEnd = lastItem.endTime.secondsValue
            }
        }

        return enforceStrictConstraints(alignedItems, videoDuration: videoDuration)
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

        // 先获取基于局部簇的确定性对齐结果作为基准
        let baseMatched = matchTimelineToTranslation(
            items: items,
            language: config.targetLanguage,
            videoDuration: videoDuration
        )

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
        The timeline has been partitioned and pre-aligned into speech clusters anchored to the video scenes.
        Original text and translated text MUST remain strictly 1-to-1 matched.
        You may refine the [start, end] seconds for each subtitle slightly (within ±0.5s from input values):
        1. Keep speaking duration natural for each sentence (around 3.8-4.2 chars/sec for Chinese, 2.6 words/sec for English).
        2. Do NOT drift timestamps across video gaps. Keep natural silences between speech clusters.
        3. Maintain strict chronological sequence: start[i] >= end[i-1] + 0.05 (ABSOLUTELY NO OVERLAPPING).
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

            if let parsed = parseLLMTimeline(from: responseText, baseMatched: baseMatched, language: config.targetLanguage, videoDuration: videoDuration) {
                return enforceStrictConstraints(parsed, videoDuration: videoDuration)
            }
        } catch {
            // 大模型异常或网络不可用时平滑使用确定性匹配结果
        }

        return baseMatched
    }

    // MARK: - 内部辅助方法：分簇与局部平滑引擎

    /// 将全量字幕依原声静音间隙与上限切分为独立的局部对话簇
    private func partitionIntoClusters(
        items: [SubtitleItem],
        gapThreshold: Double,
        maxItems: Int,
        maxDuration: Double
    ) -> [[SubtitleItem]] {
        var clusters: [[SubtitleItem]] = []
        var currentCluster: [SubtitleItem] = []

        for item in items {
            if currentCluster.isEmpty {
                currentCluster.append(item)
                continue
            }

            let prev = currentCluster.last!
            let gap = item.startTime.secondsValue - prev.endTime.secondsValue
            let currentSpan = prev.endTime.secondsValue - currentCluster.first!.startTime.secondsValue

            // 遇到明显的停顿、行数达到上限、或时长过长时，封口当前簇并开启新簇
            if gap >= gapThreshold || currentCluster.count >= maxItems || currentSpan >= maxDuration {
                clusters.append(currentCluster)
                currentCluster = [item]
            } else {
                currentCluster.append(item)
            }
        }

        if !currentCluster.isEmpty {
            clusters.append(currentCluster)
        }

        return clusters
    }

    /// 在局部对话簇内进行语速平滑与微调，杜绝全局时移
    private func alignCluster(
        cluster: [SubtitleItem],
        language: String,
        naturalPauseSeconds: Double,
        prevActualEnd: Double,
        nextOrigStart: Double,
        videoDuration: Double?
    ) -> [SubtitleItem] {
        guard !cluster.isEmpty else { return [] }

        let origStart = cluster.first!.startTime.secondsValue
        let origEnd = cluster.last!.endTime.secondsValue

        // 1. 簇起始时间：牢牢锚定在原声开讲时刻，且确保与前簇安全隔离（至少 40ms）
        let clusterStart = max(origStart, prevActualEnd + 0.04)

        // 2. 簇最大截止时间：允许安全借用后方自然静音缓冲（最多 1.2 秒），但绝不侵入下一簇原声起始区
        let trailingGap = max(0.0, nextOrigStart - origEnd)
        let safeBorrowSilence = min(1.2, max(0.0, trailingGap - 0.20))
        var maxClusterEnd = origEnd + safeBorrowSilence
        if let vidDur = videoDuration {
            maxClusterEnd = min(maxClusterEnd, vidDur)
        }
        maxClusterEnd = max(clusterStart + 0.35, maxClusterEnd)

        // 3. 计算簇内各句期望发音自然时长
        let expectedDurations = cluster.map { expectedDurationForSubtitle($0, language: language) }
        let totalExpectedDuration = expectedDurations.reduce(0.0, +)
        let m = cluster.count

        // 单句对话簇
        if m == 1 {
            let item = cluster[0]
            let needed = expectedDurations[0]
            let origSpan = max(0.3, origEnd - origStart)

            let finalDur: Double
            if needed <= origSpan {
                // 译文较短：按自然舒适语速发音，略留余量，剩余时间作为自然静音停顿，避免极度拖沓
                finalDur = max(0.35, min(origSpan, needed * 1.05))
            } else {
                // 译文较长：安全借用静音缓冲，最多延展至 maxClusterEnd
                finalDur = max(0.35, min(needed, maxClusterEnd - clusterStart))
            }

            return [
                SubtitleItem(
                    id: item.id,
                    startTime: CMTime.from(seconds: clusterStart),
                    endTime: CMTime.from(seconds: clusterStart + finalDur),
                    originalText: item.originalText,
                    translatedText: item.translatedText,
                    words: item.words,
                    dubbedAudioURL: nil
                )
            ]
        }

        // 多句对话簇：簇内共享时间预算，平衡各句语速
        let targetPause = naturalPauseSeconds
        let totalIdealPause = Double(m - 1) * targetPause
        let idealClusterSpan = totalExpectedDuration + totalIdealPause
        let origSpan = max(0.4, origEnd - clusterStart)
        let availableSpan = max(0.4, maxClusterEnd - clusterStart)

        var itemDurations: [Double] = []
        var itemPause: Double = targetPause

        if idealClusterSpan <= origSpan {
            // 情况 A：译文文字量较少，充裕在原时段内
            // 保持 1.0x 舒适发音时长，略加句间微停顿，留白自然停顿在簇末尾，绝不慢放拖拉
            itemDurations = expectedDurations
            itemPause = min(0.25, max(0.12, (origSpan - totalExpectedDuration) / Double(m)))
        } else if idealClusterSpan <= availableSpan {
            // 情况 B：译文文字量稍大，可在借用静音后以 1.0x 完美自然语速舒适展开
            itemDurations = expectedDurations
            itemPause = targetPause
        } else {
            // 情况 C：时间紧凑，簇内所有句子等比例分摊时间预算，避免单句急促爆发或单句停顿过长
            let minPause = max(0.08, min(0.14, (availableSpan - totalExpectedDuration * 0.75) / Double(m - 1)))
            let reservedPauses = Double(m - 1) * minPause
            let speechBudget = max(Double(m) * 0.35, availableSpan - reservedPauses)
            let ratio = speechBudget / max(0.1, totalExpectedDuration)
            itemDurations = expectedDurations.map { max(0.35, $0 * ratio) }
            itemPause = minPause
        }

        var result: [SubtitleItem] = []
        var curStart = clusterStart

        for (i, orig) in cluster.enumerated() {
            let dur = itemDurations[i]
            let curEnd = curStart + dur
            result.append(
                SubtitleItem(
                    id: orig.id,
                    startTime: CMTime.from(seconds: curStart),
                    endTime: CMTime.from(seconds: curEnd),
                    originalText: orig.originalText,
                    translatedText: orig.translatedText,
                    words: orig.words,
                    dubbedAudioURL: nil
                )
            )
            curStart = curEnd + itemPause
        }

        return result
    }

    /// 解析大模型返回的时间轴数据，并施加发音自然时长与局部防漂移的保底校验
    internal func parseLLMTimeline(
        from response: String,
        baseMatched: [SubtitleItem],
        language: String,
        videoDuration: Double?
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

        guard decoded.subtitles.count == baseMatched.count,
              Set(decoded.subtitles.map(\.id)) == Set(baseMatched.indices),
              decoded.subtitles.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }) else {
            return nil
        }
        let map = Dictionary(decoded.subtitles.map { ($0.id, ($0.start, $0.end)) }, uniquingKeysWith: { first, _ in first })
        var result: [SubtitleItem] = []
        var lastEnd = 0.0

        for (idx, base) in baseMatched.enumerated() {
            let naturalDur = expectedDurationForSubtitle(base, language: language)

            if let timing = map[idx] {
                let requestedDur = timing.1 - timing.0
                let safeDur = max(naturalDur * 0.85, max(0.35, requestedDur))

                // 防漂移约束：大模型微调的结果，起止时间不得偏离局部基准超过 0.6 秒，杜绝跨场景漂移
                let maxDrift = 0.6
                let boundedStart = max(base.startTime.secondsValue - maxDrift,
                                       min(base.startTime.secondsValue + maxDrift, timing.0))
                let safeStart = max(lastEnd + 0.04, boundedStart)
                let safeEnd = safeStart + safeDur

                result.append(SubtitleItem(
                    id: base.id,
                    startTime: CMTime.from(seconds: max(0, safeStart)),
                    endTime: CMTime.from(seconds: safeEnd),
                    originalText: base.originalText,
                    translatedText: base.translatedText,
                    words: base.words,
                    dubbedAudioURL: nil
                ))
                lastEnd = safeEnd
            } else {
                let start = max(lastEnd + 0.04, base.startTime.secondsValue)
                let end = start + base.durationSeconds
                result.append(SubtitleItem(
                    id: base.id,
                    startTime: CMTime.from(seconds: start),
                    endTime: CMTime.from(seconds: end),
                    originalText: base.originalText,
                    translatedText: base.translatedText,
                    words: base.words,
                    dubbedAudioURL: nil
                ))
                lastEnd = end
            }
        }

        return result.count == baseMatched.count ? result : nil
    }

    /// 确定性约束校验器：杜绝字幕重合、保障发音持续时长，且不超过视频上限
    private func enforceStrictConstraints(_ items: [SubtitleItem], videoDuration: Double? = nil) -> [SubtitleItem] {
        guard !items.isEmpty else { return [] }

        var sanitized: [SubtitleItem] = []
        var lastEnd = 0.0

        for (i, item) in items.enumerated() {
            var start = item.startTime.secondsValue
            var end = item.endTime.secondsValue

            // 1. 杜绝上一句与下一句重叠交叉 (保持至少 30ms 间距)
            if i > 0 && start < lastEnd + 0.03 {
                start = lastEnd + 0.03
            }

            // 2. 保证单句至少持续 200ms
            if end < start + 0.20 {
                end = start + 0.20
            }

            // 3. 安全边界截断：不超过视频总时长
            if let maxDur = videoDuration, end > maxDur {
                if start < maxDur - 0.20 {
                    end = maxDur
                } else {
                    start = max(0, maxDur - 0.25)
                    end = maxDur
                }
            }

            let validItem = SubtitleItem(
                id: item.id,
                startTime: CMTime.from(seconds: max(0, start)),
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
