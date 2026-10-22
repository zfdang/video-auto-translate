import Foundation
import CoreMedia

/// 基于大语言模型（LLM）的智能语义分句规整与时间轴重构器
public final class LLMSegmenter {
    private let fallbackSegmenter = NaturalLanguageSegmenter()

    public init() {}

    /// 将物理声学 ASR 识别出的词序列送入大模型，依据语法意群进行自然语义断句，并由句首/句末词精确重构时间轴
    /// - Parameters:
    ///   - tokens: 包含物理开始/结束时间戳的词序列 (WordToken)
    ///   - config: 大语言模型参数配置
    ///   - onStatusUpdate: 进度与状态更新回调 (状态描述, 0.0~1.0进度)
    /// - Returns: 经语义断句后的高质量字幕项列表 (SubtitleItem)
    public func segment(
        tokens: [WordToken],
        config: LLMConfiguration,
        onStatusUpdate: ((_ status: String, _ progress: Double) -> Void)? = nil
    ) async throws -> [SubtitleItem] {
        guard !tokens.isEmpty else { return [] }

        let fullRawText = tokens.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullRawText.isEmpty else { return [] }

        let totalTokens = tokens.count
        let batchWordSize = 120
        let totalBatches = max(1, Int(ceil(Double(totalTokens) / Double(batchWordSize))))
        let modelName = config.effectiveModel

        let initialMsg = totalBatches > 1
            ? "正在准备智能分句：分析共 \(totalTokens) 个对齐词，划分为 \(totalBatches) 个批次..."
            : "正在准备智能分句：分析共 \(totalTokens) 个对齐词时间戳..."
        onStatusUpdate?(initialMsg, 0.05)

        defer {
            if config.providerType == .localOllama {
                Task {
                    await OllamaProbe().unloadModel(baseURL: config.ollamaBaseURL, model: config.effectiveModel)
                }
            }
        }

        let client = OpenAICompatibleClient(
            baseURL: config.effectiveBaseURL,
            apiKey: config.effectiveAPIKey,
            timeout: 60.0
        )

        // 分批处理：为保证 LLM 响应速度与上下文连贯性，每批约 120 个词进行分句
        var allSegmentedItems: [SubtitleItem] = []
        var tokenOffset = 0
        var batchIndex = 0

        while tokenOffset < tokens.count {
            batchIndex += 1
            let chunkTokens = Array(tokens[tokenOffset..<min(tokenOffset + batchWordSize, tokens.count)])
            tokenOffset += chunkTokens.count

            // 批次进度：从 0.05 渐进至 0.90
            let batchStartProgress = 0.05 + 0.85 * (Double(batchIndex - 1) / Double(totalBatches))
            let batchAlignProgress = 0.05 + 0.85 * ((Double(batchIndex) - 0.25) / Double(totalBatches))

            let promptMsg = totalBatches > 1
                ? "智能分句 (批次 \(batchIndex)/\(totalBatches)): 正在调用大模型 (\(modelName)) 规划语法意群..."
                : "智能分句: 正在调用大模型 (\(modelName)) 规划语法意群与断句..."
            onStatusUpdate?(promptMsg, batchStartProgress)

            let alignMsg = totalBatches > 1
                ? "智能分句 (批次 \(batchIndex)/\(totalBatches)): 正在吸附物理声学时间戳并重构字幕行..."
                : "智能分句: 正在吸附物理声学时间戳并重构字幕行..."

            let items = try await segmentChunk(
                tokens: chunkTokens,
                config: config,
                client: client,
                onBeforeAlign: {
                    onStatusUpdate?(alignMsg, batchAlignProgress)
                }
            )
            allSegmentedItems.append(contentsOf: items)
        }

        let finalItems: [SubtitleItem]
        if allSegmentedItems.isEmpty {
            onStatusUpdate?("大模型未返回分句，正在使用本地规则安全重构...", 0.92)
            finalItems = fallbackSegmenter.segment(tokens: tokens)
        } else {
            finalItems = allSegmentedItems
        }

        onStatusUpdate?("智能分句重构完成：共生成 \(finalItems.count) 行自然字幕", 1.0)
        return finalItems
    }

