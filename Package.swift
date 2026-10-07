// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OnigiriHarness",
    defaultLocalization: "ja",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OnigiriCore", targets: ["OnigiriCore"]),
        .executable(name: "OnigiriServer", targets: ["OnigiriServer"]),
        .executable(name: "OnigiriApp", targets: ["OnigiriApp"]),
        .executable(name: "onigiri-eval", targets: ["OnigiriEvalCLI"]),
        .executable(name: "onigiri-mcp", targets: ["OnigiriMCP"])
    ],
    targets: [
        .target(name: "OnigiriCore"),
        .executableTarget(name: "OnigiriServer", dependencies: ["OnigiriCore"]),
        .executableTarget(
            name: "OnigiriApp", dependencies: ["OnigiriCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "OnigiriEvalCLI", dependencies: ["OnigiriCore"]),
        .executableTarget(name: "OnigiriMCP", dependencies: ["OnigiriCore"]),
        .testTarget(name: "OnigiriCoreTests", dependencies: ["OnigiriCore"])
    ],
    swiftLanguageModes: [.v5]
)
