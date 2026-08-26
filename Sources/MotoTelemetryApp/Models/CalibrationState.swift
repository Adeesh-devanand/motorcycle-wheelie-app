import Foundation

enum CalibrationStaleReason: String, Codable, Sendable {
    case timeout
    case thermalDrift
    case biasAgeExceeded
}

enum CalibrationState: Equatable, Sendable {
    case unavailable
    case calibrating(progress: Double?)
    case calibrated(referenceID: UUID, calibratedAt: Date)
    case stale(reason: CalibrationStaleReason)
    case failed(message: String)
}
