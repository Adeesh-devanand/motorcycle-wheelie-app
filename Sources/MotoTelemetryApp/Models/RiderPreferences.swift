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

    /// The gauge ceilings a rider may choose, km/h.
    ///
    /// Derived from `MeterScale`, not hardcoded, and that derivation is load-bearing. The
    /// live meter divides its scale into `MeterScale.divisions` (6) equal intervals so the
    /// speed axis reads exactly like the 0-90 deg angle axis beside it. For those six steps
    /// to land on whole multiples of 5, the ceiling must be a multiple of
    /// `divisions * 5` — 90 gives 15s, 120 gives 20s, 300 gives 50s. A ceiling of 100,
    /// which is what this used to default to, gives 16.6667 and an axis labelled
    /// 0/17/33/50/67/83/100.
    ///
    /// Uniformly spaced, so the picker is an even ladder: 30, 60, ... 300.
    static let gaugeMaximumOptions: [Double] =
        Array(stride(from: MeterScale.ceilingStep, through: 300.0, by: MeterScale.ceilingStep))

    /// Inclusive bounds for `speedGaugeMaximum`, km/h — the ends of
    /// `gaugeMaximumOptions`. A stored value from an older build must not be able to
    /// produce a gauge with a zero or absurd span; 0 would make `fillFraction` divide by
    /// zero.
    static let gaugeMaximumRange: ClosedRange<Double> =
        (gaugeMaximumOptions.first ?? 30)...(gaugeMaximumOptions.last ?? 300)

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
            // Absent from preferences written before the toggle existed. Defaults ON, and
            // it deliberately does NOT match the fresh-install default below, which is now
            // off. The two answer different questions: this one is "what did this rider
            // already have?", and before the toggle shipped every rider had a speedometer.
            // Migrating them to off would switch off a readout they have been using,
            // silently, on the strength of a preference key they never saw.
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
            self.speedGaugeMaximum = Self.defaultGaugeMaximum
            // FRESH INSTALL default: speedometer OFF.
            //
            // The instrument this app is actually for is the angle — that comes from the
            // gyro and owes nothing to GNSS. Speed is a secondary readout that costs a
            // ~1 Hz location fix, and CoreLocation's own accuracy at low speed is poor
            // enough that its early readings have twice been mistaken for bugs. Starting
            // off means a new rider sees the meter that works before the one that needs
            // a sky view.
            //
            // This does NOT affect an existing install: the stored branch above reads
            // whatever the rider last set, so flipping this only changes first launch (or
            // first launch after deleting the app). `speedTarget` and `speedGaugeMaximum`
            // are still seeded so the meter has sane values the moment it is switched on.
            self.speedEnabled = false
            self.speedUnit = .kph
        }
    }

    /// Snaps a ceiling onto the nearest allowed option, rather than merely clamping it
    /// into range.
    ///
    /// Snapping and not clamping, because an off-ladder value is not a cosmetic problem:
    /// the meter divides the range into six and a ceiling that is not a multiple of 30
    /// yields fractional axis labels. Existing installs default to 100, which lands on 90
    /// here — a visible change to their gauge, and the only alternative was to keep
    /// rendering an axis labelled 0/17/33/50/67/83/100.
    static func clampGaugeMaximum(_ value: Double) -> Double {
        let fallback = gaugeMaximumOptions.first ?? 30
        guard value.isFinite else { return defaultGaugeMaximum }
        return gaugeMaximumOptions.min(by: {
            abs($0 - value) < abs($1 - value)
        }) ?? fallback
    }

    /// 120 km/h: on the ladder, and a plausible ceiling for a bike being ridden hard
    /// enough to loft the front. The old default was 100, which is not on it.
    static let defaultGaugeMaximum: Double = 120

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
