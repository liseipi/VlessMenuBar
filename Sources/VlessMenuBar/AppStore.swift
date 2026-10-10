import Foundation
import Combine

enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard = "仪表板"
    case profiles = "代理配置"
    case systemProxy = "系统代理"
    case localProxy = "本地代理"
    case logs = "运行日志"
    case preferences = "偏好设置"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .dashboard: return "info.circle"
        case .profiles: return "rectangle.stack"
        case .systemProxy: return "slider.horizontal.3"
        case .localProxy: return "wifi"
        case .logs: return "terminal"
        case .preferences: return "gearshape"
        }
    }
}

final class AppStore: ObservableObject {
    @Published var profiles: [ProxyProfile] = []
    @Published var activeProfileID: UUID?
    @Published var selectedSection: SidebarSection? = .dashboard
    @Published var localSettings: LocalProxySettings = LocalProxyStore.load()

    @Published private(set) var proxyStatus: ProxyStatus = .stopped
    @Published private(set) var uptimeSeconds: Int = 0
    @Published var systemProxyIsOn = false
    @Published var logLines: [String] = []
    @Published var tunSettings: TunSettings = TunSettingsStore.load()
    @Published var systemProxyMode: SystemProxyMode = SystemProxyModeStore.load()
    private var activeSystemProxyMode: SystemProxyMode?

    private let proxyProcess = ProxyProcess()
    private let tunRunner = TunRunner()
    private let wakeMonitor = SleepWakeMonitor()
    /// 用户"想让代理保持运行"的意图：点了启动 = true，点了停止/退出 = false。
    /// 睡眠唤醒、网络切换后的自动重连只在这个标志为 true 时才会发生。
    private var shouldBeRunning = false
    private var reconnectWork: DispatchWorkItem?
    private var uptimeTimer: Timer?
    private var startedAt: Date?
    private let maxLogLines = 2000

    var activeProfile: ProxyProfile? {
        profiles.first { $0.id == activeProfileID } ?? profiles.first
    }

    var isRunning: Bool { proxyProcess.isRunning }

    init() {
        let loaded = ProfileStore.load()
        profiles = loaded.profiles
        activeProfileID = loaded.activeID

        proxyProcess.onStatusChange = { [weak self] status in
            DispatchQueue.main.async { self?.handleStatusChange(status) }
        }
        proxyProcess.onLogLine = { [weak self] line in
            DispatchQueue.main.async { self?.appendLog(line) }
        }

        tunRunner.onStatusChange = { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                // 只有当前真正生效的模式是 tun 时，才让 TunRunner 的事件影响
                // systemProxyIsOn——避免用户切到传统模式之后，tun 那边残留的
                // 事件把状态搅乱。
                guard self.activeSystemProxyMode == .tun else { return }
                switch status {
                case .running, .starting:
                    self.systemProxyIsOn = true
                case .failed(let message):
                    self.systemProxyIsOn = false
                    self.activeSystemProxyMode = nil
                    self.appendLog("[tun] 启动失败：\(message)\n")
                case .stopped:
                    self.systemProxyIsOn = false
                }
            }
        }
        tunRunner.onLogLine = { [weak self] line in
            DispatchQueue.main.async { self?.appendLog("[tun] " + line) }
        }

