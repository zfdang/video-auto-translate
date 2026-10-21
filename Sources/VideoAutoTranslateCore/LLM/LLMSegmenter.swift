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
    /// - Returns: 经语义断句后的高质量字幕项列表 (SubtitleItem)
    public func segment(
        tokens: [WordToken],
        config: LLMConfiguration
    ) async throws -> [SubtitleItem] {
        guard !tokens.isEmpty else { return [] }

        let fullRawText = tokens.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullRawText.isEmpty else { return [] }

        let client = OpenAICompatibleClient(
            baseURL: config.effectiveBaseURL,
            apiKey: config.effectiveAPIKey,
            timeout: 60.0
        )

        // 分批处理：为保证 LLM 响应速度与上下文连贯性，每批约 120 个词进行分句
        let batchWordSize = 120
        var allSegmentedItems: [SubtitleItem] = []
        var tokenOffset = 0

        while tokenOffset < tokens.count {
            let chunkTokens = Array(tokens[tokenOffset..<min(tokenOffset + batchWordSize, tokens.count)])
            tokenOffset += chunkTokens.count

            let items = try await segmentChunk(tokens: chunkTokens, config: config, client: client)
            allSegmentedItems.append(contentsOf: items)
        }

        return allSegmentedItems.isEmpty ? fallbackSegmenter.segment(tokens: tokens) : allSegmentedItems
    }

    private func segmentChunk(
        tokens: [WordToken],
        config: LLMConfiguration,
        client: OpenAICompatibleClient
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

    /// 将断句文本对齐到词级时间戳，由首词与末词获得物理时间
    private func alignLinesToTokens(lines: [String], tokens: [WordToken]) -> [SubtitleItem] {
        var items: [SubtitleItem] = []
        var tokenIdx = 0

        for line in lines {
            guard tokenIdx < tokens.count else { break }

            let wordsInLine = line
                .components(separatedBy: .whitespacesAndNewlines)
                .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
                .filter { !$0.isEmpty }

            guard !wordsInLine.isEmpty else { continue }

            let startIdx = tokenIdx
            var matchedCount = 0

            while tokenIdx < tokens.count && matchedCount < wordsInLine.count {
                let tokenWord = tokens[tokenIdx].text.trimmingCharacters(in: .punctuationCharacters).lowercased()
                if !tokenWord.isEmpty {
                    matchedCount += 1
                }
                tokenIdx += 1
            }

            let endIdx = max(startIdx, tokenIdx - 1)
            let lineTokens = Array(tokens[startIdx...endIdx])
            guard !lineTokens.isEmpty else { continue }

            let startCM = lineTokens.first!.startCMTime
            let endCM = lineTokens.last!.endCMTime

            items.append(SubtitleItem(
                startTime: startCM,
                endTime: endCM,
                originalText: line,
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
