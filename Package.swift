// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MotoTelemetry",
    platforms: [.macOS(.v13), .iOS(.v16)],
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
