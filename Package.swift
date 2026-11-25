// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "claude-notch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "claude-notch-hook", targets: ["claude-notch-hook"])
    ],
    targets: [
        .target(name: "ClaudeNotchCore"),
        .executableTarget(name: "claude-notch-hook", dependencies: ["ClaudeNotchCore"]),
        .testTarget(name: "ClaudeNotchCoreTests", dependencies: ["ClaudeNotchCore"]),
    ]
)
