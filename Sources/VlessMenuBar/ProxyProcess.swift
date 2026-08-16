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

    private func resolveBinaryURL() throws -> URL {
        let arch = Self.currentArch()
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

    private func ensureExecutable(_ url: URL) throws {
        var attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let currentPerm = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        if currentPerm & 0o111 == 0 {
            attrs[.posixPermissions] = NSNumber(value: UInt16(0o755))
            try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
        }
    }

    private static func currentArch() -> String {
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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let binaryURL = try self.resolveBinaryURL()
                let proc = Process()
                proc.executableURL = binaryURL
                proc.arguments = config.commandLineArguments(local: local)

                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                self.attachLogReader(pipe: outPipe)
                self.attachLogReader(pipe: errPipe)

                proc.terminationHandler = { [weak self] p in
                    guard let self else { return }
                    DispatchQueue.main.async {

                        guard self.process === p else { return }
                        if p.terminationStatus == 0 {
                            self.updateStatus(.stopped)
                        } else {
                            self.updateStatus(.failed("进程退出，退出码 \(p.terminationStatus)，具体原因看日志"))
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
                }
            }
        }
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

    private func attachLogReader(pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
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