        wakeMonitor.onWake = { [weak self] in self?.handleSystemWake() }
        wakeMonitor.onNetworkChanged = { [weak self] in self?.handleNetworkChanged() }
    }

    func addProfile(_ profile: ProxyProfile) {
        profiles.append(profile)
        if activeProfileID == nil { activeProfileID = profile.id }
        persistProfiles()
    }

    func updateProfile(_ profile: ProxyProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        persistProfiles()
        if profile.id == activeProfileID, isRunning {

            restart()
        }
    }

    func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id {
            activeProfileID = profiles.first?.id
        }
        persistProfiles()
    }

    func setActiveProfile(_ id: UUID) {
        guard activeProfileID != id else { return }
        activeProfileID = id
        persistProfiles()
        if isRunning {
            restart()
        }
    }

    private func persistProfiles() {
        ProfileStore.save(profiles: profiles, activeID: activeProfileID)
    }

    func updateLocalSettings(_ settings: LocalProxySettings) {
        let wasRunning = isRunning
        localSettings = settings
        LocalProxyStore.save(settings)
        if wasRunning {
            restart()
        }
    }

    func start() {
        if startProxyProcess() { shouldBeRunning = true }
    }

    /// 真正启动子进程。校验失败返回 false。不改动 shouldBeRunning，
    /// 这样自动重连可以复用而不会改变用户意图。
    @discardableResult
    private func startProxyProcess() -> Bool {
        guard let profile = activeProfile else {
            proxyStatus = .failed("还没有任何节点，请先去「代理配置」新增一个")
            return false
        }
        if let err = localSettings.validationError() {
            proxyStatus = .failed("本地代理设置有问题：\(err)")
            return false
        }
        if let err = profile.config.validationError() {
            proxyStatus = .failed("当前节点「\(profile.name)」配置不完整：\(err)")
            appendLog("[界面] 无法启动：\(err)\n")
            return false
        }
        proxyProcess.start(config: profile.config, local: localSettings)
        startUptimeTimer()
        return true
    }

    func stop() {
        shouldBeRunning = false
        reconnectWork?.cancel()
        reconnectWork = nil
        proxyProcess.stop()
        stopUptimeTimer()
        if systemProxyIsOn {
            stopActiveSystemProxy()
        }
    }

    // MARK: - 睡眠唤醒 / 网络切换后的自动重连

    private func handleSystemWake() {
        if activeSystemProxyMode == .tun {
            // tun 模式的子进程是 root 权限，重启需要再弹管理员密码框，
            // 不适合在唤醒瞬间自动做，这里只提示。
            appendLog("[自动重连] 系统已唤醒。tun 模式需要管理员权限才能重建，如果连不上请手动关闭再开启系统代理\n")
        }
        guard shouldBeRunning else { return }
        appendLog("[自动重连] 检测到系统从睡眠中唤醒，等待网络恢复…\n")
        waitForNetworkThenReconnect(reason: "系统唤醒", deadline: Date().addingTimeInterval(20))
    }

    private func handleNetworkChanged() {
        guard shouldBeRunning else { return }
        // 网络刚恢复/切换，给 DHCP、DNS 一点时间稳定。同一时间段内多次触发会合并成一次。
        scheduleReconnect(reason: "网络已恢复或切换", after: 2.0)
    }

    /// 唤醒后 Wi-Fi 往往要几秒才重新连上，网络没好就重启进程只会马上又失败。
    private func waitForNetworkThenReconnect(reason: String, deadline: Date) {
        if wakeMonitor.isNetworkSatisfied || Date() > deadline {
            scheduleReconnect(reason: reason, after: 2.0)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.shouldBeRunning else { return }
                self.waitForNetworkThenReconnect(reason: reason, deadline: deadline)
            }
        }
    }

    /// 防抖：新的重连请求会取消还没执行的旧请求。
    private func scheduleReconnect(reason: String, after delay: TimeInterval, attempt: Int = 0) {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performReconnect(reason: reason, attempt: attempt)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 只重启本地代理子进程，**不**碰系统代理设置（networksetup 的设置本身不会丢，
    /// 只要本地端口重新有人监听就能用；不能走 restart()，它会顺手把系统代理关掉）。
    private func performReconnect(reason: String, attempt: Int) {
        guard shouldBeRunning else { return }
        appendLog("[自动重连] \(reason)，重启代理进程（第 \(attempt + 1) 次）…\n")
        proxyProcess.stop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.shouldBeRunning else { return }
            guard self.startProxyProcess() else { return }

            // 3 秒后进程已经退出（比如端口还没释放、网络还没通），退避重试，最多 3 次
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, self.shouldBeRunning else { return }
                guard !self.proxyProcess.isRunning else { return }
                if attempt < 3 {
                    let backoff = TimeInterval(2 << attempt) // 2s, 4s, 8s
                    self.scheduleReconnect(reason: "重启后进程未存活", after: backoff, attempt: attempt + 1)
                } else {
                    self.appendLog("[自动重连] 连续重试失败，请检查网络后手动启动\n")
                }
            }
        }
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.start()
        }
    }

    private func handleStatusChange(_ status: ProxyStatus) {
        proxyStatus = status
        if case .stopped = status { stopUptimeTimer() }
        if case .failed = status { stopUptimeTimer() }
    }

    private func startUptimeTimer() {
        stopUptimeTimer()
        startedAt = Date()
        uptimeSeconds = 0
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in

            DispatchQueue.main.async {
                guard let self, let startedAt = self.startedAt else { return }
                self.uptimeSeconds = Int(Date().timeIntervalSince(startedAt))
            }
        }
    }

    private func stopUptimeTimer() {
        uptimeTimer?.invalidate()
        uptimeTimer = nil
        startedAt = nil
        uptimeSeconds = 0
    }

    /// 切换"系统代理"用传统模式还是 tun 模式。开着的时候不允许切，先关掉再选。
    func setSystemProxyMode(_ mode: SystemProxyMode) {
        guard !systemProxyIsOn else {
            appendLog("[界面] 请先关闭系统代理，再切换传统模式/TUN 模式\n")
            return
        }
        systemProxyMode = mode
        SystemProxyModeStore.save(mode)
    }

    /// "系统代理"开关：根据 systemProxyMode 选择用传统模式（调用 networksetup，
    /// 依赖仪表板的本地代理已经在跑）还是 tun 模式（虚拟网卡接管系统路由，
    /// 独立于仪表板本地代理运行）。
    func toggleSystemProxy() {
        if systemProxyIsOn {
            stopActiveSystemProxy()
            return
        }

        if systemProxyMode == .legacy {
            guard isRunning else {
                appendLog("[界面] 传统模式需要先在「仪表板」启动本地代理，再开启系统代理\n")
                return
            }
            if SystemProxyManager.enableSystemProxy(port: localSettings.localPort) {
                activeSystemProxyMode = .legacy
                systemProxyIsOn = true
            } else {
                appendLog("[界面] 设置系统代理失败\n")
            }
            return
        }

        // tun 模式：跟仪表板的本地代理是两条独立的连接，不需要仪表板那边也在跑。
        guard let profile = activeProfile else {
            appendLog("[tun] 还没有任何节点，请先去「代理配置」新增一个\n")
            return
        }
        if let err = profile.config.validationError() {
            appendLog("[tun] 无法启动：当前节点「\(profile.name)」配置不完整：\(err)\n")
            return
        }
        if let err = tunSettings.validationError() {
            appendLog("[tun] 无法启动：tun 网卡设置有问题：\(err)\n")
            return
        }

        // 先乐观地把开关状态改成"开"，真实结果由 TunRunner 在后台跑完提权脚本后
        // 通过 onStatusChange 回调过来（可能是几秒后，也可能失败后被改回"关"）。
        activeSystemProxyMode = .tun
        systemProxyIsOn = true
        tunRunner.start(config: profile.config, tun: tunSettings)
    }

    private func stopActiveSystemProxy() {
        switch activeSystemProxyMode {
        case .tun:
            tunRunner.stop()
        case .legacy:
            SystemProxyManager.disableSystemProxy()
        case nil:
            break
        }
        activeSystemProxyMode = nil
        systemProxyIsOn = false
    }

    func updateTunSettings(_ settings: TunSettings) {
        let wasOn = systemProxyIsOn && activeSystemProxyMode == .tun
        tunSettings = settings
        TunSettingsStore.save(settings)
        if wasOn {
            // 网卡名/地址这类参数变了必须重建网卡才能生效，这里直接重启一次。
            tunRunner.stop()
            activeSystemProxyMode = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.toggleSystemProxy()
            }
        }
    }

    private func appendLog(_ text: String) {
        logLines.append(text)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }

    func clearLogs() {
        logLines.removeAll()
    }
}
