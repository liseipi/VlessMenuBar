// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VlessMenuBar",
    platforms: [
        .macOS(.v12)
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
