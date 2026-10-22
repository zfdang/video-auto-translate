import Foundation
import AVFoundation

/// 基于微软 Edge Neural TTS (通过本地 Sidecar 或 edge-tts 管道) 的高质量语音合成引擎
public final class EdgeTTSService: TTSServiceProtocol {
    public let host: String
    public let port: Int
    private let ensureSidecar: () async -> Bool
    private let systemFallback = SystemTTSService()

    public init(host: String = "127.0.0.1", port: Int = 8765) {
        self.host = host
        self.port = port
        self.ensureSidecar = { await ASRSidecarManager.shared.ensureRunning() }
    }

    internal init(ensureSidecar: @escaping () async -> Bool) {
        self.host = "127.0.0.1"
        self.port = 8765
        self.ensureSidecar = ensureSidecar
    }

    public func synthesize(
        text: String,
        voice: String = "zh-CN-YunxiNeural",
        outputURL: URL
    ) async throws -> URL {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            throw TTSError.emptyText
        }

        try Task.checkCancellation()

        // 确保输出文件父目录存在
        let parentDir = outputURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let tempMp3URL = FileManager.default.temporaryDirectory.appendingPathComponent("edge_tts_\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: tempMp3URL) }

        // Only the default local endpoint belongs to the managed sidecar.
        if ["127.0.0.1", "localhost"].contains(host), port == 8765 {
            _ = await ensureSidecar()
            try Task.checkCancellation()
        }

        // 1. 优先尝试本地 Sidecar HTTP 服务合成 (常驻服务，毫秒级响应)
        do {
            let data = try await synthesizeViaHTTP(text: cleanText, voice: voice)
            try data.write(to: tempMp3URL, options: .atomic)
            try finalizeOutput(from: tempMp3URL, to: outputURL)
            return outputURL
        } catch {
            // HTTP 请求未成功 (服务未启动或网络异常)，进入下一步本地 CLI / 回退通道
        }

        try Task.checkCancellation()

        // 2. 尝试通过 Python CLI (edge-tts) 直接执行
        do {
            try await synthesizeViaCLI(text: cleanText, voice: voice, outputMp3URL: tempMp3URL)
            try finalizeOutput(from: tempMp3URL, to: outputURL)
            return outputURL
        } catch {
            // CLI 合成失败
        }

        try Task.checkCancellation()

        // 3. 最终保底：回退到 macOS 系统原生 TTS，确保任务绝不挂死
        // 将 Edge 音色代码回退提取为语言代号 (如 "zh-CN-YunxiNeural" -> "zh-CN")
        let fallbackVoiceCode = voice.split(separator: "-").prefix(2).joined(separator: "-")
        return try await systemFallback.synthesize(text: cleanText, voice: fallbackVoiceCode.isEmpty ? "zh-CN" : fallbackVoiceCode, outputURL: outputURL)
    }

    // MARK: - 内部实现细节

    private func synthesizeViaHTTP(text: String, voice: String) async throws -> Data {
        guard let url = URL(string: "http://\(host):\(port)/v1/audio/speech") else {
            throw TTSError.synthesisFailed("无效的 TTS 端点 URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        let body: [String: Any] = [
            "input": text,
            "voice": voice,
            "speed": 1.0,
            "response_format": "mp3"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200, !data.isEmpty else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TTSError.synthesisFailed("HTTP TTS 服务响应异常 (状态码: \(code))")
        }
        return data
    }

    private func synthesizeViaCLI(text: String, voice: String, outputMp3URL: URL) async throws {
        let pythonPath = ASRSidecarManager.shared.resolvePythonPath()
        guard FileManager.default.fileExists(atPath: pythonPath) else {
            throw TTSError.synthesisFailed("未检测到有效 Python 运行时")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = [
                "-m", "edge_tts",
                "--text", text,
                "--voice", voice,
                "--write-media", outputMp3URL.path
            ]

            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: outputMp3URL.path) {
                    continuation.resume()
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: errData, encoding: .utf8) ?? "进程退出码 \(process.terminationStatus)"
                    continuation.resume(throwing: TTSError.synthesisFailed(msg))
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// 将生成的音频统一转换为目标文件格式 (如将 mp3 解码为 PCM WAV，或直接原子重命名)
    private func finalizeOutput(from sourceURL: URL, to destURL: URL) throws {
        if destURL.pathExtension.lowercased() == "wav" {
            // 将 MP3 转换为标准的 PCM WAV 文件供后续修剪与变速
            let inputFile = try AVAudioFile(forReading: sourceURL)
            let format = inputFile.processingFormat
            let framesPerBlock = AVAudioFrameCount(max(1, Int(format.sampleRate * 0.05)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBlock) else {
                throw TTSError.synthesisFailed("无法创建音频缓冲区")
            }

            try? FileManager.default.removeItem(at: destURL)
            let outputFile = try AVAudioFile(forWriting: destURL, settings: format.settings)
            while inputFile.framePosition < inputFile.length {
                let count = AVAudioFrameCount(min(Int64(framesPerBlock), inputFile.length - inputFile.framePosition))
                try inputFile.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0 else { break }
                try outputFile.write(from: buffer)
            }
        } else {
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        }
    }

    // MARK: - 环境检测与依赖安装辅助方法

    /// 探测当前 Python 环境中是否已安装 edge-tts 库
    public static func probeEdgeTTS() -> (installed: Bool, version: String, pythonPath: String) {
        let python = ASRSidecarManager.shared.resolvePythonPath()
        guard FileManager.default.fileExists(atPath: python) else {
            return (false, "未检测到有效 Python 解释器", python)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-c", "import edge_tts; print(getattr(edge_tts, '__version__', 'ready'))"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                let ver = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "已安装"
                return (true, ver, python)
            }
        } catch {}
        return (false, "未安装", python)
    }

    /// 在当前选定的 Python 环境中一键静默安装 edge-tts 依赖
    public static func installEdgeTTS() async throws {
        let python = ASRSidecarManager.shared.resolvePythonPath()
        guard FileManager.default.fileExists(atPath: python) else {
            throw TTSError.synthesisFailed("未检测到有效 Python 解释器，请先安装 Python 3.10-3.13")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-m", "pip", "install", "--disable-pip-version-check", "edge-tts>=7.0.0"]
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: errData, encoding: .utf8) ?? "pip install 退出码 \(process.terminationStatus)"
                    continuation.resume(throwing: TTSError.synthesisFailed(msg))
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
