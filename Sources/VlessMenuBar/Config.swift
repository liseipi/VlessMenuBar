import Foundation

struct ProxyProfile: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var config: ProxyConfig
}

enum ProfileStore {
    private static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("VlessMenuBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var profilesURL: URL { appSupportDir.appendingPathComponent("profiles.json") }
    private static var legacyConfigURL: URL { appSupportDir.appendingPathComponent("config.json") }

    struct StoredState: Codable {
        var profiles: [ProxyProfile]
        var activeID: UUID?
    }

    static func load() -> (profiles: [ProxyProfile], activeID: UUID?) {
        if let data = try? Data(contentsOf: profilesURL),
           let state = try? JSONDecoder().decode(StoredState.self, from: data),
           !state.profiles.isEmpty {
            return (state.profiles, state.activeID ?? state.profiles.first?.id)
        }

        if let data = try? Data(contentsOf: legacyConfigURL),
           let legacyConfig = try? JSONDecoder().decode(ProxyConfig.self, from: data) {
            let profile = ProxyProfile(name: legacyConfig.host.isEmpty ? "默认节点" : legacyConfig.host, config: legacyConfig)
            save(profiles: [profile], activeID: profile.id)
            return ([profile], profile.id)
        }

        return ([], nil)
    }

    static func save(profiles: [ProxyProfile], activeID: UUID?) {
        let state = StoredState(profiles: profiles, activeID: activeID)
        guard let data = try? JSONEncoder.pretty.encode(state) else { return }
        try? data.write(to: profilesURL, options: .atomic)
    }

    static func export(_ profile: ProxyProfile, to url: URL) throws {
        let data = try JSONEncoder.pretty.encode(profile)
        try data.write(to: url, options: .atomic)
    }

    static func importProfile(from url: URL) throws -> ProxyProfile {
        let data = try Data(contentsOf: url)
        if let profile = try? JSONDecoder().decode(ProxyProfile.self, from: data) {
            return profile
        }
        let config = try JSONDecoder().decode(ProxyConfig.self, from: data)
        return ProxyProfile(name: config.host.isEmpty ? "导入的节点" : config.host, config: config)
    }
}

struct ProxyConfig: Codable, Equatable {
    var host: String = ""
    var port: String = "443"
    var path: String = "/api"
    var useTLS: Bool = true

    var sni: String = ""
    var wsHost: String = ""

    var uuid: String = ""
    var token: String = ""

    var connectRetries: Int = 2
    var retryBaseMs: Int = 300
    var keepAliveSec: Int = 30
    var insecure: Bool = false
    var logLevel: String = "info"

    func validationError() -> String? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty {
            return "服务器地址不能为空"
        }
        if uuid.trimmingCharacters(in: .whitespaces).isEmpty {
            return "UUID 不能为空"
        }
        if Int(port) == nil {
            return "服务器端口必须是数字"
        }
        return nil
    }

    func commandLineArguments(local: LocalProxySettings) -> [String] {
        var args: [String] = [
            "-host", host,
            "-port", port,
            "-path", path,
            "-tls=\(useTLS ? "true" : "false")",
            "-uuid", uuid,
            "-local-ip", local.localIP,
            "-local-port", local.localPort,
            "-connect-retries", String(connectRetries),
            "-retry-base-ms", String(retryBaseMs),
            "-keepalive-sec", String(keepAliveSec),
            "-insecure=\(insecure ? "true" : "false")",
            "-log-level", logLevel,
        ]
        if !token.isEmpty {
            args.append(contentsOf: ["-token", token])
        }
        if !sni.isEmpty {
            args.append(contentsOf: ["-sni", sni])
        }
        if !wsHost.isEmpty {
            args.append(contentsOf: ["-ws-host", wsHost])
        }
        return args
    }

