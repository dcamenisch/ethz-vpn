// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ETHVPNMenuBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ETHVPNMenuBar",
            path: "Sources/ETHVPNMenuBar",
            resources: [.copy("Resources")]
        )
    ]
)
