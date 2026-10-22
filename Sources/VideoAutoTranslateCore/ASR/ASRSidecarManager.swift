import Foundation

public enum SidecarStatus: Equatable {
    case idle
    case starting
    case running(pid: Int32, port: Int)
    case error(String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var displayString: String {
        switch self {
        case .idle:
            return "就绪（将在开始首个转录任务时自动唤醒）"
        case .starting:
            return "正在自动唤醒后台推理引擎..."
        case .running(let pid, let port):
            return "后台引擎已托管运行 (热驻留，PID: \(pid), 端口: \(port))"
        case .error(let msg):
            return "引擎异常: \(msg)"
        }
    }
}

/// 负责 App 内部按需延迟启动 (Lazy Start) 并常驻显存、退出时销毁的 ASR 引擎托管器
public final class ASRSidecarManager: ObservableObject {
    public static let shared = ASRSidecarManager()

    @Published public var status: SidecarStatus = .idle
    @Published public var isPreparingRuntime = false
    @Published public var runtimeMessage = "首次使用需准备 Python 环境与识别/对齐模型。"
    @Published public private(set) var isUsingEmbeddedRuntime: Bool = false
    @Published public private(set) var runtimeDescription: String = "正在检测 Python 环境..."
    @Published public private(set) var isRuntimeValid: Bool = false
    @Published public private(set) var isEmbeddedRuntimeCorrupted: Bool = false

    // 线程安全的内部缓存
    private let cacheQueue = DispatchQueue(label: "com.videoautotranslate.environmentCache")
    private var candidateValidationCache: [String: Bool] = [:]
    private var internalCachedPythonPath: String = ""

    private func getCachedValidation(for path: String) -> Bool? {
        cacheQueue.sync { candidateValidationCache[path] }
    }

    private func setCachedValidation(_ isValid: Bool, for path: String) {
        cacheQueue.sync { candidateValidationCache[path] = isValid }
    }

    private func getInternalCachedPythonPath() -> String {
        cacheQueue.sync { internalCachedPythonPath }
    }

    private func setInternalCachedPythonPath(_ path: String) {
        cacheQueue.sync { internalCachedPythonPath = path }
    }

    public func clearEnvironmentCache() {
        cacheQueue.sync {
            candidateValidationCache.removeAll()
            internalCachedPythonPath = ""
        }
    }

    public var bootstrapPythonPath: String?
    private var runtimeWorker: Task<Void, Error>?
    public var diagnosticLogURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VideoAutoTranslate/asr.log")
    }
    public var runtimeLogURL: URL { diagnosticLogURL.deletingLastPathComponent().appendingPathComponent("runtime-setup.log") }
    public var modelsDirectory: URL?
    private var process: Process?
    public let defaultPort: Int = 8765

    public init() {
        Task {
            await self.refreshEnvironment()
        }
    }

    /// 探测当前服务是否已经在运行 (不自动生成新进程)
    public func probeExistingStatus() async {
        if await checkHealth(port: defaultPort) {
            await MainActor.run {
                if !self.status.isRunning {
                    self.status = .running(pid: self.process?.processIdentifier ?? 0, port: self.defaultPort)
                }
            }
        }
    }

    /// 在用户触发第一个任务时按需拉起引擎，并保持常驻
    @discardableResult
    public func ensureRunning() async -> Bool {
        // 1. 如果已经在运行，直接复用（无需重复拉起）
        if await checkHealth(port: defaultPort) {
            await MainActor.run {
                if !self.status.isRunning {
                    self.status = .running(pid: self.process?.processIdentifier ?? 0, port: self.defaultPort)
                }
            }
            return true
        }

        // 2. 否则首次静默拉起子进程
        return await startSidecar()
    }

    /// 校验 Python 环境是否安装了必须依赖 (fastapi, uvicorn, multipart, mlx_audio, huggingface_hub, edge_tts)
    public func isPythonCandidateValid(path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        if let cached = getCachedValidation(for: path) {
            return cached
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-c", "import sys, fastapi, uvicorn, multipart, mlx_audio, huggingface_hub, edge_tts; sys.stdout.write('__VAT_PY_OK__')"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        var isValid = false
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                isValid = (out == "__VAT_PY_OK__")
            }
        } catch {
            isValid = false
        }

