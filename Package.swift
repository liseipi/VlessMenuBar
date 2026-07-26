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
                .copy("Resources/vless-ws-client-darwin-amd64"),
                .copy("Resources/vless-ws-client-darwin-arm64"),
            ]
        )
    ]
)
