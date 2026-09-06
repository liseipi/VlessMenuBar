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
        guard let profile = activeProfile else {
            proxyStatus = .failed("还没有任何节点，请先去「代理配置」新增一个")
            return
        }
        if let err = localSettings.validationError() {
            proxyStatus = .failed("本地代理设置有问题：\(err)")
            return
        }
        if let err = profile.config.validationError() {
            proxyStatus = .failed("当前节点「\(profile.name)」配置不完整：\(err)")
            appendLog("[界面] 无法启动：\(err)\n")
            return
        }
        proxyProcess.start(config: profile.config, local: localSettings)
        startUptimeTimer()
    }

    func stop() {
        proxyProcess.stop()
        stopUptimeTimer()
        if systemProxyIsOn {
            stopActiveSystemProxy()
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
