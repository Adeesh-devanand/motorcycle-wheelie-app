import XCTest
@testable import MotoTelemetryCore

/// Every public core type must have a non-test caller.
///
/// This project's signature failure mode is not bugs — it is correct, tested code
/// that nothing connects to. Eight complete subsystems shipped orphaned (a smoother
/// the docs called a live peer, a session writer, four unused views), and this very
/// cleanup left a `cueEngine = nil` teardown pointing at a property that had been
/// deleted — a would-be compile break that two rounds of by-hand review found only
/// by luck. This test replaces the luck: a public core type with no reference
/// outside the test target is either dead weight to delete or a seam that was never
/// wired, and either way you want to know before it rots.
///
/// Like `PurityTests`, this is a source-level grep, not a link check: it must fail
/// in review on Linux CI, where the iOS app target does not build and a linker
/// cannot see the app→core edges at all.
final class ReachabilityTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MotoTelemetryCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    /// Public top-level type declarations in the core, mapped to their file.
    private func coreDeclarations() throws -> [(name: String, file: String)] {
        let coreDir = repoRoot.appendingPathComponent("Sources/MotoTelemetryCore")
        let files = try FileManager.default
            .contentsOfDirectory(at: coreDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        // Matches `public struct X`, `public enum X`, `public final class X`,
        // `public class X`, `public actor X`, `public protocol X`.
        let pattern = #"^public\s+(?:final\s+)?(?:struct|enum|class|actor|protocol)\s+(\w+)"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])

        var decls: [(String, String)] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                if let r = Range(match.range(at: 1), in: text) {
                    decls.append((String(text[r]), file.lastPathComponent))
                }
            }
        }
        return decls
    }

    /// All non-test Swift source across every target: core, app, and CLI. A core
    /// type is reachable if ANY of these references it — app→core and cli→core edges
    /// count, which is exactly what a Linux linker cannot see.
    private func nonTestSourceText() throws -> String {
        let fm = FileManager.default
        var combined = ""
        for target in ["Sources/MotoTelemetryCore",
                       "Sources/MotoTelemetryApp",
                       "Sources/motolog"] {
            let dir = repoRoot.appendingPathComponent(target)
            guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                combined += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                combined += "\n"
            }
        }
        return combined
    }

    /// Types that are legitimately referenced by NAME nowhere outside tests, with the
    /// reason each is exempt. Keeping the exemptions explicit is the point: adding one
    /// is a decision a reviewer sees, not a silent pass.
    private let exemptions: [String: String] = [
        // Wire-format cases: present in logged fixtures and old rides, so `Sample`
        // must be able to decode them even though this build's estimator ignores both.
        "BaroSample": "log wire format — fixtures/old rides decode it",
        "WheelSpeedSample": "log wire format — reserved channel, decoded not consumed",
        // Referenced only within its own file by RelativeMetricColorScale, which the
        // app DOES use — the grep sees the colour-scale type, not this helper.
        "LinearRGB": "used within RelativeMetricColorScale.swift, which the app uses",
        // Used within Calibration.swift by BiasEstimator's .failed progress case.
        "CalibrationFailure": "used within Calibration.swift by BiasEstimator",
        // Marker protocols / associated types conformed to structurally rather than
        // named at a call site.
        "MeasurementSource": "protocol conformed to by sources, not named at call sites",
        "Stage": "protocol conformed to structurally",
    ]

    func testEveryPublicCoreTypeHasANonTestCaller() throws {
        let decls = try coreDeclarations()
        XCTAssertGreaterThan(decls.count, 10, "did not find the core declarations")

        let haystack = try nonTestSourceText()

        var orphans: [String] = []
        for (name, file) in decls {
            if exemptions[name] != nil { continue }
            // A reference is the name as a whole word, appearing somewhere OTHER than
            // its own declaration. The declaration itself is one occurrence; a real
            // caller pushes the count to two or more.
            let wordPattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#
            let regex = try NSRegularExpression(pattern: wordPattern)
            let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
            let count = regex.numberOfMatches(in: haystack, range: range)
            if count < 2 {
                orphans.append("\(name) (declared in \(file)) — no non-test caller")
            }
        }

        XCTAssertTrue(orphans.isEmpty,
            "Orphaned public core types — delete them or wire them, or add an "
            + "explicit exemption with a reason:\n" + orphans.joined(separator: "\n"))
    }

    /// The exemption list must not rot: an entry for a type that no longer exists is
    /// a stale excuse that would silently cover a future orphan of the same name.
    func testExemptionsReferenceRealTypes() throws {
        let declared = Set(try coreDeclarations().map(\.name))
        let stale = exemptions.keys.filter { !declared.contains($0) }
        XCTAssertTrue(stale.isEmpty,
            "Exemptions naming types that no longer exist: \(stale.sorted())")
    }
}
