import Foundation

/// 翻译结果项
public struct TranslationEntry: Codable {
    public let id: String
    public let translation: String
}

/// 智能字幕翻译执行器
public final class SubtitleTranslator {
    public init() {}

    /// 执行批量字幕翻译 (三阶段生命周期：1. 启动模型 -> 2. 翻译文本 -> 3. 终止模型)
    /// - Parameters:
    ///   - items: 待翻译的字幕行
    ///   - config: LLM 配置
    ///   - onProgress: 进度与状态提示回调 (0.0 ~ 1.0, 状态说明)
    public func translate(
        items: [SubtitleItem],
        config: LLMConfiguration,
        onProgress: ((_ progress: Double, _ status: String) -> Void)? = nil
    ) async throws {
        let items = await MainActor.run {
            items.filter { $0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.translationNeedsReview }
        }
        guard !items.isEmpty else { return }

        let modelName = config.effectiveModel

        // 任务结束/取消/异常时，确保终止本地 Ollama 模型释放显存
        defer {
            if config.providerType == .localOllama {
                Task {
                    await OllamaProbe().unloadModel(baseURL: config.ollamaBaseURL, model: modelName)
                }
            }
        }

        // 阶段 1: 启动模型
        await MainActor.run {
            onProgress?(0.05, "正在启动模型 (\(modelName))...")
        }

        if config.providerType == .localOllama {
            await OllamaProbe().preloadModel(baseURL: config.ollamaBaseURL, model: modelName)
        }

        try Task.checkCancellation()

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
        let totalBatches = chunks.count

        // 阶段 2: 利用模型开始翻译文本
        for (batchIdx, chunk) in chunks.enumerated() {
            try Task.checkCancellation()

            let currentBatch = batchIdx + 1
            let progressBefore = 0.05 + 0.90 * (Double(completedCount) / Double(totalCount))
            let promptText: String
            if totalBatches > 1 {
                promptText = "正在翻译文本 (第 \(currentBatch)/\(totalBatches) 批, \(completedCount)/\(totalCount) 行)..."
            } else {
                promptText = "正在翻译文本 (共 \(totalCount) 行)..."
            }

            await MainActor.run {
                onProgress?(progressBefore, promptText)
            }

            let snapshot = await MainActor.run {
                chunk.map { (id: $0.id, orig: $0.originalText, trans: $0.translatedText) }
            }
            try await Self.retryBatch {
                try await self.translateChunk(
                    chunk: chunk,
                    snapshot: snapshot,
                    targetLanguage: config.targetLanguage,
                    model: modelName,
                    temperature: config.temperature,
                    client: client
                )
            }

            completedCount += chunk.count
            let progressAfter = 0.05 + 0.90 * (Double(completedCount) / Double(totalCount))
            let doneBatchText: String
            if totalBatches > 1 {
                doneBatchText = "正在翻译文本 (第 \(currentBatch)/\(totalBatches) 批完成, \(completedCount)/\(totalCount) 行)..."
            } else {
                doneBatchText = "正在翻译文本 (共 \(totalCount) 行完成)..."
            }

            await MainActor.run {
                onProgress?(progressAfter, doneBatchText)
            }
        }

        try Task.checkCancellation()

        // 阶段 3: 释放模型显存
        await MainActor.run {
            onProgress?(0.98, "正在释放模型显存...")
        }

        if config.providerType == .localOllama {
            await OllamaProbe().unloadModel(baseURL: config.ollamaBaseURL, model: modelName)
        }

        // 适当微小延迟以便状态栏提示平滑过渡展示
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    /// 兼容旧版仅传 Double 的进度回调
    public func translate(
        items: [SubtitleItem],
        config: LLMConfiguration,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        try await translate(items: items, config: config) { progress, _ in
            onProgress(progress)
        }
    }

    /// Retry one failed batch; cancellation must never initiate another request.
    internal static func retryBatch(_ operation: () async throws -> Void) async throws {
        do {
            try Task.checkCancellation()
            try await operation()
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 300_000_000)
            try await operation()
        }
    }

