import Foundation

/// Every tunable constant, in one versioned struct.
///
/// This gets serialized into each log's header, so a log always says which
/// parameters produced it and an old ride can be replayed against new tuning.
/// Nothing in the pipeline may read a magic number that does not live here.
///
/// ## Versioning contract
/// `version` is incremented whenever a field is added, removed, or its default
/// meaning changes. Decoding is TOLERANT: an older header that lacks newer keys
/// decodes with this struct's current defaults for them, so a v1 log recorded
/// before a field existed still replays. `motolog` prints both the header's
/// version and any override in force, so which parameters produced a number is
/// never ambiguous.
///
/// v1 -> v2: `eventExitPitch` 4 deg -> 5 deg to match docs/ui-spec.md 7.6;
/// added the entry/exit dwells the ui spec required but which had no home here;
/// added the estimator, smoother, cue, quality, writer and display parameters.
public struct Config: Codable, Sendable, Equatable {
    public var version: Int = 2

    // MARK: - Validity gate
    // Opens only when we can PROVE quasi-static, because the accelerometer cannot
    // distinguish lean from turning or tilt from acceleration. At lean angle t the
    // specific-force magnitude is 1/cos(t), so 20 deg = 1.06 g and 30 deg = 1.15 g:
    // a +/-0.03 g window rejects anything past ~14 deg of lean before the rate
    // test even fires.
    public var gateSpecificForceLow: Double = 0.97 * 9.80665   // m/s^2
    public var gateSpecificForceHigh: Double = 1.03 * 9.80665  // m/s^2
    public var gateMaxRotationRate: Double = 3.0 * .pi / 180   // rad/s, per axis
    public var gateDwell: TimeInterval = 0.5                   // must hold this long

    // MARK: - Zero / baseline
    // Blend slowly so a brief false gate-open cannot yank the reference. Road
    // grade is absorbed by the long time constant. The baseline is FROZEN while
    // the gate is closed — a 25 s time constant would otherwise eat a 10 s hold.
    public var baselineTimeConstant: TimeInterval = 25.0

    // MARK: - Accelerometer low-pass
    // Signal of interest is DC..3 Hz; engine vibration is 30..200 Hz. NOTE: this
    // does NOT fix aliasing — at 100 Hz sampling a twin at 6000 rpm folds to DC
    // and the information is already destroyed. Aliasing is attenuated
    // MECHANICALLY, at the mount.
    public var accelLowPassCutoff: Double = 5.0                // Hz

    // MARK: - Cue engine
    // Fire on time-to-threshold, not on crossing it: angle is a lagging indicator
    // and by the time you cross you are committed.
    public var timeToThresholdWarn: TimeInterval = 0.4
    /// Added to the lead time to absorb Bluetooth audio latency.
    /// HFP/SCO ~0.05 s; A2DP is 0.1-0.2 s and too slow — prefer wired or SCO.
    /// Replaced at runtime by the measured route latency when one is available.
    public var audioLatencyCompensation: TimeInterval = 0.05
    /// Pitch rate above which the loop-out warning preempts the approach tone.
    public var loopOutPitchRate: Double = 60.0 * .pi / 180     // rad/s
    /// A sounding tone persists until its condition has been false this long.
    /// Without it a tone chatters on and off across the boundary at 100 Hz.
    public var cueReleaseTime: TimeInterval = 0.15

    // MARK: - Event segmentation
    public var eventEntryPitchRate: Double = 15.0 * .pi / 180  // rad/s
    public var eventEntryPitch: Double = 8.0 * .pi / 180       // rad
    /// 5 deg, per docs/ui-spec.md 7.6. Entry is 8 deg, so there is 3 deg of
    /// hysteresis between onset and end.
    public var eventExitPitch: Double = 5.0 * .pi / 180        // rad
    public var eventEntryDwell: TimeInterval = 0.15
    public var eventExitDwell: TimeInterval = 0.25
    public var eventMinDuration: TimeInterval = 0.4
    /// Deadband on pitch rate when locating the hold window's boundaries, so
    /// vibration does not produce spurious zero crossings.
    public var holdRateEpsilon: Double = 1.0 * .pi / 180       // rad/s

