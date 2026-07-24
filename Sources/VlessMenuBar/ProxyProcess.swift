import Foundation

enum ProxyStatus {
    case stopped
    case starting
    case running
    case failed(String)
}

/// 管理 vless-ws-client 这个子进程的启停，
/// 并从它的标准输出/错误里粗略判断"看起来是不是连上了"。
final class ProxyProcess {
    private(set) var status: ProxyStatus = .stopped
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// 状态变化、日志输出都通过这两个回调通知外面（AppDelegate 里更新菜单栏图标/日志窗口）。
    var onStatusChange: ((ProxyStatus) -> Void)?
    var onLogLine: ((String) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

    /// 从打包进 App 资源里的两个二进制中，挑出跟当前 Mac CPU 架构匹配的那一个。
    /// 用 uname -m 在运行时判断，比编译期 #if arch(...) 更保险
    /// （万一以后要支持在 Intel Mac 上跑 arm64 二进制之类的场景也方便扩展）。
    private func resolveBinaryURL() throws -> URL {
        let arch = Self.currentArch()
        let resourceName = arch == "arm64"
            ? "vless-ws-client-darwin-arm64"
            : "vless-ws-client-darwin-amd64"

        guard let url = Bundle.module.url(forResource: resourceName, withExtension: nil) else {
            throw NSError(domain: "VlessMenuBar", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "找不到内置的可执行文件 \(resourceName)，App 打包可能不完整"
            ])
        }

        // SwiftPM 拷贝资源文件时不一定保留可执行权限，这里保险起见每次都重新加上。
        var attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let currentPerm = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        if currentPerm & 0o111 == 0 {
            attrs[.posixPermissions] = NSNumber(value: UInt16(0o755))
            try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
        }
        return url
    }

    private static func currentArch() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
                String(cString: ptr)
            }
        }
        return machine // "arm64" 或 "x86_64"
    }

    func start(config: ProxyConfig, local: LocalProxySettings) {
        stop() // 保证不会重复启动多个实例
        updateStatus(.starting) // 立刻反馈"正在启动"，不用等下面的后台线程干完活再显示

        // 文件属性检查/改权限、真正拉起子进程（Process.run()）都挪到后台线程做。
        // 这几步偶尔会有明显耗时——尤其是系统第一次运行这个内嵌的可执行文件时，
        // macOS 会做一次安全评估（Gatekeeper/AMFI 校验签名），这个过程如果在主
        // 线程上同步等，会卡住整个界面的重绘和点击响应，看起来就像"侧边栏变灰、
        // 过一会儿才能点"。挪到后台线程后，这些耗时都不会影响界面响应。
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
                        // 关键判断：这次终止通知对应的进程，是不是我们当前还在
                        // 追踪的那一个。如果 self.process 已经不是它了（要么是
                        // 用户主动点了"停止"——stop() 里会立刻把 self.process
                        // 设成 nil；要么是又重新启动了一个新的进程），说明这条
                        // 通知是"过期"的，不应该用它来更新状态，否则就会出现
                        // "自己主动停止，却被判定成异常退出"的情况（比如手动
                        // 终止会收到 SIGTERM，退出码是 15，不代表真的出错了）。
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

                    // vless-ws-client 启动横幅+监听成功的日志几乎是瞬间打印的，
                    // 给 1.5 秒缓冲之后，只要进程还活着就认为是"正常运行中"。
                    // （它跟服务器的连接是每条代理请求单独建立的，不是启动时就长
                    //  连接，所以没法在这里做更精确的"已连接服务器"判断，只能看
                    //  本地监听有没有起来。）
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
        // 先把 self.process 设成 nil，再发终止信号：这样等会儿这个进程真正退出、
        // 它的 terminationHandler 异步触发时，上面那个 "self.process === p" 的
        // 身份检查会是 false（因为 self.process 已经不指向它了），就不会再用
        // "被我们自己终止导致的退出码 15" 去覆盖这里已经设好的 .stopped 状态。
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
