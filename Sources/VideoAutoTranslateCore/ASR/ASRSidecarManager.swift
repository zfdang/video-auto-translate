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
    public var bootstrapPythonPath: String?
    private var runtimeWorker: Task<Void, Error>?
    public var diagnosticLogURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VideoAutoTranslate/asr.log")
    }
    public var runtimeLogURL: URL { diagnosticLogURL.deletingLastPathComponent().appendingPathComponent("runtime-setup.log") }
    public var modelsDirectory: URL?
    private var process: Process?
    public let defaultPort: Int = 8765

    public init() {}

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

    /// 校验 Python 环境是否安装了必须依赖 (fastapi 与 uvicorn)
    private func isPythonCandidateValid(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-c", "import fastapi, uvicorn, multipart, mlx_audio, huggingface_hub"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// 查找 Python 路径 (R13: 智能探测各环境候选并验证依赖有效性)
    public func resolvePythonPath() -> String {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser

        // 1. 优先读取环境变量 VAT_PYTHON_PATH
        if let envPath = ProcessInfo.processInfo.environment["VAT_PYTHON_PATH"],
           fileManager.fileExists(atPath: envPath) {
            return envPath
        }

        // 2. 检查应用专属目录、工作区虚拟环境及 Conda 等候选路径
        var candidates: [String] = []
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport.appendingPathComponent("VideoAutoTranslate/venv/bin/python").path)
            candidates.append(appSupport.appendingPathComponent("VideoAutoTranslate/venv/bin/python3").path)
        }

        // 工作区与常用虚拟环境路径
        candidates.append(URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(".venv/bin/python").path)
        candidates.append(home.appendingPathComponent("workspaces/video-auto-translate/.venv/bin/python").path)
        candidates.append(home.appendingPathComponent("workspaces/VideoLingo/.venv/bin/python").path)
        candidates.append(home.appendingPathComponent("miniconda3/bin/python").path)
        candidates.append(home.appendingPathComponent("miniconda3/bin/python3").path)

        // 标准系统与 Homebrew 路径
        candidates.append("/opt/homebrew/bin/python3")
        candidates.append("/usr/local/bin/python3")
        candidates.append("/usr/bin/python3")

        // 优先筛选已安装 fastapi 依赖的 Python
        for path in candidates {
            if isPythonCandidateValid(path: path) {
                return path
            }
        }

        // 回退选择任意存在的文件路径
        for path in candidates {
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }
        return "/usr/bin/python3"
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

        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice

        do {
            try p.run()
            self.process = p
            let pid = p.processIdentifier

            // 轮询等待健康检查就绪 (最多等待 8 秒)
            for _ in 0..<16 {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                if !p.isRunning {
                    let errData = errPipe.fileHandleForReading.availableData
                    let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let fullDesc = errMsg.isEmpty ? "ASR 子进程异常退出 (PID: \(pid))" : "ASR 引擎启动错误: \(errMsg.prefix(200))"
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
    @MainActor public func prepareManagedRuntime() async {
        guard !isPreparingRuntime else { return }
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
        } catch is CancellationError { runtimeMessage = "已取消环境准备，可重新开始。" }
        catch { runtimeMessage = "准备未完成：\(error.localizedDescription)" }
        isPreparingRuntime = false
        runtimeWorker = nil
    }
    @MainActor public func cancelRuntimePreparation() { runtimeWorker?.cancel() }

}
