// Reproduction for the "27 corrupt run files" diagnosis, and a standing check on the
// compatibility rule in `WheelieRun.init(from:)`.
//
//     xcrun swiftc -o /tmp/run_schema_check .kiro/tools/check_run_schema_compat.swift
//     /tmp/run_schema_check
//
// This lives here rather than in the test suite because there is NO test target for
// MotoTelemetryApp — `Tests/` covers MotoTelemetryCore only, and `WheelieRun` is an
// app-layer type. That is a real gap: it is why one additive field silently orphaned 27
// runs for three sessions with nothing failing. Until an app test target exists, this
// script is the reproduction.
//
// It mirrors the real types rather than importing them (the app module is not built as a
// library), so if `WheelieRun` gains another stored field this file must be updated
// alongside it — the same discipline the pbxproj file list already demands.
import Foundation

// MARK: - Mirrors of the real stored schema

struct Flags: OptionSet, Codable { let rawValue: Int }
let qualityRecordMissing = Flags(rawValue: 1 << 9)
let smoothingUnavailable = Flags(rawValue: 1 << 6)

struct Sample: Codable {
    let id: UUID
    let elapsed: TimeInterval
    let angleDegrees: Double
    var blurredAngleDegrees: Double?
    let speedKPH: Double
}

struct Range: Codable { let lower: Double; let upper: Double }

struct Snapshot: Codable {
    let angleTarget: Range
    let speedTarget: Range
    let speedGaugeMaximum: Double
    let calibrationID: UUID
}

/// The pre-beta file on disk: no `qualityFlags` key.
struct RunAsSavedBeforeTheBeta: Codable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let samples: [Sample]
    let configuration: Snapshot
}

/// What `WheelieRun` was: an additive field with a default and a SYNTHESIZED decoder.
struct RunWithSynthesizedDecoder: Codable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let samples: [Sample]
    let configuration: Snapshot
    var qualityFlags: Flags = []
}

/// What `WheelieRun` is now.
struct RunWithTolerantDecoder: Codable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let samples: [Sample]
    let configuration: Snapshot
    var qualityFlags: Flags = []

    enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, samples, configuration, qualityFlags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decode(Date.self, forKey: .endedAt)
        samples = try c.decode([Sample].self, forKey: .samples)
        configuration = try c.decode(Snapshot.self, forKey: .configuration)
        if let stored = try c.decodeIfPresent(Flags.self, forKey: .qualityFlags) {
            qualityFlags = stored
        } else {
            var derived = qualityRecordMissing
            if samples.allSatisfy({ $0.blurredAngleDegrees == nil }) {
                derived.formUnion(smoothingUnavailable)
            }
            qualityFlags = derived
        }
    }
}

// MARK: - Run

let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601

let old = RunAsSavedBeforeTheBeta(
    id: UUID(), startedAt: Date(), endedAt: Date().addingTimeInterval(7.9),
    samples: [Sample(id: UUID(), elapsed: 0, angleDegrees: 41.2,
                     blurredAngleDegrees: nil, speedKPH: 38)],
    configuration: Snapshot(angleTarget: Range(lower: 35, upper: 45),
                            speedTarget: Range(lower: 35, upper: 50),
                            speedGaugeMaximum: 100, calibrationID: UUID()))
let payload = try encoder.encode(old)

var failures = 0

do {
    _ = try decoder.decode(RunWithSynthesizedDecoder.self, from: payload)
    print("FAIL  synthesized decoder accepted the old file — diagnosis was wrong")
    failures += 1
} catch let error as DecodingError {
    if case .keyNotFound(let key, _) = error, key.stringValue == "qualityFlags" {
        print("ok    synthesized decoder throws keyNotFound('qualityFlags') — the cause")
    } else {
        print("FAIL  threw, but not the expected keyNotFound:", error)
        failures += 1
    }
}

do {
    let run = try decoder.decode(RunWithTolerantDecoder.self, from: payload)
    let expected = qualityRecordMissing.union(smoothingUnavailable)
    if run.qualityFlags == expected {
        print("ok    tolerant decoder loads it, flags = qualityRecordMissing|smoothingUnavailable")
    } else {
        print("FAIL  tolerant decoder loaded it with flags \(run.qualityFlags.rawValue), expected \(expected.rawValue)")
        failures += 1
    }
} catch {
    print("FAIL  tolerant decoder rejected the old file:", error)
    failures += 1
}

// A file genuinely missing a load-bearing field must still be refused — the shim
// tolerates the additive key only.
var truncated = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
truncated.removeValue(forKey: "configuration")
do {
    _ = try decoder.decode(RunWithTolerantDecoder.self,
                           from: try JSONSerialization.data(withJSONObject: truncated))
    print("FAIL  tolerant decoder accepted a file with no configuration")
    failures += 1
} catch {
    print("ok    tolerant decoder still refuses a file missing 'configuration'")
}

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
