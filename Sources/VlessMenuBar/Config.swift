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

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }
}
