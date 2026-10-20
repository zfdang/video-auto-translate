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
        guard let url = URL(string: config.serviceURL) else { return false }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/health"
        guard let healthURL = components?.url else { return false }

        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 2.0

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return true
            }
            return false
        } catch {
            return false
        }
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

        // 4. 添加音频文件
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
                "无法连接到本地 ASR 服务 (\(config.serviceURL))。\n请确保在终端启动了本地 ASR 服务，例如:\npython3 scripts/asr_server.py\n错误详情: \(error.localizedDescription)"
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ASRError.transcriptionFailed("未收到有效 HTTP 响应")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: responseData, encoding: .utf8) ?? "状态码 \(httpResponse.statusCode)"
            throw ASRError.transcriptionFailed("ASR 服务报错: \(errorMsg)")
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