    /// tun 模式不需要 -local-ip/-local-port，换成 -tun 系列参数。
    func tunCommandLineArguments(tun: TunSettings) -> [String] {
        var args: [String] = [
            "-host", host,
            "-port", port,
            "-path", path,
            "-tls=\(useTLS ? "true" : "false")",
            "-uuid", uuid,
            "-connect-retries", String(connectRetries),
            "-retry-base-ms", String(retryBaseMs),
            "-keepalive-sec", String(keepAliveSec),
            "-insecure=\(insecure ? "true" : "false")",
            "-log-level", logLevel,
            "-tun",
            "-tun-name", tun.adapterName,
            "-tun-mtu", String(tun.mtu),
            "-tun-addr4", tun.address4,
        ]
        if !token.isEmpty {
            args.append(contentsOf: ["-token", token])
        }
        if !sni.isEmpty {
            args.append(contentsOf: ["-sni", sni])
        }
        if !wsHost.isEmpty {
            args.append(contentsOf: ["-ws-host", wsHost])
        }
        if !tun.address6.isEmpty {
            args.append(contentsOf: ["-tun-addr6", tun.address6])
        }
        return args
    }
}

struct LocalProxySettings: Codable, Equatable {
    var localIP: String = "127.0.0.1"
    var localPort: String = "1080"

    var lanEnabled: Bool {
        get { localIP == "0.0.0.0" }
        set { localIP = newValue ? "0.0.0.0" : "127.0.0.1" }
    }

    func validationError() -> String? {
        if Int(localPort) == nil {
            return "本地端口必须是数字"
        }
        return nil
    }
}

enum LocalProxyStore {
    private static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("VlessMenuBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var fileURL: URL { appSupportDir.appendingPathComponent("local-proxy.json") }

    static func load() -> LocalProxySettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(LocalProxySettings.self, from: data) else {
            return LocalProxySettings()
        }
        return settings
    }

    static func save(_ settings: LocalProxySettings) {
        guard let data = try? JSONEncoder.pretty.encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// TUN（系统级透明代理）虚拟网卡设置。取代旧版基于 networksetup 的"系统代理"实现——
/// 开启后不再是把 macOS 的 SOCKS5/HTTP/HTTPS 系统代理指向本地端口，而是创建一张
/// utun 虚拟网卡并把默认路由接管过来，效果上等价于"全局代理"，不依赖目标 App
/// 主动读取系统代理设置。
struct TunSettings: Codable, Equatable {
    /// macOS 下 utun 网卡名是系统按顺序自动分配的（utun0/utun1/...），创建时不能
    /// 指定成任意名字，这里保存的是"给 wireguard-go 传的建议名"，实际生效的名字
    /// 以创建后系统实际分配的为准（TunRunner 里会重新探测）。
    var adapterName: String = "utun"
    var mtu: Int = 1500
    var address4: String = "198.18.0.1"
    var address6: String = ""

    func validationError() -> String? {
        if mtu < 576 || mtu > 9000 {
            return "MTU 建议填 576-9000 之间"
        }
        if address4.trimmingCharacters(in: .whitespaces).isEmpty {
            return "网卡 IPv4 地址不能为空"
        }
        return nil
    }
}

enum TunSettingsStore {
    private static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("VlessMenuBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var fileURL: URL { appSupportDir.appendingPathComponent("tun.json") }

    static func load() -> TunSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(TunSettings.self, from: data) else {
            return TunSettings()
        }
        return settings
    }

    static func save(_ settings: TunSettings) {
        guard let data = try? JSONEncoder.pretty.encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// "系统代理"开关背后到底用哪种实现——两种方式都保留，用户自己选：
///   legacy：老办法，调用 `networksetup` 写系统代理设置，只对"读取系统代理
///           设置"的应用生效，需要先启动本地代理（仪表板）；
///   tun：新办法，创建虚拟网卡接管系统路由，覆盖面更广，不依赖应用支持读取
///        系统代理设置，但每次开关都要弹一次管理员密码框。
enum SystemProxyMode: String, Codable {
    case legacy
    case tun
}

enum SystemProxyModeStore {
    private struct Wrapper: Codable { var mode: SystemProxyMode }

    private static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("VlessMenuBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var fileURL: URL { appSupportDir.appendingPathComponent("system-proxy-mode.json") }

    static func load() -> SystemProxyMode {
        guard let data = try? Data(contentsOf: fileURL),
              let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else {
            return .tun
        }
        return wrapper.mode
    }

    static func save(_ mode: SystemProxyMode) {
        guard let data = try? JSONEncoder.pretty.encode(Wrapper(mode: mode)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }
}
