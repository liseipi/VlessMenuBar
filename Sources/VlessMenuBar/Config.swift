import Foundation

/// 一个"节点"：ProxyConfig 加一个显示名称和唯一 ID，
/// 对应截图里"代理配置"列表里的每一行、以及仪表板"当前节点"卡片里显示的那份。
struct ProxyProfile: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var config: ProxyConfig
}

/// 管理"多个已保存节点 + 当前选中的是哪一个"，替代早期版本里单一 ProxyConfig 的存法。
/// 兼容旧版本：如果只找到旧的单份 config.json，会自动升级成一个叫"默认节点"的 profile。
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

    /// 加载全部节点 + 当前激活的是哪个。
    static func load() -> (profiles: [ProxyProfile], activeID: UUID?) {
        if let data = try? Data(contentsOf: profilesURL),
           let state = try? JSONDecoder().decode(StoredState.self, from: data),
           !state.profiles.isEmpty {
            return (state.profiles, state.activeID ?? state.profiles.first?.id)
        }

        // 兼容旧版本只有单份 config.json 的情况，自动升级成一个 profile。
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

    /// 导出单个节点到用户指定位置。
    static func export(_ profile: ProxyProfile, to url: URL) throws {
        let data = try JSONEncoder.pretty.encode(profile)
        try data.write(to: url, options: .atomic)
    }

    /// 导入一个节点文件；也兼容直接导入一份裸 ProxyConfig（没有 name 包装）的情况。
    static func importProfile(from url: URL) throws -> ProxyProfile {
        let data = try Data(contentsOf: url)
        if let profile = try? JSONDecoder().decode(ProxyProfile.self, from: data) {
            return profile
        }
        let config = try JSONDecoder().decode(ProxyConfig.self, from: data)
        return ProxyProfile(name: config.host.isEmpty ? "导入的节点" : config.host, config: config)
    }
}

/// 与 vless-ws-client 的命令行参数一一对应。
/// 之所以用 Codable 而不是直接存 UserDefaults 里一堆零散的 key，
/// 是为了让"导出配置"直接等于把这个 struct 序列化成 JSON 文件，
/// "导入配置"就是反序列化回来，逻辑简单、不容易漏字段。
struct ProxyConfig: Codable, Equatable {
    var host: String = ""
    var port: String = "443"
    var path: String = "/api"
    var useTLS: Bool = true

    var sni: String = ""       // 留空 = 跟 host 一样
    var wsHost: String = ""    // 留空 = 跟 host 一样

    var uuid: String = ""
    var token: String = ""

    var connectRetries: Int = 2
    var retryBaseMs: Int = 300
    var keepAliveSec: Int = 30
    var insecure: Bool = false
    var logLevel: String = "info"

    /// 校验必填项，返回缺失的字段名（用于界面上给出提示），全部合格返回 nil。
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

    /// 拼成传给 vless-ws-client 的命令行参数数组。
    /// local 是全局的"本地代理"设置（本地 IP/端口），跟具体连的是哪个远程节点无关，
    /// 所以作为参数传进来，而不是存在 ProxyConfig 自己身上。
    ///
    /// 注意：布尔类型的参数（-tls / -insecure）必须写成 "-tls=true" 这种
    /// 单个 token 的形式，不能写成 "-tls", "true" 两个分开的元素——
    /// Go 的 flag 包对 bool 类型参数的规则是"出现即为 true"，不会去消费
    /// 紧跟在后面的下一个 token 当作自己的值；如果紧跟着一个不以 "-" 开头的
    /// 字符串（比如字面的 "true"），flag 包会直接整体停止解析，后面所有参数
    /// （包括 -uuid 及其值）都会被当成无意义的剩余参数扔掉，导致 UUID 等字段
    /// 全部变回默认值——这正是之前"明明填了配置还是报缺 host/uuid"的真正原因。
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
}

/// 全局的"本地代理"设置：本地监听 IP / 端口，跟连的是哪个远程节点无关，
/// 整个 App 只有一份，不像 ProxyConfig 那样每个节点各存一份。
struct LocalProxySettings: Codable, Equatable {
    var localIP: String = "127.0.0.1"
    var localPort: String = "1080"

    /// 是否允许局域网内其他设备连接（对应 localIP 是否为 0.0.0.0）。
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

/// 本地代理设置的持久化，跟 ProfileStore（节点列表）分开存一个文件，
/// 因为这是全局设置，不属于任何一个节点。
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

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }
}
