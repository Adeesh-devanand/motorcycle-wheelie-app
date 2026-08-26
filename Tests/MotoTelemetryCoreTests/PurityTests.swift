import XCTest
@testable import MotoTelemetryCore

/// R1.1, R1.2 — the architectural law of this package, enforced mechanically.
///
/// `MotoTelemetryCore` has zero platform dependencies. That is what lets the
/// identical pipeline run live on the bike, replayed from a file on a Mac, and in
/// a unit test with no device in the room. Break it and every tuning change to
/// the gate or the filter costs a ride, in traffic, on a bike you are trying to
/// wheelie.
///
/// This is a source-level grep rather than a link-level check because it must
/// fail in review, on Linux CI, without an iOS SDK present.
final class PurityTests: XCTestCase {

    /// Frameworks that would break replay, testability, or both.
    /// Accelerate is included deliberately: it is legal in the `motolog` target
    /// (FFT and Allan analysis) but never in the core, whose numerics must run
    /// anywhere.
    private let banned = [
        "CoreMotion", "CoreLocation", "UIKit", "SwiftUI", "AppKit",
        "AVFoundation", "Accelerate", "CoreGraphics", "Combine",
    ]

    private var coreSourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MotoTelemetryCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/MotoTelemetryCore")
    }

    private func coreSourceFiles() throws -> [URL] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: coreSourceDirectory,
                                                 includingPropertiesForKeys: nil)
        return contents.filter { $0.pathExtension == "swift" }
    }

    func testCoreImportsNoPlatformFramework() throws {
        let files = try coreSourceFiles()
        XCTAssertGreaterThan(files.count, 5, "did not find the core sources")

        var violations: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n",
                                             omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let module = trimmed
                    .dropFirst("import ".count)
                    .trimmingCharacters(in: .whitespaces)
                if banned.contains(module) {
                    violations.append(
                        "\(file.lastPathComponent):\(number + 1): import \(module)")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty,
            "MotoTelemetryCore must have zero platform dependencies. Found:\n"
            + violations.joined(separator: "\n"))
    }

    func testCoreImportsOnlyFoundation() throws {
        // Stronger statement: the only import the core needs at all is Foundation.
        // Anything else is worth a deliberate decision, so it fails here first.
        var unexpected: [String] = []
        for file in try coreSourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let module = String(trimmed.dropFirst("import ".count))
                    .trimmingCharacters(in: .whitespaces)
                if module != "Foundation" {
                    unexpected.append("\(file.lastPathComponent): import \(module)")
                }
            }
        }
        XCTAssertTrue(unexpected.isEmpty,
                      "unexpected imports in the core:\n"
                      + unexpected.joined(separator: "\n"))
    }

    func testPackageDeclaresNoThirdPartyDependencies() throws {
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        XCTAssertFalse(text.contains(".package("),
                       "no third-party dependencies are permitted (R1.2)")
    }
}
