import XCTest
@testable import MotoTelemetryCore

/// R1.5 — the `Measurement` -> `Sample` rename is source-level only and must
/// never change the log format. Swift's synthesized `Codable` for an enum with
/// associated values keys on the CASE name, not the type name, so a log written
/// before the rename must still decode after it. This fixture was emitted by the
/// pre-rename code; if it ever fails to decode, the wire format has moved and
/// every log on every phone in the field just became unreadable.
final class WireFormatTests: XCTestCase {

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MotoTelemetryCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Fixtures/pre-rename-session.ndjson")
    }

    func testPreRenameLogStillDecodes() throws {
        let (header, samples) = try LogFile.read(contentsOf: fixtureURL)

        XCTAssertEqual(header.formatVersion, 1,
                       "log format version must not move with a source rename")
        XCTAssertEqual(header.sessionID, "pre-rename-fixture")
        XCTAssertEqual(header.config.version, 1,
                       "fixture must retain its ORIGINAL config version so the "
                       + "v1-header decode path stays covered after Config v2")
        XCTAssertGreaterThan(samples.count, 100)
    }

    func testEveryCaseInTheEnumRoundTripsThroughTheFixture() throws {
        let (_, samples) = try LogFile.read(contentsOf: fixtureURL)

        var sawIMU = false, sawGNSS = false, sawBaro = false, sawWheel = false
        var sawSaturated = false, sawFusedAttitude = false
        for s in samples {
            switch s {
            case .imu(let i):
                sawIMU = true
                if i.saturated { sawSaturated = true }
                if i.fusedAttitude != nil { sawFusedAttitude = true }
            case .gnss:       sawGNSS = true
            case .baro:       sawBaro = true
            case .wheelSpeed: sawWheel = true
            }
        }
        XCTAssertTrue(sawIMU);  XCTAssertTrue(sawGNSS)
        XCTAssertTrue(sawBaro); XCTAssertTrue(sawWheel)
        XCTAssertTrue(sawSaturated, "fixture must cover the saturated flag")
        XCTAssertTrue(sawFusedAttitude, "fixture must cover the optional attitude")
    }

    func testCaseNamesAreTheWireKeys() throws {
        // Pins the actual JSON shape, so a future refactor that adds a custom
        // CodingKeys or a discriminator field fails loudly here rather than
        // silently orphaning every recorded session.
        let encoded = try LogFile.encode(.imu(IMUSample(
            time: 0.5,
            rotationRate: Vector3(1, 2, 3),
            specificForce: Vector3(4, 5, 6))))
        let text = String(data: encoded, encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix("{\"imu\":{\"_0\":{"),
                      "unexpected wire shape: \(text)")

        let gnss = try LogFile.encode(.gnss(GNSSFix(
            fixTime: 1.0, arrivalTime: 1.25, speed: 12.5, speedAccuracy: 0.3)))
        XCTAssertTrue(String(data: gnss, encoding: .utf8)!
            .hasPrefix("{\"gnss\":{\"_0\":{"))
    }

    func testReplaySourceOrdersOnSampleTime() throws {
        let (_, samples) = try LogFile.read(contentsOf: fixtureURL)
        var source = ReplaySource(samples: samples.reversed())
        var last = -Double.infinity
        var count = 0
        while let s = source.next() {
            XCTAssertGreaterThanOrEqual(s.time, last)
            last = s.time
            count += 1
        }
        XCTAssertEqual(count, samples.count)
    }
}
