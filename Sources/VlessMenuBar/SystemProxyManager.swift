import Foundation

/// 封装 macOS 自带的 `networksetup` 命令行工具，
/// 用来一键把"系统代理"指向本地跑着的 vless-ws-client 监听端口。
///
/// 注意：networksetup 改的是"网络服务"（比如 Wi-Fi、以太网）级别的代理设置，
/// 不需要 sudo（只要是当前登录用户改自己的网络偏好设置），
/// 但如果你的 Mac 上有多个网络服务同时激活（比如 Wi-Fi + 有线网都连着），
/// 这里会把所有"当前正连着网"的服务都设置一遍，保证不会漏掉。
enum SystemProxyManager {

    struct NetworkService {
        let name: String
    }

    /// 列出所有已启用（没被禁用）的网络服务名称，比如 ["Wi-Fi", "以太网"]。
    /// `networksetup -listallnetworkservices` 第一行是提示文字，要跳过；
    /// 前面带 `*` 的表示该服务被禁用，也要跳过。
    static func listActiveServices() -> [NetworkService] {
        let output = runNetworksetup(["-listallnetworkservices"]) ?? ""
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count > 1 else { return [] }
        return lines.dropFirst()
            .filter { !$0.hasPrefix("*") }
            .map { NetworkService(name: $0.trimmingCharacters(in: .whitespaces)) }
    }

    /// 把所有网络服务的 SOCKS5 + HTTP + HTTPS 代理都指向 127.0.0.1:port 并开启。
    /// 返回 true 表示至少成功设置了一个服务；如果一个网络服务都没找到，返回 false。
    @discardableResult
    static func enableSystemProxy(port: String, host: String = "127.0.0.1") -> Bool {
        let services = listActiveServices()
        guard !services.isEmpty else { return false }

        for service in services {
            _ = runNetworksetup(["-setsocksfirewallproxy", service.name, host, port])
            _ = runNetworksetup(["-setsocksfirewallproxystate", service.name, "on"])
            _ = runNetworksetup(["-setwebproxy", service.name, host, port])
            _ = runNetworksetup(["-setwebproxystate", service.name, "on"])
            _ = runNetworksetup(["-setsecurewebproxy", service.name, host, port])
            _ = runNetworksetup(["-setsecurewebproxystate", service.name, "on"])
        }
        return true
    }

    /// 关闭所有网络服务上的系统代理（不清空已填的地址/端口，只是关掉开关，
    /// 这样下次重新开启还是原来配置，行为上更像"临时关闭"而不是"清除设置"）。
    static func disableSystemProxy() {
        for service in listActiveServices() {
            _ = runNetworksetup(["-setsocksfirewallproxystate", service.name, "off"])
            _ = runNetworksetup(["-setwebproxystate", service.name, "off"])
            _ = runNetworksetup(["-setsecurewebproxystate", service.name, "off"])
        }
    }

    @discardableResult
    private static func runNetworksetup(_ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe() // 丢弃 stderr，避免个别服务报错刷屏

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