    // MARK: - Bias
    // Dominant error term in the whole system. A stationary average drives it to
    // ~0.002 deg/s, but self-heating walks it ~0.1 deg/s over 30 min, which is a
    // whole degree over a 10 s hold. So: track bias age and degrade reported
    // confidence with it.
    public var biasCalibrationDuration: TimeInterval = 8.0
    public var biasStaleAfter: TimeInterval = 300.0            // seconds
    /// How long a zeroing attempt may fail to open the gate before it gives up
    /// and tells the rider why, rather than spinning indefinitely.
    public var biasAttemptWindow: TimeInterval = 30.0
    /// A zeroing whose per-axis sigma exceeds this FAILS, naming the axis, rather
    /// than being accepted. Expected sigma after 10 s at 100 Hz is ~0.0014 deg/s,
    /// so a breach here is real signal, not a tight threshold.
    public var biasSigmaLimit: Double = 0.01 * .pi / 180       // rad/s
    /// Bias process-noise multiplier by ProcessInfo.ThermalState raw value
    /// (nominal, fair, serious, critical).
    public var thermalBiasNoiseScale: [Double] = [1.0, 2.0, 4.0, 8.0]

    // MARK: - Sensor noise
    // PLACEHOLDERS until `motolog allan` output replaces them (task T2.4).
    // Read ARW off the -1/2 slope at tau=1 s and bias instability off the flat
    // minimum divided by 0.664. These are priors for Q/R, never shipped truth:
    // consumer MEMS varies unit to unit, so bias is still estimated live.
    public var gyroNoiseDensity: Double = 0.004 * .pi / 180    // rad/s/sqrt(Hz)
    public var gyroBiasInstability: Double = 3.0 * .pi / 180 / 3600 // rad/s
    public var accelNoiseDensity: Double = 100e-6 * 9.80665    // m/s^2/sqrt(Hz)

    // MARK: - Estimator
    /// Accelerometer measurement-noise multiplier when the gate is closed but the
    /// specific-force magnitude is still near g.
    public var accelNoiseInflation: Double = 100.0
    /// Multiplier when the magnitude is also out of band. Inflating rather than
    /// dropping keeps the filter continuous: a hard on/off schedule injects a
    /// covariance step every time a bump closes the gate, and steps are what make
    /// an angle readout jump.
    public var accelNoiseInflationDynamic: Double = 10_000.0
    /// Linear-acceleration content above which inflation applies.
    public var accelDynamicThreshold: Double = 0.1 * 9.80665   // m/s^2
    /// Depth of the delayed-state ring used to apply a GNSS fix at its own
    /// fixTime and re-propagate forward. A fix older than this is discarded and
    /// counted.
    public var delayedStateWindow: TimeInterval = 2.0
    /// GNSS pitch aiding is suppressed during an event and within this margin of
    /// one: at 1 Hz it cannot track a 1.2 s ramp, and a Doppler difference
    /// straddling onset is meaningless. Its job is bias containment before the
    /// event, not tracking during it.
    public var gnssAidingEventMargin: TimeInterval = 1.0
    /// Fixes worse than this are not used for aiding.
    public var gnssMaxSpeedAccuracy: Double = 0.5              // m/s

    // MARK: - Smoother
    /// Margin either side of an event for the RTS window. Whole-session smoothing
    /// would cost ~75 MB of transient state for no benefit: RTS information decays
    /// over a few filter time constants.
    public var smootherWindowMargin: TimeInterval = 10.0
    /// Gate-open samples required AFTER an event before it can be smoothed. The
    /// backward pass has nothing to propagate without a post-event gravity anchor.
    public var smootherMinAnchorSamples: Int = 200

    // MARK: - Metrics
    /// Below this many GNSS fixes inside an event, distance reports nil rather
    /// than a fabricated number.
    public var distanceMinFixes: Int = 4

    // MARK: - In-range intervals (docs/ui-spec.md 9.6)
    // Order of operations is load-bearing: merge gaps FIRST, then drop short
    // fragments. Filtering first would delete jitter around a band edge as three
    // sub-threshold fragments and then have nothing left to merge.
    public var intervalMinDuration: TimeInterval = 0.15
    public var intervalMergeGap: TimeInterval = 0.10

