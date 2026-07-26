import Foundation
import ServiceManagement

enum LoginItemManager {

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            return legacyPlistExists()
        }
    }

    static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status == .enabled {
                        return .success(())
                    }
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        } else {
            return setLegacyLoginItem(enabled)
        }
    }

    static var statusDescription: String {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .notRegistered: return "未启用"
            case .enabled: return "已启用"
            case .requiresApproval: return "需要在「系统设置 → 通用 → 登录项」里手动允许"
            case .notFound: return "未注册"
            @unknown default: return "未知状态"
            }
        } else {
            return legacyPlistExists() ? "已启用（LaunchAgent）" : "未启用"
        }
    }

    private static let legacyLabel = "com.vlessmenubar.loginitem"

    private static var legacyPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
    }

    private static func legacyPlistExists() -> Bool {
        FileManager.default.fileExists(atPath: legacyPlistURL.path)
    }

    private static func runLaunchctl(_ args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        try? task.run()
        task.waitUntilExit()
    }

    private static func setLegacyLoginItem(_ enabled: Bool) -> Result<Void, Error> {
        if enabled {
            guard let execPath = Bundle.main.executablePath else {
                return .failure(NSError(
                    domain: "LoginItemManager", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "找不到当前 App 的可执行文件路径"]
                ))
            }
            let plist: [String: Any] = [
                "Label": legacyLabel,
                "ProgramArguments": [execPath],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
            ]
            do {
                let data = try PropertyListSerialization.data(
                    fromPropertyList: plist, format: .xml, options: 0
                )
                try FileManager.default.createDirectory(
                    at: legacyPlistURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: legacyPlistURL, options: .atomic)
                runLaunchctl(["load", "-w", legacyPlistURL.path])
                return .success(())
            } catch {
                return .failure(error)
            }
        } else {
            runLaunchctl(["unload", "-w", legacyPlistURL.path])
            try? FileManager.default.removeItem(at: legacyPlistURL)
            return .success(())
        }
    }
}
