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

/// 整个 App 的中枢状态：节点列表、当前跑的是哪个节点、运行状态、
/// 本地代理全局设置、系统代理开关状态、日志。
/// 所有 SwiftUI 页面都通过 @EnvironmentObject 拿到同一份 AppStore。
final class AppStore: ObservableObject {
    @Published var profiles: [ProxyProfile] = []
    @Published var activeProfileID: UUID?
    @Published var selectedSection: SidebarSection? = .dashboard
    @Published var localSettings: LocalProxySettings = LocalProxyStore.load()

    @Published private(set) var proxyStatus: ProxyStatus = .stopped
    @Published private(set) var uptimeSeconds: Int = 0
    @Published var systemProxyIsOn = false
    @Published var logLines: [String] = []

    private let proxyProcess = ProxyProcess()
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
    }

    // MARK: - 节点管理

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
            // 正在用的这个节点被改了，重启一下让新配置生效。
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

    // MARK: - 本地代理设置（全局，跟具体节点无关）

    func updateLocalSettings(_ settings: LocalProxySettings) {
        let wasRunning = isRunning
        localSettings = settings
        LocalProxyStore.save(settings)
        if wasRunning {
            restart()
        }
    }

    // MARK: - 启停

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
            SystemProxyManager.disableSystemProxy()
            systemProxyIsOn = false
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

    // MARK: - 运行时长（纯本地计时，不依赖任何网络请求）

    private func startUptimeTimer() {
        stopUptimeTimer()
        startedAt = Date()
        uptimeSeconds = 0
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // 不直接在 Timer 的回调里改 @Published 属性——Timer 回调虽然本来就在
            // 主线程上跑，但它触发的时机有可能和 SwiftUI 当前正在进行的一次视图
            // 渲染撞在一起，直接改会报 "Publishing changes from within view
            // updates is not allowed"（未定义行为，长期可能导致界面状态错乱）。
            // 用 DispatchQueue.main.async 把实际赋值推迟到下一个 run loop 轮次，
            // 跟当前这次渲染事务彻底分开，就不会有这个问题了。
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

    // MARK: - 系统代理

    func toggleSystemProxy() {
        if systemProxyIsOn {
            SystemProxyManager.disableSystemProxy()
            systemProxyIsOn = false
        } else {
            guard isRunning else {
                appendLog("[界面] 请先启动代理，再设为系统代理\n")
                return
            }
            systemProxyIsOn = SystemProxyManager.enableSystemProxy(port: localSettings.localPort)
        }
    }

    // MARK: - 日志

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
