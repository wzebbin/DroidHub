// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DroidHub",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "DroidHub", targets: ["DroidHub"])],
    targets: [
        .target(name: "DroidHubCore", resources: [.process("Resources")]),
        .executableTarget(name: "DroidHub", dependencies: ["DroidHubCore"]),
        .testTarget(name: "DroidHubCoreTests", dependencies: ["DroidHubCore"]),
        .testTarget(name: "DroidHubTests", dependencies: ["DroidHub", "DroidHubCore"])
    ]
)
