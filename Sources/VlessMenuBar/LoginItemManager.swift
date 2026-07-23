import Foundation
import ServiceManagement

/// 开机自启动。
///
/// macOS 13+ 用 `SMAppService.mainApp`，这是苹果目前推荐的方式，不需要单独
/// 安装 LaunchAgent 文件，跟"系统设置 -> 通用 -> 登录项"里的开关是同一套东西。
///
/// macOS 12 及更早的系统没有 `SMAppService`（这是 Ventura 才引入的 API），
/// 用一个手写的 LaunchAgent plist 兜底：往 `~/Library/LaunchAgents/` 写一份
/// 配置文件，登录时 launchd 会按这份配置自动拉起这个 App。效果上跟
/// SMAppService 类似，只是不会出现在"系统设置 -> 登录项"那个列表里
/// （旧系统本来也没有这个统一列表）。
///
/// 前提：这个可执行文件必须是从一个正经的 .app 包里跑起来的
/// （即 Bundle.main 是 .../VlessMenuBar.app/Contents/MacOS/VlessMenuBar 这种结构），
/// 直接用 `swift run` 跑源码或者裸执行 SwiftPM 编译出来的二进制是不行的——
/// 详见 README 里 build-app.sh 脚本，负责把编译产物打包成正经 .app。
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

    /// 人类可读的状态描述，方便在菜单里显示或者出错时提示用户去系统设置里看看。
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

    // MARK: - macOS 12 及更早系统的兜底实现（手写 LaunchAgent plist）

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
