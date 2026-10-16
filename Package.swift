// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MemBot",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "MemBotCore"),
        .testTarget(name: "MemBotCoreTests", dependencies: ["MemBotCore"]),
        .target(name: "MemBotSystem", dependencies: ["MemBotCore"]),
        .executableTarget(name: "MemBot", dependencies: ["MemBotCore", "MemBotSystem"]),
        .testTarget(name: "MemBotSystemTests", dependencies: ["MemBotSystem", "MemBotCore"]),
    ]
)
