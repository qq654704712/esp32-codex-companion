// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexCompanion",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexCompanionCore", targets: ["CodexCompanionCore"]),
        .executable(name: "codex-companion", targets: ["CodexCompanionCLI"]),
        .executable(name: "CodexCompanion", targets: ["CodexCompanionApp"]),
        .executable(name: "companion-simulator", targets: ["CompanionSimulator"]),
    ],
    targets: [
        .target(
            name: "CodexCompanionCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "CodexCompanionCLI",
            dependencies: ["CodexCompanionCore"]
        ),
        .executableTarget(
            name: "CodexCompanionApp",
            dependencies: ["CodexCompanionCore"]
        ),
        .executableTarget(
            name: "CompanionSimulator",
            dependencies: ["CodexCompanionCore"]
        ),
        .testTarget(
            name: "CodexCompanionCoreTests",
            dependencies: ["CodexCompanionCore"]
        ),
    ]
)