    private func translateChunk(
        chunk: [SubtitleItem],
        snapshot: [(id: UUID, orig: String, trans: String)],
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
        4. 严格保留每一项的原始 "id"，禁止随意修改或遗漏 "id"。
        5. 译文中如需使用引号，请使用中文双引号“”或英文单引号，不要在 JSON 字符串内部使用未转义的英文双引号。
        
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

        // 解析返回的 JSON 数组 (传入当前 chunk 辅助序号或属性兜底匹配)
        let entries = try parseTranslationEntries(from: responseText, chunk: chunk)

        // 回填至各 SubtitleItem (R07 / FU06: 严格快照校验保护人工在途修改; R08: 安全合并去重; R17: 校验批次有效性)
        let finalDict = try validatedTranslations(entries, for: chunk)
        await MainActor.run {
            guard !Task.isCancelled else { return }
            for snap in snapshot {
                guard let item = chunk.first(where: { $0.id == snap.id }),
                      let translated = finalDict[item.id.uuidString] else {
                    continue
                }
                // R07 / FU06: 严格比较当前值与请求发起时的快照，用户任何手动改动（包括清空）均保留，绝不覆盖
                let cleanTranslation = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                if item.originalText == snap.orig && item.translatedText == snap.trans {
                    item.translatedText = cleanTranslation
                    item.translationNeedsReview = false
                }
            }
        }
    }

