import Foundation
import Observation

enum SpeedUnit: String, Codable, Sendable, Equatable {
    case kph
    case mph
}

@Observable
final class RiderPreferences {
    private static let storageKey = "RiderPreferences"

    var angleTarget: MetricRange {
        didSet { save() }
    }
    var speedTarget: MetricRange {
        didSet { save() }
    }
    var speedGaugeMaximum: Double {
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
            self.speedGaugeMaximum = stored.speedGaugeMaximum
            self.speedUnit = stored.speedUnit
        } else {
            self.angleTarget = MetricRange(lower: 35, upper: 45)
            self.speedTarget = MetricRange(lower: 35, upper: 50)
            self.speedGaugeMaximum = 100
            self.speedUnit = .kph
        }
    }

    private func save() {
        let stored = StoredPreferences(
            angleTarget: angleTarget,
            speedTarget: speedTarget,
            speedGaugeMaximum: speedGaugeMaximum,
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
    let speedUnit: SpeedUnit
}