    private func segmentChunk(
        tokens: [WordToken],
        config: LLMConfiguration,
        client: OpenAICompatibleClient,
        onBeforeAlign: (() -> Void)? = nil
    ) async throws -> [SubtitleItem] {
        let rawText = tokens.map { $0.text }.joined(separator: " ")

        let systemPrompt = """
        You are an expert video subtitle editor and linguist.
        Your task is to take a continuous stream of speech transcript and split it into natural, grammatically coherent, and readable subtitle lines.

        CRITICAL RULES:
        1. Keep closely connected semantic units, phrases, and modifier groups together on the same line (e.g. NEVER break phrases like "very important", "artificial intelligence", "in front of", "as well as" across two lines).
        2. Suitable line length: 5 to 15 words per line (approx 30 to 65 characters in English, 10 to 25 characters in Chinese).
        3. Do NOT drop, add, or alter any words from the original transcript. Preserve the exact order of words.
        4. You may add appropriate punctuation (periods, commas, question marks) to denote sentence ends.
        5. Return ONLY a valid JSON object matching this schema:
        {
          "lines": [
            "first subtitle line",
            "second subtitle line"
          ]
        }
        """

        let userPrompt = "Please segment this transcript into subtitle lines:\n\n\(rawText)"

        let messages = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]

        let responseText: String
        do {
            responseText = try await client.chatCompletion(
                model: config.effectiveModel,
                messages: messages,
                temperature: 0.1,
                responseFormatJSON: true
            )
        } catch {
            // 模型调用失败时，安全回退到本地规整断句器
            return fallbackSegmenter.segment(tokens: tokens)
        }

        // 解析返回的 JSON 行
        guard let lines = parseLines(from: responseText), !lines.isEmpty else {
            return fallbackSegmenter.segment(tokens: tokens)
        }

        onBeforeAlign?()

        // 将 LLM 分出的行精确对齐映射回原物理 WordTokens，重构开始和结束时间
        return alignLinesToTokens(lines: lines, tokens: tokens)
    }

    private func parseLines(from response: String) -> [String]? {
        let clean = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = clean.data(using: .utf8) else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let lines = json["lines"] as? [String] {
            return lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return array.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        return nil
    }

    private static let omittableFillers: Set<String> = ["um", "uh", "umm", "uhh", "erm", "呃", "嗯"]

    /// 将断句文本对齐到词级时间戳，由首词与末词获得物理时间
    internal func alignLinesToTokens(lines: [String], tokens: [WordToken]) -> [SubtitleItem] {
        var items: [SubtitleItem] = []
        var tokenIdx = 0

        for line in lines {
            guard tokenIdx < tokens.count else { break }

            func normalized(_ value: String) -> String {
                String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            }
            let target = normalized(line)
            guard !target.isEmpty else { continue }
            let startIdx = tokenIdx
            var consumed = ""
            while tokenIdx < tokens.count && consumed != target {
                let token = normalized(tokens[tokenIdx].text)
                let candidate = consumed + token
                if target.hasPrefix(candidate) {
                    consumed = candidate
                } else if !Self.omittableFillers.contains(token) {
                    return fallbackSegmenter.segment(tokens: tokens)
                }
                // Omitted fillers still belong to the physical subtitle tokens.
                tokenIdx += 1
            }
            guard consumed == target else { return fallbackSegmenter.segment(tokens: tokens) }

            let endIdx = max(startIdx, tokenIdx - 1)
            let lineTokens = Array(tokens[startIdx...endIdx])
            guard !lineTokens.isEmpty else { continue }

            let startCM = lineTokens.first!.startCMTime
            let endCM = lineTokens.last!.endCMTime

            items.append(SubtitleItem(
                startTime: startCM,
                endTime: endCM,
                originalText: NaturalLanguageSegmenter.joinTokensText(lineTokens),
                words: lineTokens
            ))
        }

        // 若末尾还有未被分出的物理 Token，补在最后一行保证不漏词
        if tokenIdx < tokens.count {
            let remainingTokens = Array(tokens[tokenIdx...])
            let remText = NaturalLanguageSegmenter.joinTokensText(remainingTokens)
            items.append(SubtitleItem(
                startTime: remainingTokens.first!.startCMTime,
                endTime: remainingTokens.last!.endCMTime,
                originalText: remText,
                words: remainingTokens
            ))
        }

        return items.isEmpty ? fallbackSegmenter.segment(tokens: tokens) : items
    }
}
