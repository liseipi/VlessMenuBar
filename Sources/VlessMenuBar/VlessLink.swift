import Foundation

enum VlessLink {

    private static let unreservedCharacters: CharacterSet = {
        var set = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? s
    }

    private static func percentDecode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    static func build(from profile: ProxyProfile) -> String {
        let c = profile.config
        var query: [(String, String)] = [
            ("encryption", "none"),
            ("security", c.useTLS ? "tls" : "none"),
            ("type", "ws"),
            ("host", c.wsHost.isEmpty ? c.host : c.wsHost),
            ("path", c.path),
        ]
        if c.useTLS {
            query.append(("sni", c.sni.isEmpty ? c.host : c.sni))
        }
        if !c.token.isEmpty {
            query.append(("token", c.token))
        }

        let queryString = query.map { "\($0.0)=\(percentEncode($0.1))" }.joined(separator: "&")
        let remark = percentEncode(profile.name)
        return "vless://\(c.uuid)@\(c.host):\(c.port)?\(queryString)#\(remark)"
    }

    static func parse(_ link: String) -> ProxyProfile? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("vless://") else { return nil }
        let rest = String(trimmed.dropFirst("vless://".count))

        var main = rest
        var name = ""
        if let hashIdx = rest.firstIndex(of: "#") {
            main = String(rest[..<hashIdx])
            name = percentDecode(String(rest[rest.index(after: hashIdx)...]))
        }

        guard let atIdx = main.firstIndex(of: "@") else { return nil }
        let uuid = String(main[..<atIdx])
        let afterAt = String(main[main.index(after: atIdx)...])
        guard !uuid.isEmpty else { return nil }

        var hostPort = afterAt
        var queryPart = ""
        if let qIdx = afterAt.firstIndex(of: "?") {
            hostPort = String(afterAt[..<qIdx])
            queryPart = String(afterAt[afterAt.index(after: qIdx)...])
        }

        guard let colonIdx = hostPort.lastIndex(of: ":") else { return nil }
        let host = String(hostPort[..<colonIdx])
        let port = String(hostPort[hostPort.index(after: colonIdx)...])
        guard !host.isEmpty, !port.isEmpty else { return nil }

        var params: [String: String] = [:]
        if !queryPart.isEmpty {
            for pair in queryPart.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                params[String(kv[0])] = percentDecode(String(kv[1]))
            }
        }

        var config = ProxyConfig()
        config.host = host
        config.port = port
        config.uuid = uuid
        config.path = params["path"] ?? "/"
        config.useTLS = (params["security"] ?? "tls") == "tls"
        config.sni = params["sni"] ?? ""
        config.wsHost = params["host"] ?? ""
        config.token = params["token"] ?? ""

        return ProxyProfile(name: name.isEmpty ? host : name, config: config)
    }
}
