import Foundation

enum ProxyStatus {
    case stopped
    case starting
    case running
    case failed(String)
}

final class ProxyProcess {
    private(set) var status: ProxyStatus = .stopped
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    var onStatusChange: ((ProxyStatus) -> Void)?
    var onLogLine: ((String) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

    /// tun 模式（TunRunner）复用同一份可执行文件和架构探测逻辑，所以这两个方法
    /// 从 private 改成 internal（同一个 module 内可见）。
    static func resolveBinaryURL() throws -> URL {
        let arch = currentArch()
        let resourceName = arch == "arm64"
            ? "vless-ws-client-darwin-arm64"
            : "vless-ws-client-darwin-amd64"

        if let resourceDir = Bundle.main.resourceURL {
            let candidate = resourceDir.appendingPathComponent(resourceName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                try ensureExecutable(candidate)
                return candidate
            }
        }

        guard let url = Bundle.module.url(forResource: resourceName, withExtension: nil) else {
            throw NSError(domain: "VlessMenuBar", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "找不到内置的可执行文件 \(resourceName)（既不在 Contents/Resources 也不在 Bundle.module 里），App 打包不完整"
            ])
        }
        try ensureExecutable(url)
        return url
    }

    private static func ensureExecutable(_ url: URL) throws {
        var attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let currentPerm = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        if currentPerm & 0o111 == 0 {
            attrs[.posixPermissions] = NSNumber(value: UInt16(0o755))
            try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
        }
    }

    static func currentArch() -> String {
        if isRunningUnderRosetta() {
            return "arm64"
        }
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
                String(cString: ptr)
            }
        }
        return machine
    }

    private static func isRunningUnderRosetta() -> Bool {
        var ret: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("sysctl.proc_translated", &ret, &size, nil, 0)

        return result == 0 && ret == 1
    }

    func start(config: ProxyConfig, local: LocalProxySettings) {
        stop()
        updateStatus(.starting)

        let localPort = local.localPort
        let recentOutputBox = RecentOutputBox()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let binaryURL = try Self.resolveBinaryURL()
                let proc = Process()
                proc.executableURL = binaryURL
                proc.arguments = config.commandLineArguments(local: local)

                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                self.attachLogReader(pipe: outPipe, recentOutputBox: recentOutputBox)
                self.attachLogReader(pipe: errPipe, recentOutputBox: recentOutputBox)

                proc.terminationHandler = { [weak self] p in
                    guard let self else { return }
                    DispatchQueue.main.async {

                        guard self.process === p else { return }
                        if p.terminationStatus == 0 {
                            self.updateStatus(.stopped)
                        } else {
                            self.updateStatus(.failed("进程退出，退出码 \(p.terminationStatus)，具体原因看日志"))
                            if Self.isPortInUseError(recentOutputBox.value) {
                                self.onLogLine?("[提示] 本地端口 \(localPort) 可能已被占用，可在终端执行以下命令释放端口后重新启动：\nsudo lsof -ti :\(localPort) | xargs kill -9\n")
                            }
                        }
                    }
                }

                try proc.run()

                DispatchQueue.main.async {
                    self.process = proc
                    self.stdoutPipe = outPipe
                    self.stderrPipe = errPipe

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self, self.process?.isRunning == true else { return }
                        if case .starting = self.status {
                            self.updateStatus(.running)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.updateStatus(.failed(error.localizedDescription))
                    if Self.isPortInUseError(error.localizedDescription) {
                        self.onLogLine?("[提示] 本地端口 \(localPort) 可能已被占用，可在终端执行以下命令释放端口后重新启动：\nsudo lsof -ti :\(localPort) | xargs kill -9\n")
                    }
                }
            }
        }
    }

    /// 简单容器，用来在多个闭包（读日志的 handler、terminationHandler）之间
    /// 安全地共享"最近输出内容"，用于判断是否是端口被占用导致的启动失败。
    private final class RecentOutputBox {
        private let lock = NSLock()
        private var text = ""
        private let maxLength = 4000

        var value: String {
            lock.lock()
            defer { lock.unlock() }
            return text
        }

        func append(_ chunk: String) {
            lock.lock()
            text += chunk
            if text.count > maxLength {
                text = String(text.suffix(maxLength))
            }
            lock.unlock()
        }
    }

    /// 根据进程输出内容判断是否是"端口已被占用"导致的启动失败。
    /// 覆盖常见的中英文报错关键字（Go net 包 / 系统调用常见措辞）。
    private static func isPortInUseError(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let keywords = [
            "address already in use",
            "bind: address already in use",
            "port is already in use",
            "端口已被占用",
            "地址已被使用",
            "eaddrinuse",
        ]
        return keywords.contains { lowered.contains($0) }
    }

    func stop() {
        guard let proc = process, proc.isRunning else {
            process = nil
            updateStatus(.stopped)
            return
        }

        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        updateStatus(.stopped)
        proc.terminate()
    }

    private func attachLogReader(pipe: Pipe, recentOutputBox: RecentOutputBox) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            recentOutputBox.append(text)
            DispatchQueue.main.async {
                self?.onLogLine?(text)
            }
        }
    }

    private func updateStatus(_ newStatus: ProxyStatus) {
        status = newStatus
        onStatusChange?(newStatus)
    }
}