    // MARK: - Quality and aliasing disclosure
    /// Corner of the one-pole high-pass whose RMS is the vibration indicator.
    public var highFreqCutoff: Double = 20.0                   // Hz
    /// Above this 1 s RMS, calibration fails and rides are flagged. The fix named
    /// to the rider is mechanical isolation, never a software setting.
    public var highFreqRMSThreshold: Double = 1.5              // m/s^2
    /// Standard deviation of |specific force| above which a stationary
    /// calibration is rejected as too shaky, m/s^2. A separate, much lower
    /// threshold than the ride-time one, and a different statistic.
    ///
    /// The validity gate's specific-force window is +/-0.03 g, i.e. 0.294 m/s^2,
    /// so any vibration big enough to reach `highFreqRMSThreshold` has already
    /// been rejected by the gate — instantaneously, since the gate does not
    /// average. That left the vibration failure unreachable during calibration
    /// and told a rider with a buzzing mount that the bike "is not level and
    /// still", which is true but useless. So: the gate remains the detector, and
    /// this threshold decides whether an out-of-band rejection is REPORTED as
    /// vibration. It must sit below the gate's window to be reachable.
    public var calibrationVibrationThreshold: Double = 0.1  // m/s^2
    /// Runs whose reported uncertainty exceeds these are marked lowConfidence and
    /// excluded from personal bests.
    public var liveSigmaLimit: Double = 3.0 * .pi / 180        // rad
    public var smoothedSigmaLimit: Double = 1.5 * .pi / 180    // rad

    // MARK: - Mount alignment
    /// Gesture (b) must reach this longitudinal acceleration or alignment is
    /// rejected with a request for a harder pull.
    public var alignmentMinPullAccel: Double = 0.25 * 9.80665  // m/s^2
    /// Maximum tolerated non-orthogonality between the solved axes.
    public var alignmentMaxResidual: Double = 5.0 * .pi / 180  // rad

    // MARK: - Logging and display
    public var nominalSampleRate: Double = 100.0               // Hz
    /// Rate of the decimated display series stored with a run. Raw stays in the
    /// session log and is hydrated on demand.
    public var displayDecimationRate: Double = 30.0            // Hz
    /// Ring-buffer depth between the sensor callback and the disk writer.
    /// Overwrite is FORBIDDEN: a full buffer increments a drop counter that
    /// surfaces in the integrity report and must be zero for a session to be
    /// trusted. Silently dropping raw samples would defeat the point of the log.
    public var writerRingCapacity: Int = 8192
    /// fsync cadence. This is what bounds "a force-quit loses at most 1 s".
    public var fsyncInterval: TimeInterval = 1.0
    /// Frames of full-screen white at ride start, as a visual alignment mark for
    /// an external camera. Replaces the withdrawn audio chirp.
    public var syncFlashFrames: Int = 6
    /// Full-scale ranges used to set IMUSample.saturated, with a 1% margin.
    public var gyroFullScale: Double = 2000.0 * .pi / 180      // rad/s
    public var accelFullScale: Double = 16.0 * 9.80665         // m/s^2

    // MARK: - Barometer
    /// Dynamic-pressure coefficient, calibrated per mount position. Unused in
    /// v1: grade comes from the gate-open pitch baseline instead, because this
    /// needs a per-mount calibration procedure we do not have. The channel is
    /// still logged.
    public var baroDynamicPressureK: Double = 0.0

    public init() {}

    /// Tolerant decoding, required by the versioning contract above.
    ///
    /// Swift's synthesized `init(from:)` calls `decode` rather than
    /// `decodeIfPresent` for non-optional properties, so a default value does NOT
    /// make a missing key survive — a v1 header would throw `keyNotFound` on
    /// every field added in v2, and every log recorded before this commit would
    /// become unreadable. Hence the explicit initializer: absent keys fall back to
    /// this version's defaults, present keys win.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }

        version = try get(.version, d.version)

        gateSpecificForceLow  = try get(.gateSpecificForceLow, d.gateSpecificForceLow)
        gateSpecificForceHigh = try get(.gateSpecificForceHigh, d.gateSpecificForceHigh)
        gateMaxRotationRate   = try get(.gateMaxRotationRate, d.gateMaxRotationRate)
        gateDwell             = try get(.gateDwell, d.gateDwell)

        baselineTimeConstant  = try get(.baselineTimeConstant, d.baselineTimeConstant)
        accelLowPassCutoff    = try get(.accelLowPassCutoff, d.accelLowPassCutoff)

