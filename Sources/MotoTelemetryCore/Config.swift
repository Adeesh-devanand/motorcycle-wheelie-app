import Foundation

/// Every tunable constant, in one versioned struct.
///
/// This gets serialized into each log's header, so a log always says which
/// parameters produced it and an old ride can be replayed against new tuning.
/// Nothing in the pipeline may read a magic number that does not live here.
public struct Config: Codable, Sendable, Equatable {
    public var version: Int = 1

    // -- Validity gate. Opens only when we can PROVE quasi-static, because the
    //    accelerometer cannot distinguish lean from turning or tilt from
    //    acceleration. At lean angle t the specific-force magnitude is 1/cos(t),
    //    so 20 deg = 1.06 g and 30 deg = 1.15 g: a +/-0.03 g window rejects
    //    anything past ~14 deg of lean before the rate test even fires.
    public var gateSpecificForceLow: Double = 0.97 * 9.80665   // m/s^2
    public var gateSpecificForceHigh: Double = 1.03 * 9.80665  // m/s^2
    public var gateMaxRotationRate: Double = 3.0 * .pi / 180   // rad/s, per axis
    public var gateDwell: TimeInterval = 0.5                   // must hold this long

    // -- Zero / baseline. Blend slowly so a brief false gate-open cannot yank
    //    the reference. Road grade is absorbed by the long time constant.
    public var baselineTimeConstant: TimeInterval = 25.0

    // -- Accelerometer low-pass. Signal of interest is DC..3 Hz; engine
    //    vibration is 30..200 Hz. NOTE: this does NOT fix aliasing — at 100 Hz
    //    sampling a twin at 6000 rpm folds to DC and the information is already
    //    destroyed. Aliasing is attenuated MECHANICALLY, at the mount.
    public var accelLowPassCutoff: Double = 5.0                // Hz

    // -- Cue engine. Fire on time-to-threshold, not on crossing it: angle is a
    //    lagging indicator and by the time you cross you are committed.
    public var timeToThresholdWarn: TimeInterval = 0.4
    /// Added to the lead time to absorb Bluetooth audio latency.
    /// HFP/SCO ~0.05 s; A2DP is 0.1-0.2 s and too slow — prefer wired or SCO.
    public var audioLatencyCompensation: TimeInterval = 0.05

    // -- Event segmentation.
    public var eventEntryPitchRate: Double = 15.0 * .pi / 180  // rad/s
    public var eventEntryPitch: Double = 8.0 * .pi / 180       // rad
    public var eventExitPitch: Double = 4.0 * .pi / 180        // rad
    public var eventMinDuration: TimeInterval = 0.4

    // -- Bias. Dominant error term in the whole system. A stationary average
    //    drives it to ~0.002 deg/s, but self-heating walks it ~0.1 deg/s over
    //    30 min, which is a whole degree over a 10 s hold. So: track bias age
    //    and degrade reported confidence with it.
    public var biasCalibrationDuration: TimeInterval = 8.0
    public var biasStaleAfter: TimeInterval = 300.0            // seconds

    // -- Sensor noise. PLACEHOLDERS. Replace with your own Allan variance
    //    results (3-4 h static record, allantools.oadev, read ARW off the
    //    -1/2 slope at tau=1 s and bias instability off the flat minimum
    //    divided by 0.664). These are priors for Q/R, never shipped truth:
    //    consumer MEMS varies unit to unit, so bias is still estimated live.
    public var gyroNoiseDensity: Double = 0.004 * .pi / 180    // rad/s/sqrt(Hz)
    public var gyroBiasInstability: Double = 3.0 * .pi / 180 / 3600 // rad/s
    public var accelNoiseDensity: Double = 100e-6 * 9.80665    // m/s^2/sqrt(Hz)

    // -- Barometer dynamic-pressure coefficient, calibrated per mount position.
    public var baroDynamicPressureK: Double = 0.0

    public init() {}
}
