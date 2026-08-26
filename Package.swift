// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MotoTelemetry",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "MotoTelemetryCore", targets: ["MotoTelemetryCore"]),
        .executable(name: "motolog", targets: ["motolog"]),
    ],
    targets: [
        .target(name: "MotoTelemetryCore"),
        .executableTarget(name: "motolog", dependencies: ["MotoTelemetryCore"]),
        .testTarget(name: "MotoTelemetryCoreTests", dependencies: ["MotoTelemetryCore"]),
    ]
)
