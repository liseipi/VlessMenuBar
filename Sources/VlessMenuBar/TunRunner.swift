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
///      的标准写法），然后给"客户端连服务器"这条路线的全部目标 IP 加例外路由
///      （走原来的默认网关），最后才把默认路由接管过来指向这张网卡——例外先于
///      接管，从根上防止客户端自己的流量被自己的 TUN 抓走形成死循环；
///   4. 屏蔽 IPv6：删掉默认 IPv6 路由（本机内核对 inet6 的 -reject/-blackhole
///      路由一律返回 Invalid argument，已实测），并起一个 root 守护循环每 5 秒
///      校验一次——v4 接管路由缺了补上，默认 v6 路由被路由器 RA 加回来就再删，
///      客户端进程一死守护循环自动退出。
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
    private var lastAliveCheck = Date.distantPast

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
    private static var setupLogPath: URL { stateDir.appendingPathComponent("tun-setup.log") }

    private struct RunState: Codable {
        var pid: Int32
        var ifName: String
        var serverIPs: [String]
        var address4: String
        var v6Gateway: String?
    }

    /// 启动 tun 模式。异步执行（会弹管理员密码框），通过 onStatusChange/onLogLine 报告结果。
    func start(config: ProxyConfig, tun: TunSettings) {
        // 双实例防护：两个 VlessMenuBar 实例共用同一个 tun 状态目录，互不知道对方
        // 的存在，一个实例的开关操作会杀掉另一个实例的客户端（2026-09-08 实际
        // 发生过：旧实例把 Debug 版的隧道杀了，Debug 版 UI 还显示"开"）。这里在
        // 动任何东西之前先检查有没有不是自己管理的 TUN 客户端在跑，有就拒绝。
        if let foreignPid = Self.findExistingTunClientPid(), foreignPid != Self.stateFilePid() {
            DispatchQueue.main.async {
                self.updateStatus(.failed("检测到已在运行的 TUN 客户端（pid \(foreignPid)），可能来自另一个 VlessMenuBar 实例或残留进程。请先关闭另一个实例，或等该进程退出后再开启"))
            }
            return
        }

        stopInternal(silent: true)
        updateStatus(.starting)
        onLogLine?("[tun] 正在请求管理员权限以创建虚拟网卡（会弹出密码确认框）…\n")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let serverIPs = Self.resolveIPv4s(host: config.host)
            guard !serverIPs.isEmpty else {
                DispatchQueue.main.async {
                    self.updateStatus(.failed("无法解析服务器地址 \(config.host)"))
                }
                return
            }

            // 提权前先以普通权限捕获当前默认 IPv6 网关（读路由表不需要 root），
            // 存进状态文件，供关闭时恢复被删掉的默认 IPv6 路由。
            let v6Gateway = Self.currentIPv6Gateway()

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
            try? FileManager.default.removeItem(at: Self.setupLogPath)
            self.outOffset = 0
            self.errOffset = 0

            let args = config.tunCommandLineArguments(tun: tun)
            let shellCmd = Self.buildStartShellCommand(
                exePath: binaryURL.path,
                args: args,
                tun: tun,
                serverIPs: serverIPs,
                nameFilePath: Self.nameFilePath,
                outLogPath: Self.outLogPath,
                errLogPath: Self.errLogPath
            )

            let result = Self.runElevated(shellCmd)
            // 不管成功失败，都把提权脚本自己的完整原始输出存一份到文件里，
            // 下次调试不用非得去 App 界面翻日志。
            let rawDump: String
            switch result {
            case .success(let output): rawDump = "SUCCESS\n" + output
            case .failure(let message): rawDump = "FAILURE\n" + message
            }
            try? rawDump.write(to: Self.setupLogPath, atomically: true, encoding: .utf8)

            DispatchQueue.main.async {
                switch result {
                case .success(let output):
                    // AppleScript 的 do shell script 返回文本时换行符是 \r（回车），
                    // 不是 \n——这是 AppleScript 字符串处理的历史遗留行为，之前按 \n
                    // 切分导致 "OK ..." 和 "ROUTE_INFO ..." 两行粘在一起解析出错。
                    let lines = output
                        .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                        .filter { !$0.isEmpty }
                    guard let firstLine = lines.first else {
                        self.updateStatus(.failed("提权脚本没有任何输出"))
                        return
                    }
                    // 第一行成功时是 "OK <pid> <ifname>"，后面还可能跟着一行 "ROUTE_INFO ..."
                    // 汇报路由命令自己的执行结果（成功是空，失败会带报错文字），一并打到日志里。
                    let parts = firstLine.split(separator: " ")
                    guard parts.count >= 3, parts[0] == "OK",
                          let pid = Int32(parts[1]) else {
                        self.updateStatus(.failed("提权脚本返回了无法识别的结果：\(output)"))
                        return
                    }
                    let ifName = String(parts[2])
                    self.childPid = pid
                    let state = RunState(pid: pid, ifName: ifName, serverIPs: serverIPs, address4: tun.address4, v6Gateway: v6Gateway)
                    if let data = try? JSONEncoder().encode(state) {
                        try? data.write(to: Self.stateFilePath, options: .atomic)
                    }
                    self.onLogLine?("[tun] 网卡 \(ifName) 已就绪，默认路由已接管，服务器 \(serverIPs.joined(separator: ", ")) 走例外路由直连\n")
                    for extra in lines.dropFirst() {
                        self.onLogLine?("[tun] \(extra)\n")
                    }
                    self.startTailing()
                    // 兜底：5 秒后确认子进程还活着就标记为运行中（正常路径由日志
                    // 关键字触发），死了也要如实上报失败，避免卡在"启动中"。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self else { return }
                        if case .starting = self.status {
                            if Self.isPidAlive(pid) {
                                self.updateStatus(.running)
                            } else {
                                self.updateStatus(.failed("TUN 客户端进程启动后即退出，请查看运行日志"))
                            }
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
        var pid = childPid ?? state?.pid
        childPid = nil

        if pid == nil {
            // 状态文件缺失或解析不出来（旧版本 schema / 文件损坏）时，用 pgrep
            // 兜底找残留的 tun 客户端，避免孤儿 root 进程和它占着的路由没人清理。
            pid = Self.findExistingTunClientPid()
        }

        guard pid != nil || state != nil else {
            if !silent { updateStatus(.stopped) } else { status = .stopped }
            return
        }

        if !silent { onLogLine?("[tun] 正在请求管理员权限以清理虚拟网卡和路由（会弹出密码确认框）…\n") }

        // 清理这一步也要再弹一次密码框，可能要等用户去点确认，不能占着调用方的线程
        // （调用方基本是主线程：停止按钮、系统代理开关、菜单栏退出）。
        DispatchQueue.global(qos: .utility).async {
            let cmd = Self.buildStopShellCommand(pid: pid, address4: state?.address4, serverIPs: state?.serverIPs, v6Gateway: state?.v6Gateway)
            _ = Self.runElevated(cmd)
            try? FileManager.default.removeItem(at: Self.stateFilePath)
        }

        if !silent { updateStatus(.stopped) } else { status = .stopped }
    }

    /// 用 ps 判断进程是否还活着。不能用 kill(pid, 0)：客户端是 root 起的，非 root
    /// 进程对它发信号（哪怕信号 0）会 EPERM，永远返回"死了"（已实测 kill -0 <root pid>）。
    private static func isPidAlive(_ pid: Int32) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", String(pid), "-o", "pid="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return false
        }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    /// 找当前正在跑的 tun 模式客户端 pid（不属于本 App 管理的也算）。pgrep 模式写成
    /// -tu[n] 防自匹配：pgrep 自己进程的命令行里也含这段文本，字符类让正则匹配不到自己。
    private static func findExistingTunClientPid() -> Int32? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", "vless-ws-client.*-tu[n] "]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in out.components(separatedBy: .newlines) {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid > 0 {
                return pid
            }
        }
        return nil
    }

    /// 状态文件里记录的客户端 pid（新 schema 解析失败返回 nil）。
    private static func stateFilePid() -> Int32? {
        guard let data = try? Data(contentsOf: stateFilePath),
              let state = try? JSONDecoder().decode(RunState.self, from: data) else { return nil }
        return state.pid
    }

    // ---------- 日志尾随：定时读取被提权命令重定向到文件里的 stdout/stderr ----------

    private func startTailing() {
        tailTimer?.invalidate()
        lastAliveCheck = .distantPast
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
        // 每 2 秒确认一次子进程还活着。客户端死了内核会自动销毁它创建的 utun 并
        // 连带移除接管路由，但 App 若不知道，UI 会一直显示"运行中"（2026-09-08
        // 的事故就是这种状态：旧实例杀了客户端，Debug 版 UI 还显示 TUN 开）。
        if Date().timeIntervalSince(lastAliveCheck) >= 2,
           let pid = childPid,
           case .running = status,
           !Self.isPidAlive(pid) {
            stopTailing()
            childPid = nil
            updateStatus(.failed("TUN 客户端进程已退出，隧道与路由已失效，请重新开启系统代理"))
        }
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

    /// 解析服务器域名的全部 IPv4 记录（去重）。例外路由必须覆盖全部 A 记录：
    /// 屏蔽 IPv6 后客户端只能走 IPv4，若它连到没加例外的 IP，流量会被自己的
    /// TUN 抓走形成自环。Cloudflare 域名一般有多个 A 记录，只加第一个会漏。
    private static func resolveIPv4s(host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }

        var ips: [String] = []
        var seen = Set<String>()
        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let info = ptr {
            if let sa = info.pointee.ai_addr {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let ok = getnameinfo(sa, socklen_t(info.pointee.ai_addrlen), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
                if ok == 0 {
                    let ip = String(cString: buf)
                    if !seen.contains(ip) {
                        seen.insert(ip)
                        ips.append(ip)
                    }
                }
            }
            ptr = info.pointee.ai_next
        }
        return ips
    }

    /// 当前默认 IPv6 网关（走物理网卡的才算数；走 utun 的是别的 VPN 加的，不归我们管）。
    private static func currentIPv6Gateway() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/route")
        proc.arguments = ["-n", "get", "-inet6", "default"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in out.components(separatedBy: .newlines) {
            if line.hasPrefix("gateway:"), !line.contains("utun") {
                return line.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
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
        exePath: String, args: [String], tun: TunSettings, serverIPs: [String],
        nameFilePath: String, outLogPath: String, errLogPath: String
    ) -> String {
        let quotedArgs = args.map(shQuote).joined(separator: " ")
        var cmd = ""
        cmd += "rm -f \(shQuote(nameFilePath)) \(shQuote(outLogPath)) \(shQuote(errLogPath)); "
        // 清掉可能残留的 tun 模式客户端。pkill 模式写成 -tu[n] 防自杀：执行本脚本的
        // 父 shell 命令行里也包含这些文本，字符类让正则匹配不到父 shell 自己。
        // 参数列表是单引号逐项包裹的（'-tun'），"-tun" 后面跟的是引号不是空格，
        // 也不会命中 "-tun " 模式。杀掉旧客户端后内核会销毁它的 utun 并连带清掉
        // 它留下的接管路由，给下面重新加路由一个干净起点。
        cmd += "pkill -f 'vless-ws-client.*-tu[n] ' 2>/dev/null; sleep 0.3; "
        // 用 WG_TUN_NAME_FILE 让 wireguard-go 把内核实际分配的 utun 名字写到文件里，
        // 不用自己去猜/轮询 ifconfig 找新增网卡。
        cmd += "WG_TUN_NAME_FILE=\(shQuote(nameFilePath)) "
        // 不用 nohup（在 do shell script 这种没有真实终端的环境下，nohup 自己
        // 检测"要不要脱离控制终端"这一步会直接报错退出，见 macOS 上这个已知
        // 问题：nohup: can't detach from console: Inappropriate ioctl for
        // device）。改成用一个一次性的 sh -c 忽略 SIGHUP 之后 exec 替换成真正
        // 的程序——这样能达到跟 nohup 一样"终端关掉也不会被杀"的效果，同时 PID
        // 在 exec 前后不变，$! 拿到的还是真正 vless-ws-client 的 PID。
        cmd += "sh -c 'trap \"\" HUP; exec \"$0\" \"$@\"' \(shQuote(exePath)) \(quotedArgs) < /dev/null > \(shQuote(outLogPath)) 2> \(shQuote(errLogPath)) & "
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
        // 服务器例外路由必须先于接管路由添加：客户端刚启动的第一条连接走的是系统
        // 直连（此时还没接管默认路由），例外路由就位后才接管，从根上避免客户端
        // 自己的流量被自己的 TUN 抓走形成死循环。
        cmd += "HOSTRT=''; "
        cmd += "if [ -n \"$GW\" ]; then for ip in \(serverIPs.map(shQuote).joined(separator: " ")); do "
        cmd += "  HOSTRT=\"$HOSTRT $(route add -host \"$ip\" \"$GW\" 2>&1)\"; "
        cmd += "done; fi; "
        // 关键：这两条接管默认路由的命令写成 "-interface $IFN" 而不是
        // "-gateway <网卡自己的地址>"。对 utun 这种点对点网卡，网关地址跟本机
        // 地址是同一个的时候，用网关 IP 的写法在某些 macOS 版本上对新建 TCP
        // 连接的路由缓存处理不一致（UDP 发送不受影响，但 TCP 三次握手用的是
        // 完全不同的内核路径）——直接指定接口名是官方 WireGuard macOS 客户端
        // 实际在用、更可靠的写法。
        cmd += "R2=$(route add -net 0.0.0.0/1 -interface \"$IFN\" 2>&1); "
        cmd += "R3=$(route add -net 128.0.0.0/1 -interface \"$IFN\" 2>&1); "
        // 屏蔽 IPv6 出站流量：Google 等很多网站在有 IPv6 的网络下会优先返回
        // IPv6 地址，而我们只接管了 IPv4 的默认路由——如果不管 IPv6，这部分流量
        // 会直接从真实网络出去，完全绕开 VLESS 隧道（"IPv6 泄漏"），跟没开
        // VPN 一样。本机内核（Darwin 24.x）对 inet6 的 -reject/-blackhole 路由
        // 一律返回 Invalid argument（已提权实测），所以改成删掉默认 IPv6 路由：
        // 没有默认路由后系统对全局 IPv6 立即报不可达，浏览器和 Go dialer 自动
        // 回退 IPv4 走隧道。路由器 RA 周期广播可能把默认路由加回来，由下面的
        // 守护循环负责再删。
        cmd += "R4=$(route delete -inet6 default 2>&1); "
        // root 路由守护循环：每 5 秒校验一次。v4 接管路由被系统清掉就补回；
        // 默认 v6 路由被 RA 加回来就再删。客户端进程一死循环自动退出。
        cmd += "sh -c 'trap \"\" HUP; while kill -0 \"$1\" 2>/dev/null; do "
        cmd += "  route -n get 1.0.0.0 >/dev/null 2>&1 || route add -net 0.0.0.0/1 -interface \"$2\" >/dev/null 2>&1; "
        cmd += "  route -n get 129.0.0.0 >/dev/null 2>&1 || route add -net 128.0.0.0/1 -interface \"$2\" >/dev/null 2>&1; "
        cmd += "  route -n get -inet6 2606:4700:: >/dev/null 2>&1 && route delete -inet6 default >/dev/null 2>&1; "
        cmd += "  sleep 5; "
        cmd += "done' _ \"$CPID\" \"$IFN\" </dev/null >/dev/null 2>&1 & "
        cmd += "DAPID=$!; "
        cmd += "echo \"OK $CPID $IFN\"; "
        cmd += "echo \"ROUTE_INFO gw=$GW host_routes=[$HOSTRT] route1=$R2 route2=$R3 v6delete=$R4 daemon_pid=$DAPID\""
        return cmd
    }

    private static func buildStopShellCommand(pid: Int32?, address4: String?, serverIPs: [String]?, v6Gateway: String?) -> String {
        var cmd = ""
        if let pid { cmd += "kill -9 \(pid) >/dev/null 2>&1; " }
        if address4 != nil {
            cmd += "route delete -net 0.0.0.0/1 >/dev/null 2>&1; "
            cmd += "route delete -net 128.0.0.0/1 >/dev/null 2>&1; "
        }
        if let serverIPs {
            for ip in serverIPs {
                cmd += "route delete -host \(shQuote(ip)) >/dev/null 2>&1; "
            }
        }
        // 恢复被删掉的默认 IPv6 路由（尽力而为：即便不恢复，路由器 RA 广播也会在
        // 一两分钟内自行把它加回来）。
        if let v6Gateway {
            cmd += "route -n get -inet6 default >/dev/null 2>&1 || route add -inet6 default \(shQuote(v6Gateway)) >/dev/null 2>&1; "
        }
        cmd += "echo OK"
        return cmd
    }
}
