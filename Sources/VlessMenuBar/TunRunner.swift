import Foundation

/// 取代旧版 SystemProxyManager（调用 networksetup 写系统代理设置）的"系统代理"实现。
///
/// 开启后做的事情（全部在一次 `osascript ... with administrator privileges` 授权里
/// 完成，只弹一次密码框）：
///   1. 用 wireguard-go 的 utun 创建机制启动 vless-ws-client 的 tun 模式子进程
///      （创建 utun 虚拟网卡需要 root 权限，这一步不能省）；
///   2. 通过 `WG_TUN_NAME_FILE` 环境变量拿到内核实际分配的网卡名（比如 utun7——
///      macOS 的 utun 编号是系统按顺序分配的，不能像 Linux/Windows 那样随便起名）；
///   3. 给网卡本身配置 IP（`ifconfig utunN <addr> <addr> up`，point-to-point 网卡
///      的标准写法），然后把默认路由接管过来指向这张网卡；
///   4. 同时给"客户端连服务器"这条路径本身的目标 IP 加一条例外路由（走原来的默认
///      网关），防止流量自己套自己形成死循环。
///
/// 关闭时用另一个提权命令做清理（结束进程 + 撤销路由），会再弹一次密码框——
/// 非 root 的 GUI 进程本身没有权限直接结束一个 root 权限的子进程，也没法回收
/// 它改过的路由表，只能再提权一次单独处理。
final class TunRunner {
    var onStatusChange: ((ProxyStatus) -> Void)?
    var onLogLine: ((String) -> Void)?

    private(set) var status: ProxyStatus = .stopped
    private var tailTimer: Timer?
    private var outOffset: UInt64 = 0
    private var errOffset: UInt64 = 0
    private var childPid: Int32?

    var isRunning: Bool {
        if case .running = status { return true }
        if case .starting = status { return true }
        return false
    }

