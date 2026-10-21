import Foundation

public enum LLMError: LocalizedError {
    case invalidURL
    case networkError(String)
    case serverError(statusCode: Int, message: String)
    case invalidResponseFormat
    case parsingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "大模型 API 地址无效"
        case .networkError(let msg):
            return "网络连接失败: \(msg)"
        case .serverError(let code, let msg):
            return "大模型服务报错 (HTTP \(code)): \(msg)"
        case .invalidResponseFormat:
            return "大模型返回数据格式不符合预期"
        case .parsingFailed(let msg):
            return "结果解析失败: \(msg)"
        }
    }
}

/// 统一的 OpenAI 协议大模型 HTTP 客户端
public actor OpenAICompatibleClient {
    private let baseURL: String
    private let apiKey: String
    private let session: URLSession

    public init(baseURL: String, apiKey: String, timeout: TimeInterval = 60.0) {
        var cleanBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanBase.hasSuffix("/") { cleanBase.removeLast() }
        self.baseURL = cleanBase
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        self.session = URLSession(configuration: config)
    }

    /// 发起 Chat Completion 请求
    public func chatCompletion(
        model: String,
        messages: [[String: String]],
        temperature: Double = 0.3,
        responseFormatJSON: Bool = false,
        maxTokens: Int? = 4096
    ) async throws -> String {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": temperature
        ]

        if let maxTokens = maxTokens {
            payload["max_tokens"] = maxTokens
        }

        if responseFormatJSON {
            payload["response_format"] = ["type": "json_object"]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponseFormat
        }

        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "未知错误"
            throw LLMError.serverError(statusCode: httpResponse.statusCode, message: errorText)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponseFormat
        }

        return content
    }
}
