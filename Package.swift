// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VlessMenuBar",
    platforms: [
        .macOS(.v12) // 实际最低支持 macOS 12 (Monterey)：SMAppService 在低于 13
                     // 的系统上不可用，LoginItemManager.swift 里已经做了版本判断
                     // 和 LaunchAgent 兜底方案；@FocusState / .textSelection 这些
                     // 用到的 API 需要 macOS 12，这是往下能降到的实际极限，
                     // 再往下（比如 11 或 10.15）就要连这几个功能一起阉割了。
    ],
    targets: [
        .executableTarget(
            name: "VlessMenuBar",
            resources: [
                // 把两个 Go 客户端可执行文件当作资源打进 App 里，
                // 运行时根据 CPU 架构挑选对应的那个来启动。
                .copy("Resources/vless-ws-client-darwin-amd64"),
                .copy("Resources/vless-ws-client-darwin-arm64"),
            ]
        )
    ]
)
