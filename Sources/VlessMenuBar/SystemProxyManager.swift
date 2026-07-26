import Foundation

enum SystemProxyManager {

    struct NetworkService {
        let name: String
    }

    static func listActiveServices() -> [NetworkService] {
        let output = runNetworksetup(["-listallnetworkservices"]) ?? ""
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count > 1 else { return [] }
        return lines.dropFirst()
            .filter { !$0.hasPrefix("*") }
            .map { NetworkService(name: $0.trimmingCharacters(in: .whitespaces)) }
    }

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
        proc.standardError = Pipe()

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
