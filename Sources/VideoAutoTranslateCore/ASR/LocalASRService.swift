import Foundation
import CoreMedia

public struct ASRWordResponse: Codable {
    public let word: String
    public let start: Double
    public let end: Double
}

public struct ASRSegmentResponse: Codable {
    public let id: Int?
    public let text: String
    public let start: Double
    public let end: Double
    public let words: [ASRWordResponse]?
}

public struct ASRTranscriptionResponse: Codable {
    public let text: String?
    public let words: [ASRWordResponse]?
    public let segments: [ASRSegmentResponse]?
}

/// 基于本地轻量 ASR 服务的物理语音识别引擎 (OpenAI Audio API 兼容协议)
public final class LocalASRService: ASREngineProtocol {
    private let config: ASRConfiguration
    private let segmenter = NaturalLanguageSegmenter()
    private let session: URLSession

    public init(config: ASRConfiguration = ASRConfiguration()) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 300 // 语音识别可能耗时较长，5分钟超时
        self.session = URLSession(configuration: sessionConfig)
    }

    /// 快速检测本地 ASR 服务是否在线
    public func checkHealth() async -> Bool {
        let (success, _) = await Self.testConnection(urlString: config.serviceURL)
        return success
    }

    /// 详细测试 ASR 接口连通性并返回耗时与状态说明
    public static func testConnection(urlString: String) async -> (success: Bool, message: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) else {
            return (false, "URL 格式不合法，请输入有效的 http:// 或 https:// 地址")
        }

        var testURLs: [URL] = []
        if var comp = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comp.path = "/health"
            if let u = comp.url { testURLs.append(u) }
            comp.path = "/v1/models"
            if let u = comp.url { testURLs.append(u) }
        }
        testURLs.append(url)

        let start = Date()
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 2.0
        let session = URLSession(configuration: sessionConfig)

        for target in testURLs {
            var req = URLRequest(url: target)
            req.httpMethod = "GET"
            do {
                let (_, response) = try await session.data(for: req)
                if let http = response as? HTTPURLResponse {
                    let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                    if (200...299).contains(http.statusCode) || http.statusCode == 405 {
                        return (true, "连接成功 (HTTP \(http.statusCode) · 延迟 \(elapsed)ms)")
                    }
                }
            } catch {
                continue
            }
        }

        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        return (false, "连接失败: 无法连接至服务 (耗时 \(elapsed)ms，连接被拒绝或超时)")
    }

    public func transcribe(
        audioURL: URL,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> [SubtitleItem] {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw ASRError.audioFileNotFound
        }

        guard let requestURL = URL(string: config.serviceURL) else {
            throw ASRError.engineNotReady("ASR 服务接口 URL 无效: \(config.serviceURL)")
        }

        onProgress?(0.1)

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioURL)
        var body = Data()

        // 1. 添加参数 model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(config.model)\r\n".data(using: .utf8)!)

        // 2. 添加参数 response_format
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("verbose_json\r\n".data(using: .utf8)!)

        // 3. 添加参数 timestamp_granularities[]
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\n".data(using: .utf8)!)
        body.append("word\r\n".data(using: .utf8)!)

        // 4. 添加可选参数 language (非 auto 时显式指定)
        if config.language != "auto" && !config.language.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(config.language)\r\n".data(using: .utf8)!)
        }

        // 5. 添加音频文件
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        onProgress?(0.3)

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(for: request)
        } catch {
            throw ASRError.engineNotReady(
                "无法连接到本地语音识别服务，请前往【设置 - ASR 服务】检查引擎运行状态。"
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ASRError.transcriptionFailed("未收到有效网络响应")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg: String
            if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let detail = json["detail"] as? String {
                errorMsg = detail
            } else if let raw = String(data: responseData, encoding: .utf8), !raw.isEmpty {
                errorMsg = raw
            } else {
                errorMsg = "识别服务响应异常 (HTTP \(httpResponse.statusCode))"
            }

            // 人性化提示映射
            if errorMsg.contains("未在本地模型目录中找到") || errorMsg.contains("Qwen3-ASR") || errorMsg.contains("请先下载模型") {
                throw ASRError.transcriptionFailed("未检测到本地 Qwen3-ASR 语音识别模型，请先前往【设置 - ASR 模型】完成下载。")
            }
            throw ASRError.transcriptionFailed(errorMsg)
        }

        onProgress?(0.75)

        // 解析 verbose_json 响应
        let decoded = try JSONDecoder().decode(ASRTranscriptionResponse.self, from: responseData)

        // 提取词级时间序列
        var wordTokens: [WordToken] = []

        if let words = decoded.words, !words.isEmpty {
            for w in words {
                let startCM = CMTime.from(seconds: w.start)
                let endCM = CMTime.from(seconds: max(w.start + 0.05, w.end))
                wordTokens.append(WordToken(text: w.word, startTime: startCM, endTime: endCM))
            }
        } else if let segments = decoded.segments, !segments.isEmpty {
            // 如果只有 segments，从 segments 提取
            for seg in segments {
                if let segWords = seg.words, !segWords.isEmpty {
                    for w in segWords {
                        wordTokens.append(WordToken(
                            text: w.word,
                            startTime: CMTime.from(seconds: w.start),
                            endTime: CMTime.from(seconds: max(w.start + 0.05, w.end))
                        ))
                    }
                } else {
                    // 按句子构建 token
                    wordTokens.append(WordToken(
                        text: seg.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        startTime: CMTime.from(seconds: seg.start),
                        endTime: CMTime.from(seconds: seg.end)
                    ))
                }
            }
        }

        guard !wordTokens.isEmpty else {
            throw ASRError.transcriptionFailed("识别成功，但未解析出有效的语音词条序列")
        }

        // 规整断句并生成字幕
        let items = segmenter.segment(tokens: wordTokens)
        onProgress?(1.0)
        return items
    }
}
