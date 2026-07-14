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
    dependencies: [
        // Auto-update. Linked into the app target only — Core/UI stay dependency-free.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
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
            dependencies: ["AIUsageBarUI", "AIUsageBarCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .executableTarget(
            name: "previewgen",
            dependencies: ["AIUsageBarUI", "AIUsageBarCore"]
        ),
        .executableTarget(
            name: "icongen"
        ),
        .executableTarget(
            name: "dmgbggen"
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
            dependencies: ["AIUsageBar", "AIUsageBarUI", "AIUsageBarCore"],
            // This bundle transitively links Sparkle (via the app target). SPM leaves
            // Sparkle.framework in the products dir, three levels above the xctest
            // binary — add that as an rpath so @rpath/Sparkle.framework resolves.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])]
        ),
    ]
)
