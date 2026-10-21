import Foundation

public struct OllamaModelTag: Codable {
    public let name: String
    public let size: Int64?
}

public struct OllamaTagsResponse: Codable {
    public let models: [OllamaModelTag]
}

/// Ollama 常用预设推荐模型
public struct OllamaModelPreset: Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let displayName: String
    public let sizeDescription: String
    public let note: String

    public init(name: String, displayName: String, sizeDescription: String, note: String) {
        self.name = name
        self.displayName = displayName
        self.sizeDescription = sizeDescription
        self.note = note
    }

    public static let recommended: [OllamaModelPreset] = [
        OllamaModelPreset(
            name: "qwen2.5:latest",
            displayName: "Qwen 2.5 7B",
            sizeDescription: "~4.7 GB",
            note: "官方推荐：兼顾高精度分句规整与流畅翻译，适合 8GB/16GB+ Mac"
        ),
        OllamaModelPreset(
            name: "qwen2.5:14b",
            displayName: "Qwen 2.5 14B",
            sizeDescription: "~9.0 GB",
            note: "进阶优选：更强复杂语境理解与文学润色，适合 24GB+ 内存机型"
        ),
        OllamaModelPreset(
            name: "qwen2.5:3b",
            displayName: "Qwen 2.5 3B",
            sizeDescription: "~1.9 GB",
            note: "轻量高速：毫秒级响应，适合轻薄本或低内存设备快速处理"
        )
    ]
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

    /// 一键从 Ollama 官方源拉取指定模型，并通过回调实时汇报下载进度
    public func pullModel(
        name: String,
        baseURL: String = "http://localhost:11434",
        onProgress: @escaping (Double, String) -> Void
    ) async throws {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") {
            base = String(base.dropLast(3))
        }

        guard let url = URL(string: "\(base)/api/pull") else {
            throw NSError(domain: "OllamaProbe", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 Ollama 服务地址"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["name": name, "stream": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 7200 // 允许大模型长时间下载

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "OllamaProbe", code: code, userInfo: [NSLocalizedDescriptionKey: "Ollama 服务响应状态异常 (HTTP \(code))"])
        }

        for try await line in asyncBytes.lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let error = json["error"] as? String {
                throw NSError(domain: "OllamaProbe", code: -3, userInfo: [NSLocalizedDescriptionKey: error])
            }
            if let status = json["status"] as? String {
                if status == "success" {
                    onProgress(1.0, "下载完成")
                    return
                }
                let total = (json["total"] as? Double) ?? 0.0
                let completed = (json["completed"] as? Double) ?? 0.0
                if total > 0 {
                    let prog = min(1.0, max(0.0, completed / total))
                    let compMB = completed / (1024 * 1024)
                    let totalMB = total / (1024 * 1024)
                    let speedDesc = String(format: "%.1f MB / %.1f MB", compMB, totalMB)
                    onProgress(prog, speedDesc)
                } else {
                    onProgress(0.05, status)
                }
            }
        }
    }
}