        setCachedValidation(isValid, for: path)
        return isValid
    }

    /// 核心环境探测解析逻辑（在后台线程执行以避免阻塞 UI）
    private func performEnvironmentResolution() -> (path: String, isEmbedded: Bool, isCorrupted: Bool, isValid: Bool, description: String) {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser

        // 1. 检查 App 内置嵌入式 Python 运行时候选
        var embeddedCandidates: [(path: String, isBundle: Bool)] = []
        if let resourceURL = Bundle.main.resourceURL {
            let embeddedPy3 = resourceURL.appendingPathComponent("runtime/bin/python3").path
            let embeddedPy = resourceURL.appendingPathComponent("runtime/bin/python").path
            embeddedCandidates.append((embeddedPy3, true))
            embeddedCandidates.append((embeddedPy, true))
        }
        let buildEmbeddedPy3 = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(".build/embedded-runtime/bin/python3").path
        embeddedCandidates.append((buildEmbeddedPy3, false))

        var embeddedFoundOnDisk = false
        for candidate in embeddedCandidates {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                embeddedFoundOnDisk = true
                if isPythonCandidateValid(path: candidate.path) {
                    // 内置运行时存在且依赖完整可用
                    let desc = candidate.isBundle
                        ? "App 内置独立运行环境 (免配置·开箱即用)"
                        : "本地内嵌运行环境 (.build/embedded-runtime)"
                    return (candidate.path, true, false, true, desc)
                }
            }
        }

        // 若内置候选文件存在但依赖不完整或损坏，记录 corrupted 标记，并不在此选择它（继续回退）
        let embeddedCorrupted = embeddedFoundOnDisk

        // 2. 检查外部与回退环境候选列表
        var fallbackCandidates: [String] = []

        // 用户显式指定的 Python
        if let bootstrap = bootstrapPythonPath, fileManager.isExecutableFile(atPath: bootstrap) {
            fallbackCandidates.append(bootstrap)
        }

        // 环境变量 VAT_PYTHON_PATH
        if let envPath = ProcessInfo.processInfo.environment["VAT_PYTHON_PATH"],
           fileManager.isExecutableFile(atPath: envPath) {
            fallbackCandidates.append(envPath)
        }

        // 应用专属隔离环境 (Application Support)
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            fallbackCandidates.append(appSupport.appendingPathComponent("VideoAutoTranslate/venv/bin/python").path)
            fallbackCandidates.append(appSupport.appendingPathComponent("VideoAutoTranslate/venv/bin/python3").path)
        }

        // 工作区与常用虚拟环境路径
        fallbackCandidates.append(URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(".venv/bin/python").path)
        fallbackCandidates.append(home.appendingPathComponent("workspaces/video-auto-translate/.venv/bin/python").path)
        fallbackCandidates.append(home.appendingPathComponent("workspaces/VideoLingo/.venv/bin/python").path)
        fallbackCandidates.append(home.appendingPathComponent("miniconda3/bin/python").path)
        fallbackCandidates.append(home.appendingPathComponent("miniconda3/bin/python3").path)

        // 标准系统与 Homebrew 路径
        fallbackCandidates.append("/opt/homebrew/bin/python3")
        fallbackCandidates.append("/usr/local/bin/python3")
        fallbackCandidates.append("/usr/bin/python3")

        // 优先筛选已安装全部必要依赖的外部 Python
        for path in fallbackCandidates {
            if fileManager.isExecutableFile(atPath: path) && isPythonCandidateValid(path: path) {
                let suffix = embeddedCorrupted ? " (内置环境异常，已自动回退)" : ""
                let desc = friendlyDescription(for: path) + suffix
                return (path, false, embeddedCorrupted, true, desc)
            }
        }

        // 若没有完全匹配全部依赖的环境，回退选择第一个存在的外部可执行解释器
        for path in fallbackCandidates {
            if fileManager.isExecutableFile(atPath: path) {
                let suffix = embeddedCorrupted ? " (内置环境损坏，外部解释器缺少依赖)" : " (缺少依赖)"
                let desc = friendlyDescription(for: path) + suffix
                return (path, false, embeddedCorrupted, false, desc)
            }
        }

        // 若外部无任何可用解释器但内置可执行文件存在（只是缺依赖）
        if embeddedFoundOnDisk, let firstEmbedded = embeddedCandidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return (firstEmbedded.path, false, true, false, "内置环境已损坏 (缺少核心依赖，请重新修复)")
        }

        return ("/usr/bin/python3", false, embeddedCorrupted, false, "未就绪: /usr/bin/python3")
    }

    /// 获取友好格式的环境描述
    private func friendlyDescription(for path: String) -> String {
        if path.contains("VideoAutoTranslate/venv") {
            return "应用专属隔离环境 (Application Support)"
        } else if path.contains(".venv") {
            return "工作区虚拟环境 (.venv)"
        } else if path.contains("miniconda") {
            return "Conda 环境 (\(path))"
        } else if path.hasPrefix("/opt/homebrew") || path.hasPrefix("/usr/local") {
            return "Homebrew Python (\(path))"
        } else {
            return "外部 Python: \(path)"
        }
    }

    /// 查找当前生效的 Python 路径 (优先返回已缓存的结果，若无则执行探测并缓存)
    public func resolvePythonPath() -> String {
        let cached = getInternalCachedPythonPath()
        if !cached.isEmpty {
            return cached
        }

        let result = performEnvironmentResolution()
        setInternalCachedPythonPath(result.path)

        DispatchQueue.main.async {
            self.isUsingEmbeddedRuntime = result.isEmbedded
            self.isEmbeddedRuntimeCorrupted = result.isCorrupted
            self.isRuntimeValid = result.isValid
            self.runtimeDescription = result.description
        }

        return result.path
    }

    /// 在后台异步刷新检测 Python 运行环境并更新 published 状态
    @MainActor
    public func refreshEnvironment() async {
        clearEnvironmentCache()

        let result = await Task.detached(priority: .userInitiated) { [weak self] () -> (path: String, isEmbedded: Bool, isCorrupted: Bool, isValid: Bool, description: String) in
            guard let self = self else { return ("/usr/bin/python3", false, false, false, "未就绪") }
            return self.performEnvironmentResolution()
        }.value

        self.setInternalCachedPythonPath(result.path)
        self.isUsingEmbeddedRuntime = result.isEmbedded
        self.isEmbeddedRuntimeCorrupted = result.isCorrupted
        self.isRuntimeValid = result.isValid
        self.runtimeDescription = result.description
    }

    /// 查找 asr_server.py 脚本路径
    public func resolveServerScriptPath() -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser

        // 1. App Bundle Resources
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = (resourcePath as NSString).appendingPathComponent("scripts/asr_server.py")
            if fileManager.fileExists(atPath: bundled) {
                return bundled
            }
        }

        // 2. 当前目录
        let candidate = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("scripts/asr_server.py").path
        if fileManager.fileExists(atPath: candidate) {
            return candidate
        }

        // 3. 开发工作区路径回退
        let workspaceCandidate = home.appendingPathComponent("workspaces/video-auto-translate/scripts/asr_server.py").path
        if fileManager.fileExists(atPath: workspaceCandidate) {
            return workspaceCandidate
        }

        return nil
    }

    /// 启动子进程
    private func startSidecar() async -> Bool {
        guard let scriptPath = resolveServerScriptPath() else {
            await MainActor.run {
                self.status = .error("未找到 ASR 脚本文件 scripts/asr_server.py")
            }
            return false
        }

        let pythonPath = resolvePythonPath()

        await MainActor.run {
            self.status = .starting
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath)
        p.arguments = [scriptPath, "--port", "\(defaultPort)"]

        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_DISABLE_XET"] = "1"
        p.environment = env

        // 确保日志目录存在并将日志重定向至 diagnosticLogURL (asr.log)
        let logURL = diagnosticLogURL
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            logHandle.seekToEndOfFile()
            p.standardOutput = logHandle
            p.standardError = logHandle
        } else {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }

        do {
            try p.run()
            self.process = p
            let pid = p.processIdentifier

            // 轮询等待健康检查就绪 (最多等待 8 秒)
            for _ in 0..<16 {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                if !p.isRunning {
                    let logContent = (try? String(contentsOf: logURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let lastLines = logContent.components(separatedBy: .newlines).suffix(5).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    let fullDesc = lastLines.isEmpty ? "ASR 子进程异常退出 (PID: \(pid))" : "ASR 引擎启动错误: \(lastLines.prefix(200))"
                    await MainActor.run {
                        self.status = .error(fullDesc)
                    }
                    return false
                }
                if await checkHealth(port: defaultPort) {
                    await MainActor.run {
                        self.status = .running(pid: pid, port: defaultPort)
                    }
                    return true
                }
            }

            // R22: 严禁在超时未响应时伪报 running 状态，终止进程并返回明确失败
            p.terminate()
            await MainActor.run {
                self.status = .error("ASR 服务健康检查超时（8秒内未响应就绪）")
            }
            return false
        } catch {
            await MainActor.run {
                self.status = .error("启动子进程失败: \(error.localizedDescription)")
            }
            return false
        }
    }

    /// 健康检查
    public func checkHealth(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 0.8

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                return true
            }
        } catch {}
        return false
    }

    /// 应用完全退出时由 AppDelegate 调用以清理子进程 (R22: 有界退出，不卡死主线程)
    public func stop() {
        if let p = process, p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(1.5)
            while p.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
            }
            self.process = nil
        }
        status = .idle
    }
    @MainActor public func prepareManagedRuntime(force: Bool = false) async {
        guard !isPreparingRuntime else { return }
        if isUsingEmbeddedRuntime && isRuntimeValid && !isEmbeddedRuntimeCorrupted && !force {
            runtimeMessage = "当前已使用内置独立运行环境，无需重复准备环境。"
            return
        }
        guard let server = resolveServerScriptPath() else { runtimeMessage = "未找到环境准备脚本，请重新安装应用"; return }
        let script = URL(fileURLWithPath: server).deletingLastPathComponent().appendingPathComponent("prepare-runtime.sh")
        let target = diagnosticLogURL.deletingLastPathComponent().appendingPathComponent("venv")
        let logURL = runtimeLogURL
        guard let bootstrap = bootstrapPythonPath ?? ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            runtimeMessage = "请先安装 Python 3.10–3.13，并在此选择解释器。"
            return
        }
        isPreparingRuntime = true
        runtimeMessage = "正在创建独立环境并下载依赖；可以取消，详细进度见日志。"
        let worker = Task.detached {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, target.path, bootstrap]
            process.standardOutput = log
            process.standardError = log
            try Task.checkCancellation()
            try process.run()
            while process.isRunning {
                if Task.isCancelled {
                    process.terminate()
                    let deadline = Date().addingTimeInterval(0.5)
                    while process.isRunning && Date() < deadline { usleep(20_000) }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    throw CancellationError()
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard process.terminationStatus == 0 else {
                let tail = String(data: try Data(contentsOf: logURL), encoding: .utf8)?.split(separator: "\n").suffix(6).joined(separator: "\n") ?? "请查看准备日志"
                throw NSError(domain: "RuntimeSetup", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: tail])
            }
        }
        runtimeWorker = worker
        do {
            try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            runtimeMessage = "环境准备完成。请下载识别模型与对齐模型后开始转录。"
            await self.refreshEnvironment()
        } catch is CancellationError { runtimeMessage = "已取消环境准备，可重新开始。" }
        catch { runtimeMessage = "准备未完成：\(error.localizedDescription)" }
        isPreparingRuntime = false
        runtimeWorker = nil
    }
    @MainActor public func cancelRuntimePreparation() { runtimeWorker?.cancel() }

}
