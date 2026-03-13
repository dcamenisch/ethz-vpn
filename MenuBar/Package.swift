// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ETHZVPNMenuBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ETHZVPNMenuBar",
            path: "Sources/ETHZVPNMenuBar",
            resources: [.copy("Resources")]
        )
    ]
)
