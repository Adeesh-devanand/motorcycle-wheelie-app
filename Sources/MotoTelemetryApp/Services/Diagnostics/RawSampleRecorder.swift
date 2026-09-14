import Foundation
import MotoTelemetryCore

/// Raw data and diagnostic events share one ordered, durable recording file.
/// This adapter performs no I/O and owns no second file handle.
final class RawSampleRecorder: @unchecked Sendable {
    var fileURL: URL { DiagnosticLog.shared.currentFileURL }
    var fileSizeBytes: UInt64 { DiagnosticLog.shared.recordingSize }
    var droppedSamples: Int { DiagnosticLog.shared.recordingDrops }
    var sizeCapReached: Bool { DiagnosticLog.shared.recordingLimitReached }
    init(config: Config, bikeProfileID: UUID) {}
    func record(_ sample: Sample) { DiagnosticLog.shared.appendRecord(sample) }
    func flush() { DiagnosticLog.shared.flush() }
    func finish() { DiagnosticLog.shared.flush() }
}
