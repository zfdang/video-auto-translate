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

        let snapshot = chunk.map { (id: $0.id, orig: $0.originalText, trans: $0.translatedText) }

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

        // 回填至各 SubtitleItem (R07 / FU06: 严格快照校验保护人工在途修改; R08: 安全合并去重; R17: 校验批次有效性)
        let entryDict = Dictionary(
            entries.map { ($0.id, $0.translation) },
            uniquingKeysWith: { first, _ in first }
        )

        let matchedCount = chunk.filter { entryDict[$0.id.uuidString] != nil }.count
        guard matchedCount > 0 else {
            throw LLMError.parsingFailed("模型返回内容中未包含当前批次的任何字幕 ID (请求 \(chunk.count) 条，匹配 0 条)")
        }

        await MainActor.run {
            for snap in snapshot {
                guard let item = chunk.first(where: { $0.id == snap.id }),
                      let translated = entryDict[item.id.uuidString] else {
                    continue
                }
                // R07 / FU06: 严格比较当前值与请求发起时的快照，用户任何手动改动（包括清空）均保留，绝不覆盖
                let cleanTranslation = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                if item.originalText == snap.orig && item.translatedText == snap.trans {
                    item.translatedText = cleanTranslation
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

        // 策略 1: 尝试找到最外层的 '[' 和 ']' 数组
        if let firstBracket = text.firstIndex(of: "["),
           let lastBracket = text.lastIndex(of: "]"),
           firstBracket <= lastBracket {
            let jsonSubstring = text[firstBracket...lastBracket]
            if let data = String(jsonSubstring).data(using: .utf8),
               let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                var entries: [TranslationEntry] = []
                for dict in jsonArray {
                    let idVal = dict["id"] ?? dict["ID"] ?? dict["index"] ?? ""
                    let idStr = String(describing: idVal).trimmingCharacters(in: .whitespacesAndNewlines)
                    let transVal = dict["translation"] ?? dict["translated"] ?? dict["target"] ?? dict["translated_text"] ?? dict["chinese"] ?? dict["text"]
                    let transStr: String
                    if let s = transVal as? String {
                        transStr = s
                    } else if let num = transVal as? NSNumber {
                        transStr = num.stringValue
                    } else {
                        transStr = ""
                    }
                    if !idStr.isEmpty && !transStr.isEmpty {
                        entries.append(TranslationEntry(id: idStr, translation: transStr))
                    }
                }
                if !entries.isEmpty {
                    return entries
                }
            }
        }

        // 策略 2: 尝试找到最外层的 '{' 和 '}' 字典 (例如 {"translations": [...]} 或 {"data": [...]})
        if let firstBrace = text.firstIndex(of: "{"),
           let lastBrace = text.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            let jsonSubstring = text[firstBrace...lastBrace]
            if let data = String(jsonSubstring).data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (_, val) in dict {
                    if let arr = val as? [[String: Any]] {
                        var entries: [TranslationEntry] = []
                        for item in arr {
                            let idVal = item["id"] ?? item["ID"] ?? item["index"] ?? ""
                            let idStr = String(describing: idVal).trimmingCharacters(in: .whitespacesAndNewlines)
                            let transVal = item["translation"] ?? item["translated"] ?? item["target"] ?? item["translated_text"] ?? item["chinese"] ?? item["text"]
                            let transStr: String
                            if let s = transVal as? String {
                                transStr = s
                            } else if let num = transVal as? NSNumber {
                                transStr = num.stringValue
                            } else {
                                transStr = ""
                            }
                            if !idStr.isEmpty && !transStr.isEmpty {
                                entries.append(TranslationEntry(id: idStr, translation: transStr))
                            }
                        }
                        if !entries.isEmpty {
                            return entries
                        }
                    }
                }
            }
        }

        throw LLMError.parsingFailed("未能提取出有效的 JSON 翻译数据: \(text.prefix(120))...")
    }
}
