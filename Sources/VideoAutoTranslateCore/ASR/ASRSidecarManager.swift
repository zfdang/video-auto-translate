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

    /// 查找 Python 路径
    public func resolvePythonPath() -> String {
        let candidates = [
            "/Users/zfdang/workspaces/VideoLingo/.venv/bin/python",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        let fileManager = FileManager.default
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

        // 3. 开发工作区路径
        let hardcoded = "/Users/zfdang/workspaces/video-auto-translate/scripts/asr_server.py"
        if fileManager.fileExists(atPath: hardcoded) {
            return hardcoded
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

        let devNull = FileHandle.nullDevice
        p.standardOutput = devNull
        p.standardError = devNull

        do {
            try p.run()
            self.process = p
            let pid = p.processIdentifier

            // 轮询等待健康检查就绪 (最多等待 8 秒)
            for _ in 0..<16 {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                if await checkHealth(port: defaultPort) {
                    await MainActor.run {
                        self.status = .running(pid: pid, port: defaultPort)
                    }
                    return true
                }
            }

            await MainActor.run {
                self.status = .running(pid: pid, port: defaultPort)
            }
            return true
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

    /// 应用完全退出时由 AppDelegate 调用以清理子进程
    public func stop() {
        if let p = process, p.isRunning {
            p.terminate()
            p.waitUntilExit()
            self.process = nil
        }
        status = .idle
    }
}
