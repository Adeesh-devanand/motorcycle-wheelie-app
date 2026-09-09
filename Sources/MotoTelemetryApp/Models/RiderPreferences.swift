import Foundation
import Observation

/// The app is km/h-only. `mph` is retained ONLY so preferences persisted before the
/// unit picker was removed still decode (a `RawValue` that vanished would throw on
/// load). Nothing branches on it — speed is km/h everywhere — and the Settings picker
/// that once set it is gone, because it changed the label without converting the
/// value. Remove this enum entirely once no stored prefs can carry `"mph"`, or when a
/// real unit conversion is wired.
enum SpeedUnit: String, Codable, Sendable, Equatable {
    case kph
    case mph
}

@Observable
final class RiderPreferences {
    private static let storageKey = "RiderPreferences"

    /// Inclusive bounds for `speedGaugeMaximum`, km/h. The Settings field is a free
    /// text entry rather than a preset picker, so these are enforced here as well —
    /// a stored value from an older build, or a typo that got past the field, must
    /// not be able to produce a gauge with a zero or absurd span. 0 would make
    /// `fillFraction` divide by zero.
    static let gaugeMaximumRange: ClosedRange<Double> = 50...300

    var angleTarget: MetricRange {
        didSet { save() }
    }
    var speedTarget: MetricRange {
        didSet { save() }
    }
    /// Clamped into `gaugeMaximumRange` on every write, including the one in `init`.
    var speedGaugeMaximum: Double {
        didSet {
            let clamped = Self.clampGaugeMaximum(speedGaugeMaximum)
            if clamped != speedGaugeMaximum {
                speedGaugeMaximum = clamped     // re-enters didSet once, then settles
                return
            }
            // The target band is expressed in the same units as the gauge, so
            // shrinking the ceiling below the band would leave a target the rider
            // can never reach and a band drawn off the top of the meter.
            if speedTarget.upper > clamped {
                speedTarget = MetricRange(lower: min(speedTarget.lower, clamped - 1),
                                          upper: clamped)
            }
            save()
        }
    }
    /// Whether this rider has a speedometer at all.
    ///
    /// Off is not a display filter — it means speed is not part of the instrument:
    /// the Live speed meter and speed card are gone, GNSS is not consulted for a
    /// reading, and a recorded run stores 0 for every speed field rather than a
    /// number nobody was watching. Angle is unaffected; it comes from the gyro and
    /// never depended on speed.
    var speedEnabled: Bool {
        didSet { save() }
    }
    var speedUnit: SpeedUnit {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(StoredPreferences.self, from: data) {
            self.angleTarget = stored.angleTarget
            self.speedTarget = stored.speedTarget
            self.speedGaugeMaximum = Self.clampGaugeMaximum(stored.speedGaugeMaximum)
            // Absent from preferences written before the toggle existed. Default on,
            // so an existing rider's app behaves exactly as it did before.
            self.speedEnabled = stored.speedEnabled ?? true
            self.speedUnit = stored.speedUnit
            // Property observers do not fire during init, so the band/ceiling
            // reconciliation that `speedGaugeMaximum.didSet` performs has to be
            // repeated here for a stored pair that is already inconsistent (a
            // ceiling lowered by an older build, or hand-edited defaults).
            if self.speedTarget.upper > self.speedGaugeMaximum {
                self.speedTarget = MetricRange(
                    lower: min(self.speedTarget.lower, self.speedGaugeMaximum - 1),
                    upper: self.speedGaugeMaximum
                )
            }
        } else {
            self.angleTarget = MetricRange(lower: 35, upper: 45)
            self.speedTarget = MetricRange(lower: 35, upper: 50)
            self.speedGaugeMaximum = 100
            self.speedEnabled = true
            self.speedUnit = .kph
        }
    }

    static func clampGaugeMaximum(_ value: Double) -> Double {
        guard value.isFinite else { return 100 }
        return min(max(value.rounded(), gaugeMaximumRange.lowerBound),
                   gaugeMaximumRange.upperBound)
    }

    private func save() {
        let stored = StoredPreferences(
            angleTarget: angleTarget,
            speedTarget: speedTarget,
            speedGaugeMaximum: speedGaugeMaximum,
            speedEnabled: speedEnabled,
            speedUnit: speedUnit
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

private struct StoredPreferences: Codable {
    let angleTarget: MetricRange
    let speedTarget: MetricRange
    let speedGaugeMaximum: Double
    /// Optional so preferences persisted before the speed toggle still decode. A
    /// non-optional new key would make `JSONDecoder` throw on every existing
    /// install, silently resetting every target the rider had set.
    let speedEnabled: Bool?
    let speedUnit: SpeedUnit
}