        timeToThresholdWarn      = try get(.timeToThresholdWarn, d.timeToThresholdWarn)
        audioLatencyCompensation = try get(.audioLatencyCompensation, d.audioLatencyCompensation)
        loopOutPitchRate         = try get(.loopOutPitchRate, d.loopOutPitchRate)
        cueReleaseTime           = try get(.cueReleaseTime, d.cueReleaseTime)

        eventEntryPitchRate = try get(.eventEntryPitchRate, d.eventEntryPitchRate)
        eventEntryPitch     = try get(.eventEntryPitch, d.eventEntryPitch)
        eventExitPitch      = try get(.eventExitPitch, d.eventExitPitch)
        eventEntryDwell     = try get(.eventEntryDwell, d.eventEntryDwell)
        eventExitDwell      = try get(.eventExitDwell, d.eventExitDwell)
        eventMinDuration    = try get(.eventMinDuration, d.eventMinDuration)
        holdRateEpsilon     = try get(.holdRateEpsilon, d.holdRateEpsilon)

        biasCalibrationDuration = try get(.biasCalibrationDuration, d.biasCalibrationDuration)
        biasStaleAfter          = try get(.biasStaleAfter, d.biasStaleAfter)
        biasAttemptWindow       = try get(.biasAttemptWindow, d.biasAttemptWindow)
        biasSigmaLimit          = try get(.biasSigmaLimit, d.biasSigmaLimit)
        thermalBiasNoiseScale   = try get(.thermalBiasNoiseScale, d.thermalBiasNoiseScale)

        gyroNoiseDensity     = try get(.gyroNoiseDensity, d.gyroNoiseDensity)
        gyroBiasInstability  = try get(.gyroBiasInstability, d.gyroBiasInstability)
        accelNoiseDensity    = try get(.accelNoiseDensity, d.accelNoiseDensity)

        accelNoiseInflation        = try get(.accelNoiseInflation, d.accelNoiseInflation)
        accelNoiseInflationDynamic = try get(.accelNoiseInflationDynamic, d.accelNoiseInflationDynamic)
        accelDynamicThreshold      = try get(.accelDynamicThreshold, d.accelDynamicThreshold)
        delayedStateWindow         = try get(.delayedStateWindow, d.delayedStateWindow)
        gnssAidingEventMargin      = try get(.gnssAidingEventMargin, d.gnssAidingEventMargin)
        gnssMaxSpeedAccuracy       = try get(.gnssMaxSpeedAccuracy, d.gnssMaxSpeedAccuracy)

        smootherWindowMargin     = try get(.smootherWindowMargin, d.smootherWindowMargin)
        smootherMinAnchorSamples = try get(.smootherMinAnchorSamples, d.smootherMinAnchorSamples)

        distanceMinFixes = try get(.distanceMinFixes, d.distanceMinFixes)

        intervalMinDuration = try get(.intervalMinDuration, d.intervalMinDuration)
        intervalMergeGap    = try get(.intervalMergeGap, d.intervalMergeGap)

        highFreqCutoff       = try get(.highFreqCutoff, d.highFreqCutoff)
        highFreqRMSThreshold = try get(.highFreqRMSThreshold, d.highFreqRMSThreshold)
        calibrationVibrationThreshold = try get(.calibrationVibrationThreshold,
                                                   d.calibrationVibrationThreshold)
        liveSigmaLimit       = try get(.liveSigmaLimit, d.liveSigmaLimit)
        smoothedSigmaLimit   = try get(.smoothedSigmaLimit, d.smoothedSigmaLimit)

        alignmentMinPullAccel = try get(.alignmentMinPullAccel, d.alignmentMinPullAccel)
        alignmentMaxResidual  = try get(.alignmentMaxResidual, d.alignmentMaxResidual)

        nominalSampleRate     = try get(.nominalSampleRate, d.nominalSampleRate)
        displayDecimationRate = try get(.displayDecimationRate, d.displayDecimationRate)
        writerRingCapacity    = try get(.writerRingCapacity, d.writerRingCapacity)
        fsyncInterval         = try get(.fsyncInterval, d.fsyncInterval)
        syncFlashFrames       = try get(.syncFlashFrames, d.syncFlashFrames)
        gyroFullScale         = try get(.gyroFullScale, d.gyroFullScale)
        accelFullScale        = try get(.accelFullScale, d.accelFullScale)

        baroDynamicPressureK = try get(.baroDynamicPressureK, d.baroDynamicPressureK)
    }
}