    private static var stateDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("VlessMenuBar/tun", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var outLogPath: String { stateDir.appendingPathComponent("tun-stdout.log").path }
    private static var errLogPath: String { stateDir.appendingPathComponent("tun-stderr.log").path }
    private static var nameFilePath: String { stateDir.appendingPathComponent("tun-ifname").path }
    private static var stateFilePath: URL { stateDir.appendingPathComponent("tun-state.json") }

    private struct RunState: Codable {
        var pid: Int32
        var ifName: String
        var serverIP: String
        var address4: String
    }

    /// 启动 tun 模式。异步执行（会弹管理员密码框），通过 onStatusChange/onLogLine 报告结果。
    func start(config: ProxyConfig, tun: TunSettings) {
        stopInternal(silent: true)
        updateStatus(.starting)
        onLogLine?("[tun] 正在请求管理员权限以创建虚拟网卡（会弹出密码确认框）…\n")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            guard let serverIP = Self.resolveIPv4(host: config.host) else {
                DispatchQueue.main.async {
                    self.updateStatus(.failed("无法解析服务器地址 \(config.host)"))
                }
                return
            }

            let binaryURL: URL
            do {
                binaryURL = try ProxyProcess.resolveBinaryURL()
            } catch {
                DispatchQueue.main.async { self.updateStatus(.failed(error.localizedDescription)) }
                return
            }

            try? FileManager.default.removeItem(atPath: Self.outLogPath)
            try? FileManager.default.removeItem(atPath: Self.errLogPath)
            try? FileManager.default.removeItem(atPath: Self.nameFilePath)
            self.outOffset = 0
            self.errOffset = 0

            let args = config.tunCommandLineArguments(tun: tun)
            let shellCmd = Self.buildStartShellCommand(
                exePath: binaryURL.path,
                args: args,
                tun: tun,
                serverIP: serverIP,
                nameFilePath: Self.nameFilePath,
                outLogPath: Self.outLogPath,
                errLogPath: Self.errLogPath
            )

            let result = Self.runElevated(shellCmd)
            DispatchQueue.main.async {
                switch result {
                case .success(let output):
                    // 脚本最后一行成功时是 "OK <pid> <ifname>"
                    let parts = output.split(separator: " ")
                    guard parts.count >= 3, parts[0] == "OK",
                          let pid = Int32(parts[1]) else {
                        self.updateStatus(.failed("提权脚本返回了无法识别的结果：\(output)"))
                        return
                    }
                    let ifName = String(parts[2])
                    self.childPid = pid
                    let state = RunState(pid: pid, ifName: ifName, serverIP: serverIP, address4: tun.address4)
                    if let data = try? JSONEncoder().encode(state) {
                        try? data.write(to: Self.stateFilePath, options: .atomic)
                    }
                    self.onLogLine?("[tun] 网卡 \(ifName) 已就绪，默认路由已接管，服务器 \(serverIP) 走例外路由直连\n")
                    self.startTailing()
                    // 兜底：5 秒后子进程还活着就先标记为运行中，避免日志关键字以后改了导致卡在"启动中"。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self else { return }
                        if case .starting = self.status, Self.isPidAlive(pid) {
                            self.updateStatus(.running)
                        }
                    }
                case .failure(let message):
                    self.updateStatus(.failed(message))
                }
            }
        }
    }

    func stop() { stopInternal(silent: false) }

    private func stopInternal(silent: Bool) {
        stopTailing()

        var state: RunState?
        if let data = try? Data(contentsOf: Self.stateFilePath) {
            state = try? JSONDecoder().decode(RunState.self, from: data)
        }
        let pid = childPid ?? state?.pid
        childPid = nil

        guard pid != nil || state != nil else {
            if !silent { updateStatus(.stopped) } else { status = .stopped }
            return
        }

        if !silent { onLogLine?("[tun] 正在请求管理员权限以清理虚拟网卡和路由（会弹出密码确认框）…\n") }

        // 清理这一步也要再弹一次密码框，可能要等用户去点确认，不能占着调用方的线程
        // （调用方基本是主线程：停止按钮、系统代理开关、菜单栏退出）。
        DispatchQueue.global(qos: .utility).async {
            let cmd = Self.buildStopShellCommand(pid: pid, address4: state?.address4, serverIP: state?.serverIP)
            _ = Self.runElevated(cmd)
            try? FileManager.default.removeItem(at: Self.stateFilePath)
        }

        if !silent { updateStatus(.stopped) } else { status = .stopped }
    }

    private static func isPidAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    // ---------- 日志尾随：定时读取被提权命令重定向到文件里的 stdout/stderr ----------

    private func startTailing() {
        tailTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tailOnce()
        }
        RunLoop.main.add(timer, forMode: .common)
        tailTimer = timer
    }

    private func stopTailing() {
        tailTimer?.invalidate()
        tailTimer = nil
    }

    private func tailOnce() {
        tailFile(path: Self.outLogPath, offset: &outOffset)
        tailFile(path: Self.errLogPath, offset: &errOffset)
    }

    private func tailFile(path: String, offset: inout UInt64) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return
        }
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        offset += UInt64(data.count)
        if let text = String(data: data, encoding: .utf8) {
            onLogLine?(text)
            if case .starting = status, text.contains("TUN 模式已启动") {
                updateStatus(.running)
            }
        }
    }

    private func updateStatus(_ newStatus: ProxyStatus) {
        status = newStatus
        onStatusChange?(newStatus)
    }

    // ---------- DNS 解析 ----------

    private static func resolveIPv4(host: String) -> String? {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        guard let sa = first.pointee.ai_addr else { return nil }

        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let ok = getnameinfo(sa, socklen_t(first.pointee.ai_addrlen), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
        guard ok == 0 else { return nil }
        return String(cString: buf)
    }

    // ---------- 提权执行 ----------

    private enum ElevatedResult {
        case success(String)
        case failure(String)
    }

    /// 通过 osascript 弹出管理员密码确认框，以 root 权限跑一段 shell 命令，
    /// 返回该命令自己的 stdout（去掉末尾换行）。用户点了"取消"会走 failure 分支。
    private static func runElevated(_ shellCommand: String) -> ElevatedResult {
        let script = "do shell script \"\(appleScriptEscape(shellCommand))\" with administrator privileges"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return .failure("无法启动 osascript：\(error.localizedDescription)")
        }
        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if err.contains("User canceled") || err.contains("-128") {
                return .failure("已取消：需要管理员权限才能创建虚拟网卡")
            }
            return .failure(err.isEmpty ? "提权命令执行失败（退出码 \(proc.terminationStatus)）" : err)
        }
        if out.hasPrefix("ERR") {
            return .failure(String(out.dropFirst(4)))
        }
        return .success(out)
    }

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // ---------- shell 脚本生成 ----------

    private static func buildStartShellCommand(
        exePath: String, args: [String], tun: TunSettings, serverIP: String,
        nameFilePath: String, outLogPath: String, errLogPath: String
    ) -> String {
        let quotedArgs = args.map(shQuote).joined(separator: " ")
        var cmd = ""
        cmd += "rm -f \(shQuote(nameFilePath)) \(shQuote(outLogPath)) \(shQuote(errLogPath)); "
        // 用 WG_TUN_NAME_FILE 让 wireguard-go 把内核实际分配的 utun 名字写到文件里，
        // 不用自己去猜/轮询 ifconfig 找新增网卡。
        cmd += "WG_TUN_NAME_FILE=\(shQuote(nameFilePath)) "
        cmd += "nohup \(shQuote(exePath)) \(quotedArgs) > \(shQuote(outLogPath)) 2> \(shQuote(errLogPath)) & "
        cmd += "CPID=$!; "
        cmd += "IFN=''; "
        cmd += "for i in $(seq 1 40); do "
        cmd += "  if [ -s \(shQuote(nameFilePath)) ]; then IFN=$(cat \(shQuote(nameFilePath))); break; fi; "
        cmd += "  if ! kill -0 $CPID 2>/dev/null; then echo \"ERR 子进程提前退出，详情看 \(errLogPath)\"; exit 0; fi; "
        cmd += "  sleep 0.5; "
        cmd += "done; "
        cmd += "if [ -z \"$IFN\" ]; then kill -9 $CPID 2>/dev/null; echo 'ERR 等待 20 秒仍未看到虚拟网卡，可能是权限或系统限制导致创建失败'; exit 0; fi; "
        cmd += "if ! ifconfig \"$IFN\" inet \(shQuote(tun.address4)) \(shQuote(tun.address4)) mtu \(tun.mtu) up; then "
        cmd += "  kill -9 $CPID 2>/dev/null; echo 'ERR ifconfig 配置虚拟网卡地址失败'; exit 0; "
        cmd += "fi; "
        cmd += "GW=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}'); "
        cmd += "if [ -n \"$GW\" ]; then route add -host \(shQuote(serverIP)) \"$GW\" >/dev/null 2>&1; fi; "
        cmd += "route add -net 0.0.0.0 -netmask 128.0.0.0 \(shQuote(tun.address4)) >/dev/null 2>&1; "
        cmd += "route add -net 128.0.0.0 -netmask 128.0.0.0 \(shQuote(tun.address4)) >/dev/null 2>&1; "
        cmd += "echo \"OK $CPID $IFN\""
        return cmd
    }

    private static func buildStopShellCommand(pid: Int32?, address4: String?, serverIP: String?) -> String {
        var cmd = ""
        if let pid { cmd += "kill -9 \(pid) >/dev/null 2>&1; " }
        if let address4 {
            cmd += "route delete -net 0.0.0.0 -netmask 128.0.0.0 \(shQuote(address4)) >/dev/null 2>&1; "
            cmd += "route delete -net 128.0.0.0 -netmask 128.0.0.0 \(shQuote(address4)) >/dev/null 2>&1; "
        }
        if let serverIP {
            cmd += "route delete -host \(shQuote(serverIP)) >/dev/null 2>&1; "
        }
        cmd += "echo OK"
        return cmd
    }
}
