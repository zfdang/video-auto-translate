import Foundation

public struct OllamaModelTag: Codable {
    public let name: String
    public let size: Int64?
}

public struct OllamaTagsResponse: Codable {
    public let models: [OllamaModelTag]
}

/// 本地 Ollama 服务自动探测器
public final class OllamaProbe {
    public init() {}

    /// 检测本地 Ollama 服务是否在线并获取已安装模型列表
    public func fetchLocalModels(baseURL: String = "http://localhost:11434") async -> [String] {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") {
            base = String(base.dropLast(3))
        }

        guard let url = URL(string: "\(base)/api/tags") else {
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0 // 快速探测，超时 3 秒

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return []
            }

            let tags = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            return tags.models.map { $0.name }
        } catch {
            return []
        }
    }

    /// 寻找推荐的 Qwen 模型（优先推荐纯文本大模型 qwen2.5:latest，其次视觉模型）
    public func findPreferredQwenModel(in models: [String]) -> String? {
        if let match = models.first(where: { $0.contains("qwen2.5") && !$0.contains("vl") }) {
            return match
        }
        if let match = models.first(where: { $0.contains("qwen2.5") }) {
            return match
        }
        if let match = models.first(where: { $0.contains("qwen") }) {
            return match
        }
        return models.first
    }
}
