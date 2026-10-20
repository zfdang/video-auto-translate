import Foundation

/// 单个模型的本地状态
public enum ModelState: Equatable {
    case notDownloaded
    case downloading(progress: Double, speed: String)
    case ready(localPath: String, sizeDescription: String)
    case failed(String)
}

/// 模型存储与下载管理引擎
public final class ModelStorageManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published public var config: ModelStorageConfig
    @Published public var modelStates: [String: ModelState] = [:]
    @Published public var availableDiskSpaceString: String = ""

    private var downloadSessions: [String: URLSessionDownloadTask] = [:]
    private var downloadProgressHandlers: [String: (Double, String) -> Void] = [:]
    private var downloadStartTimes: [String: Date] = [:]

    public init(config: ModelStorageConfig = ModelStorageConfig()) {
        self.config = config
        super.init()
        refreshAll()
    }

    /// 解析当前生效的模型存储物理目录
    public func resolvedStorageDirectory() -> URL {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser

        switch config.locationType {
        case .shared:
            let sharedDir = home.appendingPathComponent(".cache/huggingface/hub")
            try? fileManager.createDirectory(at: sharedDir, withIntermediateDirectories: true)
            return sharedDir

        case .dedicated:
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? home
            let dedicatedDir = appSupport.appendingPathComponent("VideoAutoTranslate/models")
            try? fileManager.createDirectory(at: dedicatedDir, withIntermediateDirectories: true)
            return dedicatedDir

        case .custom:
            if !config.customDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let customURL = URL(fileURLWithPath: config.customDirectoryPath)
                try? fileManager.createDirectory(at: customURL, withIntermediateDirectories: true)
                return customURL
            }
            // 回退到专属目录
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? home
            let fallbackDir = appSupport.appendingPathComponent("VideoAutoTranslate/models")
            try? fileManager.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
            return fallbackDir
        }
    }

    /// 刷新所有预设模型的下载/就绪状态和磁盘可用空间
    public func refreshAll() {
        updateDiskSpace()
        for preset in ASRModelPreset.allPresets {
            if let downloading = modelStates[preset.id], case .downloading = downloading {
                continue // 不覆盖下载中状态
            }
            modelStates[preset.id] = detectModel(preset)
        }
    }

    /// 更新当前目标磁盘可用空间
    public func updateDiskSpace() {
        let dir = resolvedStorageDirectory()
        do {
            let values = try dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let bytes = values.volumeAvailableCapacityForImportantUsage {
                let gb = Double(bytes) / (1024 * 1024 * 1024)
                availableDiskSpaceString = String(format: "%.1f GB 可用", gb)
                return
            }
        } catch {}
        availableDiskSpaceString = "正常"
    }

    /// 探测指定模型是否已在本地就绪
    public func detectModel(_ preset: ASRModelPreset) -> ModelState {
        let fileManager = FileManager.default
        let targetDir = resolvedStorageDirectory()
        let home = fileManager.homeDirectoryForCurrentUser

        // 候选检查目录列表 (优先目标目录，其次其它可能的共享/历史目录)
        var candidateDirs: [URL] = [targetDir]

        let hfShared = home.appendingPathComponent(".cache/huggingface/hub")
        if targetDir.path != hfShared.path {
            candidateDirs.append(hfShared)
        }

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? home
        let dedicatedDir = appSupport.appendingPathComponent("VideoAutoTranslate/models")
        if targetDir.path != dedicatedDir.path {
            candidateDirs.append(dedicatedDir)
        }

        if preset.isRepo {
            // HuggingFace 仓库形式 (例如 models--mlx-community--Qwen3-ASR-1.7B-8bit)
            let folderSafeName = "models--" + preset.repoOrFileName.replacingOccurrences(of: "/", with: "--")
            for dir in candidateDirs {
                let repoFolder = dir.appendingPathComponent(folderSafeName)
                if fileManager.fileExists(atPath: repoFolder.path) && isDirectoryValidModel(at: repoFolder) {
                    let sizeStr = calculateDirectorySize(at: repoFolder)
                    return .ready(localPath: repoFolder.path, sizeDescription: sizeStr)
                }
                // 也检查直接仓库名子目录
                let directSub = dir.appendingPathComponent(preset.repoOrFileName)
                if fileManager.fileExists(atPath: directSub.path) && isDirectoryValidModel(at: directSub) {
                    let sizeStr = calculateDirectorySize(at: directSub)
                    return .ready(localPath: directSub.path, sizeDescription: sizeStr)
                }
            }
        } else {
            // 单文件形式 (例如 ggml-small.bin)
            for dir in candidateDirs {
                let filePath = dir.appendingPathComponent(preset.repoOrFileName)
                if fileManager.fileExists(atPath: filePath.path) {
                    if let attrs = try? fileManager.attributesOfItem(atPath: filePath.path),
                       let size = attrs[.size] as? Int64, size > 1024 * 1024 {
                        let mb = Double(size) / (1024 * 1024)
                        let sizeStr = String(format: "%.1f MB", mb)
                        return .ready(localPath: filePath.path, sizeDescription: sizeStr)
                    }
                }
            }
        }

        return .notDownloaded
    }

    /// 下载单文件模型 (如 Whisper GGML 文件)
    public func startDirectDownload(for preset: ASRModelPreset) {
        guard !preset.isRepo else { return }

        // 构造下载 URL (默认使用选择的镜像)
        let baseURLStr: String
        switch config.selectedMirror {
        case .hfMirror:
            baseURLStr = "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/"
        case .huggingFace:
            baseURLStr = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
        case .modelScope:
            baseURLStr = "https://modelscope.cn/api/v1/models/AI-ModelScope/whisper.cpp/repo?Revision=master&FilePath="
        }
        guard let downloadURL = URL(string: baseURLStr + preset.repoOrFileName) else { return }

        modelStates[preset.id] = .downloading(progress: 0.0, speed: "连接中...")
        downloadStartTimes[preset.id] = Date()

        let sessionConfig = URLSessionConfiguration.default
        let session = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: .main)
        let task = session.downloadTask(with: downloadURL)
        task.taskDescription = preset.id

        downloadSessions[preset.id] = task
        task.resume()
    }

    /// 通过本地 ASR 服务执行大模型仓库下载 (调用后端 /v1/models/download)
    public func triggerServerRepoDownload(preset: ASRModelPreset, asrBaseURL: String = "http://127.0.0.1:8765") async throws {
        guard let url = URL(string: "\(asrBaseURL)/v1/models/download") else { return }

        let payload: [String: Any] = [
            "model_id": preset.id,
            "repo_id": preset.repoOrFileName,
            "storage_dir": resolvedStorageDirectory().path,
            "mirror": config.selectedMirror.rawValue
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        await MainActor.run {
            self.modelStates[preset.id] = .downloading(progress: 0.05, speed: "服务端启动下载...")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let err = String(data: data, encoding: .utf8) ?? "HTTP 错误"
            await MainActor.run {
                self.modelStates[preset.id] = .failed(err)
            }
            return
        }

        // 启动轮询检查服务端进度
        Task {
            await self.pollServerDownloadProgress(preset: preset, asrBaseURL: asrBaseURL)
        }
    }

    /// 轮询服务端下载进度
    private func pollServerDownloadProgress(preset: ASRModelPreset, asrBaseURL: String) async {
        guard let pollURL = URL(string: "\(asrBaseURL)/v1/models/download/status?model_id=\(preset.id)") else { return }

        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
            do {
                let (data, _) = try await URLSession.shared.data(from: pollURL)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String {
                    if status == "downloading" {
                        let prog = (json["progress"] as? Double) ?? 0.1
                        let speed = (json["speed"] as? String) ?? "下载中..."
                        await MainActor.run {
                            self.modelStates[preset.id] = .downloading(progress: prog, speed: speed)
                        }
                    } else if status == "ready" {
                        let path = (json["local_path"] as? String) ?? self.resolvedStorageDirectory().path
                        await MainActor.run {
                            self.modelStates[preset.id] = .ready(localPath: path, sizeDescription: preset.sizeDescription)
                            self.refreshAll()
                        }
                        break
                    } else if status == "failed" {
                        let err = (json["error"] as? String) ?? "下载失败"
                        await MainActor.run {
                            self.modelStates[preset.id] = .failed(err)
                        }
                        break
                    }
                }
            } catch {
                break
            }
        }
    }

    /// 取消下载
    public func cancelDownload(for presetId: String) {
        downloadSessions[presetId]?.cancel()
        downloadSessions.removeValue(forKey: presetId)
        modelStates[presetId] = .notDownloaded
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let presetId = downloadTask.taskDescription else { return }
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0.0

        let startTime = downloadStartTimes[presetId] ?? Date()
        let elapsed = Date().timeIntervalSince(startTime)
        var speedStr = ""
        if elapsed > 0.5 {
            let bytesPerSec = Double(totalBytesWritten) / elapsed
            let mbPerSec = bytesPerSec / (1024 * 1024)
            speedStr = String(format: "%.1f MB/s", mbPerSec)
        } else {
            speedStr = "计算中..."
        }

        DispatchQueue.main.async {
            self.modelStates[presetId] = .downloading(progress: progress, speed: speedStr)
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let presetId = downloadTask.taskDescription,
              let preset = ASRModelPreset.allPresets.first(where: { $0.id == presetId }) else { return }

        let targetDir = resolvedStorageDirectory()
        let finalPath = targetDir.appendingPathComponent(preset.repoOrFileName)

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: finalPath)
        do {
            try fileManager.moveItem(at: location, to: finalPath)
            DispatchQueue.main.async {
                self.modelStates[presetId] = self.detectModel(preset)
                self.refreshAll()
            }
        } catch {
            DispatchQueue.main.async {
                self.modelStates[presetId] = .failed("移动文件失败: \(error.localizedDescription)")
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let presetId = task.taskDescription else { return }
        if let error = error {
            DispatchQueue.main.async {
                self.modelStates[presetId] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - 工具方法

    /// R26: 校验目录是否包含真实有效的模型文件（配置与权重文件，或总大小大于 50MB）
    private func isDirectoryValidModel(at folderURL: URL) -> Bool {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: [.fileSizeKey]) else { return false }
        var hasConfig = false
        var hasWeights = false
        var totalBytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "config.json" {
                hasConfig = true
            }
            let ext = fileURL.pathExtension.lowercased()
            if ["safetensors", "bin", "npz"].contains(ext) {
                hasWeights = true
            }
            if let res = try? fileURL.resourceValues(forKeys: [.fileSizeKey]), let s = res.fileSize {
                totalBytes += Int64(s)
            }
        }
        return (hasConfig && hasWeights) || totalBytes > 50 * 1024 * 1024
    }

    private func calculateDirectorySize(at url: URL) -> String {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return "~1.8 GB"
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = resourceValues.fileSize {
                total += Int64(size)
            }
        }
        let gb = Double(total) / (1024 * 1024 * 1024)
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        } else {
            let mb = Double(total) / (1024 * 1024)
            return String(format: "%.1f MB", mb)
        }
    }
}