    internal func validatedTranslations(_ entries: [TranslationEntry], for chunk: [SubtitleItem]) throws -> [String: String] {
        let expected = Set(chunk.map { $0.id.uuidString })
        guard entries.count == chunk.count, Set(entries.map(\.id)) == expected,
              entries.allSatisfy({ !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw LLMError.parsingFailed("本批译文缺失、重复或 ID 不匹配，未覆盖任何已有译文；请重试本批")
        }
        return Dictionary(entries.map { ($0.id, $0.translation) }, uniquingKeysWith: { first, _ in first })
    }

    /// 提取并解析模型返回内容中的 JSON (多层级容错解析器)
    internal func parseTranslationEntries(from rawText: String, chunk: [SubtitleItem] = []) throws -> [TranslationEntry] {
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

        // 预处理常见的大模型 JSON 瑕疵
        var sanitized = text
        // 修复非法转义序列：如 \' 替换为 '
        sanitized = sanitized.replacingOccurrences(of: "\\'", with: "'")
        // 移除数组或对象末尾多余逗号 (trailing comma: ", ]" 或 ", }")
        if let commaRegex = try? NSRegularExpression(pattern: ",\\s*([\\]\\}])", options: []) {
            let range = NSRange(location: 0, length: (sanitized as NSString).length)
            sanitized = commaRegex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: "$1")
        }

        let numericBase = sanitized.range(of: #""(?:id|ID|index)"\s*:\s*0\b"#, options: .regularExpression) != nil ? 0 : 1
        // 辅助闭包：对提取出的单项进行标准化匹配与校验
        func normalizeEntry(id: String, translation: String, index: Int) -> TranslationEntry? {
            let cleanTrans = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTrans.isEmpty else { return nil }
            let cleanId = id.trimmingCharacters(in: .whitespacesAndNewlines)

            // 1. 若 ID 直接匹配 chunk 中的某项 UUID (忽略大小写)
            if let matched = chunk.first(where: { $0.id.uuidString.caseInsensitiveCompare(cleanId) == .orderedSame }) {
                return TranslationEntry(id: matched.id.uuidString, translation: cleanTrans)
            }

            var number = Int(cleanId)
            if number == nil, cleanId.range(of: #"^(?:item|line)_[0-9]+$"#, options: .regularExpression) != nil {
                number = Int(cleanId.split(separator: "_").last ?? "")
            }
            if let number = number {
                let position = number - numericBase
                if chunk.indices.contains(position) {
                    return TranslationEntry(id: chunk[position].id.uuidString, translation: cleanTrans)
                }
            }

            // 4. 若 ID 为空但有 index 序号
            if cleanId.isEmpty && index >= 0 && index < chunk.count {
                return TranslationEntry(id: chunk[index].id.uuidString, translation: cleanTrans)
            }

            // 5. 原样保留
            if !cleanId.isEmpty {
                return TranslationEntry(id: cleanId, translation: cleanTrans)
            }
            return nil
        }

        // 辅助函数：根据引号状态精确定位匹配闭合括号（避免将尾部备注中的 "[1]" 错误视作数组结束）
        func findMatchingClosingBracket(in str: String, openChar: Character, closeChar: Character) -> String.Index? {
            guard let start = str.firstIndex(of: openChar) else { return nil }
            var depth = 0
            var inString = false
            var isEscaped = false

            var idx = start
            while idx < str.endIndex {
                let ch = str[idx]
                if isEscaped {
                    isEscaped = false
                } else if ch == "\\" {
                    isEscaped = true
                } else if ch == "\"" {
                    inString.toggle()
                } else if !inString {
                    if ch == openChar {
                        depth += 1
                    } else if ch == closeChar {
                        depth -= 1
                        if depth == 0 {
                            return idx
                        }
                    }
                }
                idx = str.index(after: idx)
            }
            return nil
        }

        // 策略 1: 尝试解析最外层的 '[' 和 ']' 数组 (精确闭合扫描)
        if let firstBracket = sanitized.firstIndex(of: "["),
           let closeBracket = findMatchingClosingBracket(in: sanitized, openChar: "[", closeChar: "]") ?? sanitized.lastIndex(of: "]"),
           firstBracket <= closeBracket {
            let jsonSubstring = String(sanitized[firstBracket...closeBracket])
            if let data = jsonSubstring.data(using: .utf8),
               let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                var entries: [TranslationEntry] = []
                for (idx, element) in jsonArray.enumerated() {
                    if let dict = element as? [String: Any] {
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
                        if let entry = normalizeEntry(id: idStr, translation: transStr, index: idx) {
                            entries.append(entry)
                        }
                    } else if let str = element as? String, idx < chunk.count {
                        if let entry = normalizeEntry(id: chunk[idx].id.uuidString, translation: str, index: idx) {
                            entries.append(entry)
                        }
                    }
                }
                if !entries.isEmpty {
                    return entries
                }
            }
        }

        // 策略 2: 尝试解析最外层的 '{' 和 '}' 字典 (例如 {"translations": [...]} 或 {"data": [...]})
        if let firstBrace = sanitized.firstIndex(of: "{"),
           let closeBrace = findMatchingClosingBracket(in: sanitized, openChar: "{", closeChar: "}") ?? sanitized.lastIndex(of: "}"),
           firstBrace <= closeBrace {
            let jsonSubstring = String(sanitized[firstBrace...closeBrace])
            if let data = jsonSubstring.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // 2.1 检查字典中的数组字段
                for (_, val) in dict {
                    if let arr = val as? [Any] {
                        var entries: [TranslationEntry] = []
                        for (idx, item) in arr.enumerated() {
                            if let itemDict = item as? [String: Any] {
                                let idVal = itemDict["id"] ?? itemDict["ID"] ?? itemDict["index"] ?? ""
                                let idStr = String(describing: idVal).trimmingCharacters(in: .whitespacesAndNewlines)
                                let transVal = itemDict["translation"] ?? itemDict["translated"] ?? itemDict["target"] ?? itemDict["translated_text"] ?? itemDict["chinese"] ?? itemDict["text"]
                                let transStr: String
                                if let s = transVal as? String {
                                    transStr = s
                                } else if let num = transVal as? NSNumber {
                                    transStr = num.stringValue
                                } else {
                                    transStr = ""
                                }
                                if let entry = normalizeEntry(id: idStr, translation: transStr, index: idx) {
                                    entries.append(entry)
                                }
                            } else if let str = item as? String, idx < chunk.count {
                                if let entry = normalizeEntry(id: chunk[idx].id.uuidString, translation: str, index: idx) {
                                    entries.append(entry)
                                }
                            }
                        }
                        if !entries.isEmpty {
                            return entries
                        }
                    }
                }

                // 2.2 检查字典本身是否就是单条翻译对象
                let idVal = dict["id"] ?? dict["ID"] ?? ""
                let idStr = String(describing: idVal).trimmingCharacters(in: .whitespacesAndNewlines)
                let transVal = dict["translation"] ?? dict["translated"] ?? dict["target"] ?? dict["text"]
                if let transStr = transVal as? String, !transStr.isEmpty {
                    if let entry = normalizeEntry(id: idStr, translation: transStr, index: 0) {
                        return [entry]
                    }
                }
            }
        }

