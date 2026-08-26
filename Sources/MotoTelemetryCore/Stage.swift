import Foundation

/// One step of the pipeline. Takes the previous stage's output plus immutable
/// config, returns a new value, touches nothing outside itself.
///
/// Returning nil means "no output for this input" — a stage that consumes IMU
/// samples returns nil when handed a GNSS fix.
///
/// Every stage's output is logged, not just the final angle. When a reading is
/// wrong you need to see WHICH stage first went wrong; a single displayed
/// number tells you nothing.
public protocol Stage {
    associatedtype Input
    associatedtype Output
    mutating func process(_ input: Input) -> Output?
}

/// A source of measurements. Three implementations, one protocol: live sensors,
/// replay from a log file, and the synthetic generator. The pipeline cannot
/// tell them apart, which is what makes it testable without a motorcycle.
public protocol MeasurementSource {
    /// Next measurement in monotonic time order, or nil when exhausted.
    mutating func next() -> Measurement?
}
