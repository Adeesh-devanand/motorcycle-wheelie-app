// swift-tools-version:6.0
import PackageDescription

// tools-version 6.0 rather than 5.9: `.iOS(.v18)` is unavailable in the 5.9
// PackageDescription, and the app targets iOS 18. The bump also opts the targets
// into Swift 6 language mode, so the strict-concurrency checking the pipeline
// design relies on is enforced at compile time rather than hoped for.
let package = Package(
    name: "MotoTelemetry",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        // Pure logic. No CoreMotion, no CoreLocation, no UI. This is what the
        // iOS app, the replay CLI, and the tests all share.
        .library(name: "MotoTelemetryCore", targets: ["MotoTelemetryCore"]),
        .executable(name: "motolog", targets: ["motolog"]),
    ],
    targets: [
        .target(name: "MotoTelemetryCore"),
        .executableTarget(name: "motolog", dependencies: ["MotoTelemetryCore"]),
        .testTarget(name: "MotoTelemetryCoreTests", dependencies: ["MotoTelemetryCore"]),
    ]
)
