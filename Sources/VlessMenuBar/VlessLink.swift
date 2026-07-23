import Foundation

/// vless:// 分享链接的生成与解析。
/// 格式沿用社区里 v2rayN / Xray 等工具通用的写法：
///   vless://{uuid}@{host}:{port}?encryption=none&security=tls&type=ws&host={wsHost}&path={path}&sni={sni}#{备注}
/// 额外加了一个非标准的 `token` 查询参数，用来带上我们自己协议里的鉴权 Token
/// （标准 VLESS 协议没有这个概念，其他工具会直接忽略这个参数，不影响兼容性）。
///
/// 编解码逻辑已经用等价算法在 Python 里跑过一遍往返测试（中文名称、emoji、
/// 路径/token 里带 &、=、# 等特殊字符都覆盖到了），这里是照着验证过的逻辑翻译过来的。
enum VlessLink {

    /// 只保留 RFC 3986 "unreserved" 字符不转义，其余全部按 UTF-8 字节百分号编码。
    /// 用最严格的字符集是为了保证任何字符（包括中文、emoji、&=?#这些查询字符串
    /// 里有特殊含义的符号）都能被安全地放进 URL 的某一段里，不会和分隔符混淆。
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

    /// 把一个节点生成分享链接。
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

    /// 解析一个 vless:// 链接，失败返回 nil（格式不对、缺 host/port/uuid 等）。
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
