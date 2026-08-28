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
///
/// v2 -> v3: calibration made survivable on a running bike, after every one of
/// its guards was found to reject a usable zeroing in favour of none at all.
/// `biasSigmaLimit` 0.01 -> 0.05 deg/s: the old value sat on the gyro's own noise
/// floor, so a zeroing passed or failed on luck rather than on anything the rider
/// controlled, and 0.05 deg/s is the error budget the README already states.
/// Added `gateCloseConfirm`, so a band violation must persist ~60 ms before the
/// gate closes and a single buzz sample can no longer slam it shut — duration, not
/// amplitude, is what separates engine excitation from real acceleration. Added
/// `biasGateGracePeriod`, so a transient dropout no longer discards seconds of
/// accumulation. `calibrationVibrationThreshold` no longer FAILS a zeroing -- it
/// only decides whether an out-of-band rejection is reported as vibration, which is
/// all its own doc comment ever claimed it did.
public struct Config: Codable, Sendable, Equatable {
    public var version: Int = 3

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
    /// How long a band violation must PERSIST before the gate actually closes.
    ///
    /// The gate compares the raw instantaneous sample, as it always did — but a
    /// single violating sample no longer slams it. That instantaneous closure is
    /// what made the gate an accidental vibration detector: on an idling bike one
    /// buzz sample leaves the +/-0.03 g window, closes the gate, resets the dwell
    /// and discards accumulated calibration, so 8 s of unbroken quiet never
    /// assembles and calibration sticks at 0% forever.
    ///
    /// Duration is the right discriminator, not amplitude. Engine excitation
    /// violates the band for at most half a cycle — 83 Hz aliases to 17 Hz at a
    /// 100 Hz sampler, so ~30 ms — while acceleration, braking and lean violate it
    /// for as long as they last. 60 ms therefore rejects buzz and still catches
    /// anything real.
    ///
    /// A LOW-PASS was tried here first and is the wrong mechanism: it delays closure
    /// by its time constant AND attenuates, so a 0.5 g onset reaches only 63% of its
    /// value after one tau and the filter keeps taking contaminated gravity updates
    /// deep into the ramp. `AccuracyMatrixTests` catches that as live error past 2
    /// deg. A confirmation window is exact and bounded: full amplitude, closed after
    /// 60 ms, no attenuation.
    ///
    /// This does NOT address aliasing: a twin at 6000 rpm folds to DC and looks like
    /// a steady tilt at any window length. That is attenuated mechanically, at the
    /// mount.
    public var gateCloseConfirm: TimeInterval = 0.06            // seconds

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
    /// 10 deg. Nothing below this counts as a wheelie and nothing below this is
    /// clocked: in the 0-10 deg band the reported angle is dominated by
    /// suspension travel, driveway lips and mount slop rather than by riding, so
    /// counting it inflates both the attempt count and every duration.
    public var eventEntryPitch: Double = 10.0 * .pi / 180      // rad
    /// 7 deg, preserving 3 deg of hysteresis below entry. Duration is therefore
    /// "time above 10 deg" plus the 10->7 deg tail on the way down; setting exit
    /// equal to entry would chatter one wheelie into several at 100 Hz, so the
    /// tail is the price of a stable segment boundary.
    public var eventExitPitch: Double = 7.0 * .pi / 180        // rad
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
    /// A zeroing whose per-axis sigma exceeds this FAILS, naming the axis.
    ///
    /// This is the STANDARD ERROR OF THE MEAN, `std/sqrt(n)`, not the raw spread:
    /// at 100 Hz over 8 s, n is ~800 and sqrt(n) ~28, so this limit demands a raw
    /// gyro spread under 1.4 deg/s. The previous 0.01 deg/s demanded under
    /// 0.28 deg/s, which is the noise floor of the sensor itself -- a zeroing then
    /// passed or failed on luck rather than on anything the rider could change,
    /// and the observed failures were 0.02-0.09 deg/s.
    ///
    /// What a breach actually costs is the point: bias error integrates linearly
    /// into angle, so 0.05 deg/s is 0.5 deg over a 10 s hold, which is exactly the
    /// budget stated in the README. Refusing a 0.02 deg/s estimate leaves the
    /// filter with NO bias at all, and an uncalibrated consumer gyro sits at
    /// 1-5 deg/s -- 10-50 deg over the same hold. The old limit therefore traded a
    /// 0.2 deg error for a 20 deg one. This limit is kept only as a ceiling
    /// against a zeroing taken while the bike was genuinely moving.
    public var biasSigmaLimit: Double = 0.05 * .pi / 180       // rad/s
    /// How long the validity gate may be CONTINUOUSLY closed before accumulated
    /// progress is discarded.
    ///
    /// Previously any single closed sample called `resetAccumulation()`, throwing
    /// away every sample collected so far and resetting the dwell. One 10 ms blip
    /// -- 0.2 deg of rotation, or one bump in the road -- cost 8 s of work, which
    /// on a running bike meant the 8 s never completed. Progress is now PAUSED
    /// across a dropout shorter than this and only discarded once the gate has
    /// been closed long enough that the bike may genuinely have moved or been
    /// re-oriented. Paused time does not count toward the required duration, so
    /// the estimate is still built from a full 8 s of quiet samples.
    public var biasGateGracePeriod: TimeInterval = 0.25         // seconds
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
    ///
    /// As of v3 this is REPORTING ONLY and can no longer fail a zeroing. It used to,
    /// which made calibrating on a running bike impossible and mid-ride
    /// recalibration impossible outright. The justification does not survive
    /// inspection: the bias estimate is the MEAN of the gyro, and averaging is
    /// precisely the operation that removes zero-mean vibration -- its uncertainty
    /// falls as `std/sqrt(n)`, which `biasSigmaLimit` already bounds. Only two paths
    /// turn vibration into a DC error that a mean cannot reject: SATURATION, whose
    /// non-linear rail rectifies AC into DC and which is still a hard reject on its
    /// own flag, and ALIASING, which a spread test cannot see at all. So this
    /// measurement never defended against the case that can actually hurt, and
    /// blocked the case that cannot.
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
        gateCloseConfirm      = try get(.gateCloseConfirm, d.gateCloseConfirm)

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
        biasGateGracePeriod     = try get(.biasGateGracePeriod, d.biasGateGracePeriod)
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
