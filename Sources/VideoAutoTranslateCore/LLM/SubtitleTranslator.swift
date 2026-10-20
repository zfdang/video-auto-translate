import Foundation

/// 翻译结果项
public struct TranslationEntry: Codable {
    public let id: String
    public let translation: String
}

/// 智能字幕翻译执行器
public final class SubtitleTranslator {
    public init() {}

    /// 执行批量字幕翻译
    /// - Parameters:
    ///   - items: 待翻译的字幕行
    ///   - config: LLM 配置
    ///   - onProgress: 进度回调 (0.0 ~ 1.0)
    public func translate(
        items: [SubtitleItem],
        config: LLMConfiguration,
        onProgress: ((Double) -> Void)? = nil
    ) async throws {
        guard !items.isEmpty else { return }

        let client = OpenAICompatibleClient(
            baseURL: config.effectiveBaseURL,
            apiKey: config.effectiveAPIKey
        )

        // 按 10 句分批进行上下文连贯翻译
        let chunkSize = 10
        let chunks = stride(from: 0, to: items.count, by: chunkSize).map {
            Array(items[$0..<min($0 + chunkSize, items.count)])
        }

        var completedCount = 0
        let totalCount = items.count

        for chunk in chunks {
            try await translateChunk(
                chunk: chunk,
                targetLanguage: config.targetLanguage,
                model: config.effectiveModel,
                temperature: config.temperature,
                client: client
            )

            completedCount += chunk.count
            let currentProgress = Double(completedCount) / Double(totalCount)
            await MainActor.run {
                onProgress?(currentProgress)
            }
        }
    }

    private func translateChunk(
        chunk: [SubtitleItem],
        targetLanguage: String,
        model: String,
        temperature: Double,
        client: OpenAICompatibleClient
    ) async throws {
        // 构建上下文输入列表
        var inputList: [[String: Any]] = []
        for item in chunk {
            inputList.append([
                "id": item.id.uuidString,
                "text": item.originalText
            ])
        }

        let inputJSONData = try JSONSerialization.data(withJSONObject: inputList, options: [.prettyPrinted])
        let inputJSONString = String(data: inputJSONData, encoding: .utf8) ?? "[]"

        let systemPrompt = """
        你是一名顶级的专业影视字幕翻译家。请将输入的字幕列表翻译为【\(targetLanguage)】。
        
        【翻译规范】
        1. 保持原文的语气、情感和语境，口语化、接地气，绝不要生硬直译。
        2. 字符长度限制：每行译文长度必须适中，杜绝长篇大论，方便观众快速阅读。
        3. 必须输出严格的 JSON 数组格式，不要输出任何其他的解释或 Markdown 代码块以外的内容。
        
        输出示例：
        [
          {"id": "...", "translation": "..."},
          {"id": "...", "translation": "..."}
        ]
        """

        let userPrompt = """
        待翻译字幕列表：
        \(inputJSONString)
        """

        let messages = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]

        let responseText = try await client.chatCompletion(
            model: model,
            messages: messages,
            temperature: temperature
        )

        // 解析返回的 JSON 数组
        let entries = try parseTranslationEntries(from: responseText)

        // 回填至各 SubtitleItem
        await MainActor.run {
            let entryDict = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.translation) })
            for item in chunk {
                if let translated = entryDict[item.id.uuidString] {
                    item.translatedText = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
    }

    /// 提取并解析模型返回内容中的 JSON
    private func parseTranslationEntries(from rawText: String) throws -> [TranslationEntry] {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 剥离可能存在的 ```json ... ``` 包裹
        if let startRange = text.range(of: "```json") {
            text = String(text[startRange.upperBound...])
        } else if let startRange = text.range(of: "```") {
            text = String(text[startRange.upperBound...])
        }
        if let endRange = text.range(of: "```", options: .backwards) {
            text = String(text[..<endRange.lowerBound])
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 尝试找到第一个 '[' 和最后一个 ']'
        guard let firstBracket = text.firstIndex(of: "["),
              let lastBracket = text.lastIndex(of: "]"),
              firstBracket <= lastBracket else {
            throw LLMError.parsingFailed("未找到合法的 JSON 数组结构: \(text.prefix(100))...")
        }

        let jsonSubstring = text[firstBracket...lastBracket]
        guard let data = String(jsonSubstring).data(using: .utf8) else {
            throw LLMError.parsingFailed("编码转换失败")
        }

        return try JSONDecoder().decode([TranslationEntry].self, from: data)
    }
}