        // 策略 3: 单个对象逐个容错提取 (针对某个对象包含未转义双引号或截断导致整体 JSON 语法错误的情形)
        if let objRegex = try? NSRegularExpression(pattern: "\\{[^{}]*?\\}", options: [.dotMatchesLineSeparators]) {
            let nsStr = sanitized as NSString
            let matches = objRegex.matches(in: sanitized, options: [], range: NSRange(location: 0, length: nsStr.length))
            var entries: [TranslationEntry] = []
            for (idx, match) in matches.enumerated() {
                let block = nsStr.substring(with: match.range)
                if let blockData = block.data(using: .utf8),
                   let itemDict = try? JSONSerialization.jsonObject(with: blockData) as? [String: Any] {
                    let idVal = itemDict["id"] ?? itemDict["ID"] ?? ""
                    let idStr = String(describing: idVal).trimmingCharacters(in: .whitespacesAndNewlines)
                    let transVal = itemDict["translation"] ?? itemDict["translated"] ?? itemDict["target"] ?? itemDict["text"]
                    if let transStr = transVal as? String,
                       let entry = normalizeEntry(id: idStr, translation: transStr, index: idx) {
                        entries.append(entry)
                        continue
                    }
                }
                // 若该对象块整体解析失败（如内部引号冲突），使用正则提取键值
                let idPattern = #""id"\s*:\s*"([^"]+)""#
                let transPattern = #""translation"\s*:\s*"((?:[^"\\]|\\.)*)""#
                if let idReg = try? NSRegularExpression(pattern: idPattern, options: .caseInsensitive),
                   let transReg = try? NSRegularExpression(pattern: transPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                    let bNs = block as NSString
                    let bRange = NSRange(location: 0, length: bNs.length)
                    var idStr = ""
                    var transStr = ""
                    if let idM = idReg.firstMatch(in: block, options: [], range: bRange), idM.numberOfRanges > 1 {
                        idStr = bNs.substring(with: idM.range(at: 1))
                    }
                    if let trM = transReg.firstMatch(in: block, options: [], range: bRange), trM.numberOfRanges > 1 {
                        transStr = bNs.substring(with: trM.range(at: 1))
                    }
                    if !idStr.isEmpty && !transStr.isEmpty,
                       let entry = normalizeEntry(id: idStr, translation: transStr, index: idx) {
                        entries.append(entry)
                    }
                }
            }
            if !entries.isEmpty {
                return entries
            }
        }

        // 策略 4: 行级正则兜底
        let lineIdPattern = #""id"\s*:\s*"([A-Fa-f0-9\-]+|\d+)""#
        let lineTransPattern = #""translation"\s*:\s*"((?:[^"\\]|\\.)*)""#
        if let idReg = try? NSRegularExpression(pattern: lineIdPattern, options: .caseInsensitive),
           let transReg = try? NSRegularExpression(pattern: lineTransPattern, options: .caseInsensitive) {
            let lines = sanitized.components(separatedBy: .newlines)
            var entries: [TranslationEntry] = []
            for (idx, line) in lines.enumerated() {
                let lNs = line as NSString
                let lRange = NSRange(location: 0, length: lNs.length)
                var idStr = ""
                var transStr = ""
                if let idM = idReg.firstMatch(in: line, options: [], range: lRange), idM.numberOfRanges > 1 {
                    idStr = lNs.substring(with: idM.range(at: 1))
                }
                if let trM = transReg.firstMatch(in: line, options: [], range: lRange), trM.numberOfRanges > 1 {
                    transStr = lNs.substring(with: trM.range(at: 1))
                }
                if !idStr.isEmpty && !transStr.isEmpty,
                   let entry = normalizeEntry(id: idStr, translation: transStr, index: idx) {
                    entries.append(entry)
                }
            }
            if !entries.isEmpty {
                return entries
            }
        }

        throw LLMError.parsingFailed("未能提取出有效的 JSON 翻译数据: \(text.prefix(120))...")
    }
}
