// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsageBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AIUsageBarCore", targets: ["AIUsageBarCore"]),
        .executable(name: "AIUsageBar", targets: ["AIUsageBar"]),
        .executable(name: "usageprobe", targets: ["usageprobe"]),
    ],
    targets: [
        .target(
            name: "AIUsageBarCore"
        ),
        .target(
            name: "AIUsageBarUI",
            dependencies: ["AIUsageBarCore"]
        ),
        .executableTarget(
            name: "AIUsageBar",
            dependencies: ["AIUsageBarUI", "AIUsageBarCore"]
        ),
        .executableTarget(
            name: "previewgen",
            dependencies: ["AIUsageBarUI", "AIUsageBarCore"]
        ),
        .executableTarget(
            name: "icongen"
        ),
        .executableTarget(
            name: "usageprobe",
            dependencies: ["AIUsageBarCore"]
        ),
        .testTarget(
            name: "AIUsageBarCoreTests",
            dependencies: ["AIUsageBarCore"]
        ),
        .testTarget(
            name: "AIUsageBarUITests",
            dependencies: ["AIUsageBarUI", "AIUsageBarCore"]
        ),
    ]
)
