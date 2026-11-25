// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "claude-notch",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClaudeNotchCore"),
        .testTarget(name: "ClaudeNotchCoreTests", dependencies: ["ClaudeNotchCore"]),
    ]
)
