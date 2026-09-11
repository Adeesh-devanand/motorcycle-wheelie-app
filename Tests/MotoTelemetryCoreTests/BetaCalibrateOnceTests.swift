import XCTest
@testable import MotoTelemetryCore

/// Tests for the beta "calibrate-once" path: the jitter blur, the swipe-derived
/// alignment, the raw-gyro estimator, and the config flags that make a log say
/// which of the two estimators produced it.
final class BetaCalibrateOnceTests: XCTestCase {

    // MARK: - Config

    func testCurrentVersionAndTheChangedDefaults() {
        let config = Config()
        XCTAssertEqual(config.version, 8)
        XCTAssertEqual(config.eventMinDuration, 1.0, accuracy: 1e-12)
        XCTAssertEqual(config.biasCalibrationDuration, 2.0, accuracy: 1e-12)
        // v7's two additions, both previously hardcoded literals.
        XCTAssertEqual(config.maxIntegrationDt, 1.0, accuracy: 1e-12)
        XCTAssertEqual(config.maxSampleGap, 0.5, accuracy: 1e-12)
    }

    /// A v5 header predates the beta fields. It must still decode, with them at
    /// their v6 defaults — otherwise every log recorded before this commit becomes
    /// unreadable, which is the whole point of the tolerant decoder.
    func testVersionFiveHeaderStillDecodes() throws {
        let json = #"{"version":5,"eventMinDuration":0.4,"gateDwell":0.5}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.version, 5)
        XCTAssertEqual(config.eventMinDuration, 0.4, accuracy: 1e-12)
        // A field absent from the v5 JSON falls back to this version's default.
        XCTAssertEqual(config.blurWindowSamples, Config().blurWindowSamples)
        XCTAssertEqual(config.calibrationVibrationLimit,
                       Config().calibrationVibrationLimit, accuracy: 1e-12)
    }

    func testConfigRoundTripsTheNewFields() throws {
        var config = Config()
        config.calibrationVibrationLimit = 0.42
        config.alignmentConfidenceMin = 0.5
        config.blurWindowSamples = 11
        config.cueEnterPitch = 12.0 * .pi / 180
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)

        // Compared numerically, not bit-exactly. `XCTAssertEqual(decoded, config)`
        // is green on Linux and RED on macOS: Foundation's JSON double formatting
        // is platform-dependent, and seven of the degree->radian constants come
        // back one ULP off on Darwin (gateMaxRotationRate 0.05235987755982989 vs
        // ...88; also calibrationMaxRotationRate, reanchorBiasDelta, cueDeadband,
        // holdRateEpsilon, biasSigmaLimit, liveSigmaLimit). 1e-12 rad is 6e-11 deg
        // — below any physical meaning — so the tolerance costs no real strictness
        // while still catching a field that fails to serialise, lands on the wrong
        // key, or silently falls back to its default.
        let before = try Self.numericFields(of: config)
        let after = try Self.numericFields(of: decoded)
        XCTAssertEqual(after.keys.sorted(), before.keys.sorted(),
                       "a field appeared or vanished across the round trip")
        for (key, expected) in before {
            let actual = try XCTUnwrap(after[key], "\(key) missing after round trip")
            XCTAssertEqual(actual.count, expected.count, "\(key) changed arity")
            for (i, value) in expected.enumerated() where i < actual.count {
                XCTAssertEqual(actual[i], value, accuracy: 1e-12,
                               "\(key)[\(i)] did not survive the round trip")
            }
        }

        // Stated explicitly, so the round trip is proven to carry non-default
        // values rather than defaults that happen to agree on both sides.
        XCTAssertEqual(decoded.version, 8)
        XCTAssertEqual(decoded.calibrationVibrationLimit, 0.42, accuracy: 1e-12)
        XCTAssertEqual(decoded.alignmentConfidenceMin, 0.5, accuracy: 1e-12)
        XCTAssertEqual(decoded.blurWindowSamples, 11)
        XCTAssertEqual(decoded.cueEnterPitch, 12.0 * .pi / 180, accuracy: 1e-12)
    }

    /// Flattens a `Config`'s JSON encoding to `key -> [Double]` so two configs can
    /// be compared field by field with a tolerance. Scalars become one-element
    /// arrays. Pure `Codable`, so it behaves identically on Darwin and Linux —
    /// `JSONSerialization` + `NSNumber` casts do not.
    ///
    /// Every one of Config's 63 fields is numeric today. If a `Bool` or `String`
    /// field is ever added, this throws rather than silently skipping it — that is
    /// the signal to extend `NumericField`, not to drop the field from the check.
    private static func numericFields(of config: Config) throws -> [String: [Double]] {
        let data = try JSONEncoder().encode(config)
        let fields = try JSONDecoder().decode([String: NumericField].self, from: data)
        return fields.mapValues(\.values)
    }

    private enum NumericField: Decodable {
        case scalar(Double)
        case list([Double])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .scalar(value)
            } else {
                self = .list(try container.decode([Double].self))
            }
        }

        var values: [Double] {
            switch self {
            case .scalar(let value): return [value]
            case .list(let values): return values
            }
        }
    }

    // MARK: - Jitter blur

    func testBlurLeavesAFlatSeriesFlat() throws {
        let flat = [Double](repeating: 12.0, count: 200)
        let blurred = try JitterBlur().blur(flat).get()
        XCTAssertEqual(blurred.count, flat.count)
        for value in blurred {
            XCTAssertEqual(value, 12.0, accuracy: 1e-12)
        }
    }

    /// The zero-phase property, stated as a test: a straight ramp must come back
    /// with the same slope AND the same values, because a centred average of a
    /// linear function is the function itself. Any time shift would show up here as
    /// an offset, which is exactly what a causal filter would produce.
    func testBlurPreservesARampWithNoTimeShift() throws {
        let ramp = (0..<200).map { Double($0) * 0.25 }
        let blurred = try JitterBlur().blur(ramp).get()
        for (i, value) in blurred.enumerated() {
            XCTAssertEqual(value, ramp[i], accuracy: 1e-9,
                           "index \(i) shifted — the window is not centred")
        }
    }

    func testBlurPullsDownALoneSpike() throws {
        var series = [Double](repeating: 40.0, count: 200)
        series[100] += 4.0                      // one +4 deg vibration spike
        let blur = JitterBlur()
        let blurred = try blur.blur(series).get()

        XCTAssertEqual(series.max()!, 44.0, accuracy: 1e-12)
        // A centred boxcar spreads a lone spike evenly over the whole window, so the
        // residual is exactly spike/windowSamples. DERIVED from the window rather than
        // hardcoded: the old assertion only bounded the result to 40.0...41.0, which is
        // ~2.3x wider than the physics and would have passed just as happily with a
        // 5-wide window (residual 0.80) as with the intended 9-wide one (0.444). A test
        // that accepts the wrong window width is not testing the window.
        let expectedResidual = 4.0 / Double(blur.windowSamples)
        XCTAssertEqual(blurred.max()!, 40.0 + expectedResidual, accuracy: 1e-9,
                       "a lone spike must be attenuated by exactly the window width")
    }

    /// The scoring consequence, which is the reason the blur exists at all.
    func testMaxOverBlurredIsBelowMaxOverRaw() throws {
        var series = [Double](repeating: 40.0, count: 300)
        // Deliberately not at index 0: see `testEndpointsAreDeliberatelyUnfiltered`.
        for i in stride(from: 20, to: 280, by: 7) { series[i] += 3.5 }
        let blurred = try JitterBlur().blur(series).get()
        XCTAssertLessThan(blurred.max()!, series.max()!)
    }

    /// A property worth pinning because it is a real limitation, not an oversight.
    /// The window truncates symmetrically at the edges, so the FIRST and LAST samples
    /// average over themselves alone and are returned unchanged. A spike sitting
    /// exactly on the boundary therefore survives the blur.
    ///
    /// The alternatives are worse: padding with a repeated end value drags the
    /// endpoints toward it, and sliding the window off-centre shifts them in time —
    /// which would fake a ramp at the start of every wheelie, exactly where the entry
    /// peak lives. In practice the recorded window extends past the event on both
    /// sides, so the event's own samples are never the endpoints.
    func testEndpointsAreDeliberatelyUnfiltered() throws {
        var series = [Double](repeating: 40.0, count: 100)
        series[0] = 44.0
        let blurred = try JitterBlur().blur(series).get()
        XCTAssertEqual(blurred[0], 44.0, accuracy: 1e-12)
        XCTAssertLessThan(blurred[1], 44.0, "index 1 already has neighbours")
    }

    func testBlurRefusesASeriesShorterThanTheMinimum() {
        let short = [Double](repeating: 1.0, count: 10)
        switch JitterBlur().blur(short) {
        case .success:
            XCTFail("a series below blurMinSamples must be refused, not blurred")
        case .failure(let error):
            XCTAssertEqual(error, .tooFewSamples(count: 10,
                                                 required: Config().blurMinSamples))
        }
    }

    func testBlurWindowIsAlwaysOdd() {
        // An even configured width must round to an odd one: an even window has no
        // centre sample, so it would shift the series in time.
        var config = Config()
        config.blurWindowSamples = 8
        XCTAssertEqual(JitterBlur(config: config).windowSamples % 2, 1)
        config.blurWindowSamples = 9
        XCTAssertEqual(JitterBlur(config: config).windowSamples % 2, 1)
        config.blurWindowSamples = 0
        XCTAssertEqual(JitterBlur(config: config).windowSamples % 2, 1)
    }

    func testBlurDoesNotMoveTimestamps() throws {
        let series = (0..<100).map { (time: Double($0) * 0.01, value: Double($0)) }
        let blurred = try JitterBlur().blur(series).get()
        for (original, result) in zip(series, blurred) {
            XCTAssertEqual(original.time, result.time, accuracy: 1e-12)
        }
    }

    // MARK: - Swipe alignment

    /// Phone flat on the tank, long axis across the bike, swipe toward the front.
    /// Gravity is along device -Z, the swipe along device +Y, so the swipe is fully
    /// horizontal and confidence is 1.
    func testSwipeFlatOnTankRecoversForwardExactly() {
        let rest = Vector3(0, 0, -Conventions.g)          // gravity along device -Z
        let alignment = MountAlignment.fromMeasuredGravity(
            specificForce: rest,
            screenYaw: .pi / 2                            // swipe along +Y
        )

        XCTAssertEqual(alignment.swipeConfidence ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(alignment.forwardInBody.y, 1.0, accuracy: 1e-9)
        XCTAssertEqual(alignment.upInBody.z, 1.0, accuracy: 1e-9)
        // Right-handedness: forward x left == up.
        let cross = alignment.forwardInBody.cross(alignment.leftInBody)
        XCTAssertEqual(cross.z, 1.0, accuracy: 1e-9)
    }

    /// On a flat mount the projection is a NO-OP: gravity lies along the screen
    /// normal, so no swipe direction has a vertical component to strip, and every
    /// swipe returns full confidence. Worth pinning because it is the reason the
    /// flat case needs no special handling at all.
    func testFlatMountGivesFullConfidenceForEverySwipeDirection() {
        let rest = Vector3(0, 0, -Conventions.g)
        for degrees in stride(from: 0.0, to: 360.0, by: 15.0) {
            let alignment = MountAlignment.fromMeasuredGravity(
                specificForce: rest, screenYaw: degrees * .pi / 180)
            XCTAssertEqual(alignment.swipeConfidence ?? 0, 1.0, accuracy: 1e-9,
                           "swipe at \(degrees) deg on a flat mount")
        }
    }

    /// Bar-mounted portrait phone, screen facing the rider, swipe bottom-to-top.
    /// Device down is -Y, so the swipe runs ALONG gravity and |p| collapses to 0.
    ///
    /// That is NOT a failure — it is the classifier firing. It says the mount is
    /// vertical, which means the chassis axis points out through the screen, so
    /// heading comes from the screen normal. The one thing that must not happen is
    /// letting `p / |p|` run: 0/0 is NaN and would poison every later pitch reading.
    func testSwipeAlongGravityTakesTheScreenNormalBranch() {
        let rest = Vector3(0, -Conventions.g, 0)          // device down is -Y
        let alignment = MountAlignment.fromMeasuredGravity(specificForce: rest,
                                                           screenYaw: .pi / 2)

        XCTAssertEqual(alignment.forwardInBody.z, -1.0, accuracy: 1e-9,
                       "forward must be into the screen, not a NaN or the lateral axis")
        XCTAssertEqual(alignment.upInBody.y, 1.0, accuracy: 1e-9)
        XCTAssertEqual(alignment.swipeConfidence ?? -1, 0,
                       "confidence 0 records that this came from the vertical branch")

        // No NaN anywhere — the whole point of branching rather than dividing.
        for component in [alignment.forwardInBody.x, alignment.forwardInBody.y,
                          alignment.forwardInBody.z, alignment.leftInBody.x,
                          alignment.leftInBody.y, alignment.leftInBody.z] {
            XCTAssertFalse(component.isNaN, "NaN leaked into the alignment")
        }
    }

    /// And the branch must produce a usable estimator, not merely non-NaN numbers:
    /// a vertical mount at rest still has to read 0 deg.
    func testVerticalMountBranchReadsLevelAtRest() {
        let rest = Vector3(0, -Conventions.g, 0)
        let alignment = MountAlignment.fromMeasuredGravity(specificForce: rest,
                                                           screenYaw: .pi / 2)
        let live = CalibrateOnceEstimator(config: Config(),
                                         alignment: alignment,
                                         bias: .zero,
                                         gravityAnchor: rest)
        XCTAssertTrue(live.isAnchored)
        XCTAssertEqual(live.pitch * 180 / .pi, 0, accuracy: 1e-6)
        XCTAssertFalse(live.pitch.isNaN)
    }

    func testSwipeConfidenceFallsWithMountTilt() {
        let cases: [(tilt: Double, expected: Double)] = [
            (0, 1.0),                       // screen horizontal: swipe fully in plane
            (.pi / 6, cos(.pi / 6)),
            (.pi / 3, cos(.pi / 3)),
        ]
        for c in cases {
            // Tilt gravity toward the swipe axis (+Y) by `tilt`.
            let rest = Vector3(0, -Conventions.g * sin(c.tilt), -Conventions.g * cos(c.tilt))
            let alignment = MountAlignment.fromMeasuredGravity(
                specificForce: rest, screenYaw: .pi / 2)
            XCTAssertEqual(alignment.swipeConfidence ?? 0, c.expected, accuracy: 1e-9,
                           "tilt \(c.tilt * 180 / .pi) deg")
        }
    }

    /// The UIKit flip, pinned. Screen dy grows DOWNWARD, so a bottom-to-top swipe
    /// arrives as negative dy and must resolve to device +Y. Getting this backwards
    /// reverses the bike's forward axis and reports every wheelie as a stoppie.
    func testRawGestureDeltasApplyTheDownwardYFlip() throws {
        let rest = Vector3(0, 0, -Conventions.g)
        let upward = try MountAlignment.fromSwipe(specificForce: rest,
                                                  screenDX: 0,
                                                  screenDY: -100).get()
        XCTAssertEqual(upward.forwardInBody.y, 1.0, accuracy: 1e-9,
                       "an upward swipe must map to device +Y")

        let downward = try MountAlignment.fromSwipe(specificForce: rest,
                                                    screenDX: 0,
                                                    screenDY: 100).get()
        XCTAssertEqual(downward.forwardInBody.y, -1.0, accuracy: 1e-9)
    }

    /// The ONLY genuine failure left: the rider tapped instead of drawing, so there
    /// is no direction to read at all.
    func testZeroLengthSwipeIsTheOnlyRefusal() {
        let rest = Vector3(0, 0, -Conventions.g)
        switch MountAlignment.fromSwipe(specificForce: rest, screenDX: 0, screenDY: 0) {
        case .success: XCTFail("a zero-length swipe has no direction")
        case .failure(let error):
            XCTAssertEqual(error, .noSwipeDirection)
        }
    }

    /// The fallback must produce a forward axis through the SCREEN, never the
    /// lateral axis — the whole point of having a fallback at all.
    func testScreenNormalFallbackPointsThroughTheScreen() {
        let rest = Vector3(0, -Conventions.g, 0)         // bar-mounted portrait
        let alignment = MountAlignment.fromScreenNormal(specificForce: rest)
        XCTAssertEqual(alignment.forwardInBody.z, -1.0, accuracy: 1e-9,
                       "forward must be into the screen (device -Z)")
        XCTAssertEqual(alignment.upInBody.y, 1.0, accuracy: 1e-9)
        XCTAssertNotEqual(abs(alignment.forwardInBody.x), 1.0, accuracy: 1e-6,
                          "forward must NOT be the lateral axis")
    }

    // MARK: - The live estimator

    func testEstimatorReadsZeroAtRestAndIsAnchored() {
        let estimator = CalibrateOnceEstimator(
            config: Config(),
            alignment: .identity(),
            bias: .zero,
            gravityAnchor: Conventions.restSpecificForce)
        XCTAssertTrue(estimator.isAnchored)
        XCTAssertEqual(estimator.pitch, 0, accuracy: 1e-9)
    }

    func testEstimatorPublishesNothingBeforeAnchoring() {
        var estimator = CalibrateOnceEstimator(config: Config(),
                                               alignment: .identity(),
                                               bias: .zero)
        XCTAssertFalse(estimator.isAnchored)
        let sample = IMUSample(time: 0.01,
                              rotationRate: Vector3(0, -0.5, 0),
                              specificForce: Conventions.restSpecificForce)
        XCTAssertFalse(estimator.integrate(sample),
                       "integrating before the world frame exists is meaningless")
    }

    /// Integrating a constant nose-up rate must produce the corresponding angle.
    /// Nose-up is a NEGATIVE rotation about bike +Y, per Conventions — if that sign
    /// is wrong the reported angle goes negative during a wheelie.
    func testEstimatorIntegratesNoseUpWithTheRightSign() {
        var estimator = CalibrateOnceEstimator(
            config: Config(),
            alignment: .identity(),
            bias: .zero,
            gravityAnchor: Conventions.restSpecificForce)

        let dt = 0.01
        let pitchRate = 20.0 * .pi / 180            // 20 deg/s nose-up
        for i in 0...100 {                           // 1.0 s
            let sample = IMUSample(time: Double(i) * dt,
                                   rotationRate: Conventions.rotationRate(pitchRate: pitchRate),
                                   specificForce: Conventions.restSpecificForce)
            estimator.integrate(sample)
        }

        XCTAssertEqual(estimator.pitch * 180 / .pi, 20.0, accuracy: 0.05)
        XCTAssertEqual(estimator.pitchRate * 180 / .pi, 20.0, accuracy: 1e-6,
                       "pitchRate must be positive while pitching UP")
    }

    /// Bias subtraction is the mode's entire accuracy story: an unsubtracted bias
    /// integrates straight into angle error, linearly in time.
    func testBiasIsSubtractedAndNotSubtractedTwice() {
        let bias = Vector3(0, -2.0 * .pi / 180, 0)   // 2 deg/s on the pitch axis
        var withBias = CalibrateOnceEstimator(
            config: Config(), alignment: .identity(), bias: bias,
            gravityAnchor: Conventions.restSpecificForce)
        var withoutBias = CalibrateOnceEstimator(
            config: Config(), alignment: .identity(), bias: .zero,
            gravityAnchor: Conventions.restSpecificForce)

        // A perfectly still bike whose gyro reads only its own bias.
        for i in 0...500 {                           // 5 s
            let sample = IMUSample(time: Double(i) * 0.01,
                                   rotationRate: bias,
                                   specificForce: Conventions.restSpecificForce)
            withBias.integrate(sample)
            withoutBias.integrate(sample)
        }

        XCTAssertEqual(withBias.pitch, 0, accuracy: 1e-9,
                       "a correctly subtracted bias leaves a still bike at zero")
        // 2 deg/s for 5 s is 10 deg of pure fiction — what the subtraction prevents.
        XCTAssertEqual(withoutBias.pitch * 180 / .pi, 10.0, accuracy: 0.1)
    }

    /// Pitch is read as axis ELEVATION, so lean must not leak into it. This is the
    /// property that makes cornering not read as a wheelie, and the reason the code
    /// must never reach for an Euler decomposition.
    ///
    /// Stated as: pitch up, note the angle, then roll about the bike's FORWARD axis
    /// and require the pitch reading not to move. Rotating a vector about itself is
    /// the identity, so the elevation of the forward axis is mathematically immune to
    /// roll — an Euler unpack would not be, and would drift here depending on order.
    func testPitchIsIndependentOfRollInTheBetaEstimator() {
        var estimator = CalibrateOnceEstimator(
            config: Config(),
            alignment: .identity(),
            bias: .zero,
            gravityAnchor: Conventions.restSpecificForce)

        let dt = 0.01
        var t = 0.0
        func feed(_ rate: Vector3, seconds: Double) {
            for _ in 0..<Int(seconds / dt) {
                t += dt
                estimator.integrate(IMUSample(
                    time: t, rotationRate: rate,
                    specificForce: Conventions.restSpecificForce))
            }
        }

        // Prime the first-sample dt, then pitch up 20 deg/s for 1 s.
        feed(.zero, seconds: 0.02)
        feed(Conventions.rotationRate(pitchRate: 20.0 * .pi / 180), seconds: 1.0)
        let pitchBeforeRoll = estimator.pitch
        XCTAssertEqual(pitchBeforeRoll * 180 / .pi, 20.0, accuracy: 0.1)

        // Now roll hard about the bike's forward axis (bike +X) and nothing else.
        feed(Vector3(60.0 * .pi / 180, 0, 0), seconds: 1.0)

        XCTAssertEqual(estimator.pitch, pitchBeforeRoll, accuracy: 1e-6,
                       "60 deg of lean moved the pitch reading — pitch is being "
                       + "decomposed rather than read as an axis elevation")
        XCTAssertGreaterThan(abs(estimator.roll * 180 / .pi), 50.0,
                             "the roll channel should have registered the lean")
    }

    func testEstimatorSkipsImpossibleTimeSteps() {
        var estimator = CalibrateOnceEstimator(
            config: Config(),
            alignment: .identity(),
            bias: .zero,
            gravityAnchor: Conventions.restSpecificForce)

        let rate = Conventions.rotationRate(pitchRate: 20.0 * .pi / 180)
        let first = IMUSample(time: 10.0, rotationRate: rate,
                              specificForce: Conventions.restSpecificForce)
        XCTAssertFalse(estimator.integrate(first), "no dt exists on the first sample")

        // Backwards in time, and a 5 s jump: both would rotate the attitude by a
        // fabricated amount.
        XCTAssertFalse(estimator.integrate(
            IMUSample(time: 9.5, rotationRate: rate,
                      specificForce: Conventions.restSpecificForce)))
        XCTAssertFalse(estimator.integrate(
            IMUSample(time: 15.0, rotationRate: rate,
                      specificForce: Conventions.restSpecificForce)))
        XCTAssertEqual(estimator.pitch, 0, accuracy: 1e-12)
    }

    // MARK: - Pipeline

    func testPipelineIntegratesPitchAndReportsNoGrade() {
        var pipeline = Pipeline(config: Config(),
                                alignment: .identity(),
                                initialBias: nil,
                                gravityAnchor: Conventions.restSpecificForce)

        var last: PipelineOutput?
        let rate = Conventions.rotationRate(pitchRate: 15.0 * .pi / 180)
        for i in 0...200 {
            let sample = Sample.imu(IMUSample(
                time: Double(i) * 0.01,
                rotationRate: rate,
                specificForce: Conventions.restSpecificForce))
            if let out = pipeline.process(sample) { last = out }
        }

        let output = try! XCTUnwrap(last)
        XCTAssertEqual(output.pitchDegrees, 30.0, accuracy: 0.2)   // 15 deg/s for 2 s
        XCTAssertTrue(pipeline.isAnchored)
    }

    /// GNSS updates speed and nothing else. With no filter there is nothing to fuse
    /// it into, which is why the monotonic-offset timestamp bug is irrelevant here.
    func testGNSSOnlyUpdatesSpeed() {
        var pipeline = Pipeline(config: Config(),
                                alignment: .identity(),
                                initialBias: nil,
                                gravityAnchor: Conventions.restSpecificForce)

        XCTAssertNil(pipeline.process(.gnss(GNSSFix(fixTime: 0.5,
                                                    arrivalTime: 0.5,
                                                    speed: 12.0,
                                                    speedAccuracy: 0.3))),
                     "a GNSS fix produces no output record")

        var last: PipelineOutput?
        for i in 0...50 {
            let sample = Sample.imu(IMUSample(
                time: Double(i) * 0.01,
                rotationRate: .zero,
                specificForce: Conventions.restSpecificForce))
            if let out = pipeline.process(sample) { last = out }
        }
        XCTAssertEqual(try! XCTUnwrap(last).speed, 12.0)
    }

    /// The accelerometer must not reach the live estimate. A sustained 0.3 g thrust
    /// is what makes any accel-trusting fusion converge on the phantom
    /// atan(0.3) = 16.7 deg; here it must change nothing at all.
    func testThrustDoesNotMoveThePitchReading() {
        var pipeline = Pipeline(config: Config(),
                                alignment: .identity(),
                                initialBias: nil,
                                gravityAnchor: Conventions.restSpecificForce)

        var last: PipelineOutput?
        for i in 0...500 {
            // Level, not rotating, but accelerating hard forward for 5 s.
            let sample = Sample.imu(IMUSample(
                time: Double(i) * 0.01,
                rotationRate: .zero,
                specificForce: Conventions.specificForce(pitch: 0,
                                                         forwardAcceleration: 0.3 * Conventions.g)))
            if let out = pipeline.process(sample) { last = out }
        }

        XCTAssertEqual(try! XCTUnwrap(last).pitchDegrees, 0, accuracy: 1e-6,
                       "0.3 g of thrust moved the angle — the accelerometer is "
                       + "reaching the live estimate")
    }

    // MARK: - Calibration hands gravity to the swipe

    /// The join the whole flow depends on: one calibration window produces BOTH the
    /// bias `b` and the gravity anchor, and the swipe consumes the second. If this
    /// breaks, the swipe screen has nothing to solve against and the app has no
    /// alignment at all — there is deliberately no preset to fall back to.
    func testCalibrationProducesGravityWhichTheSwipeConsumes() {
        let bike = UUID()
        var estimator = BiasEstimator(config: Config(), bikeProfileID: bike)

        // Phone lying flat, gravity along device -Z, with a real gyro bias present.
        let trueBias = Vector3(0.001, -0.002, 0.0015)
        let rest = Vector3(0, 0, -Conventions.g)
        var done: BiasEstimate?
        for i in 0...400 {                                  // 4 s at 100 Hz
            let sample = IMUSample(time: Double(i) * 0.01,
                                   rotationRate: trueBias,
                                   specificForce: rest)
            if case .done(let estimate)? = estimator.process(sample) {
                done = estimate
                break
            }
        }

        let estimate = try! XCTUnwrap(done, "2 s of stillness must complete a zeroing")
        XCTAssertEqual(estimate.bias.x, trueBias.x, accuracy: 1e-5)

        let gravity = try! XCTUnwrap(estimate.measuredGravity,
                                     "calibration must produce the gravity anchor, "
                                     + "not just the bias")
        XCTAssertEqual(gravity.z, -Conventions.g, accuracy: 1e-6)

        // Now the swipe: along device +Y, i.e. across the flat phone toward the front.
        let alignment = MountAlignment.fromMeasuredGravity(
            specificForce: gravity,
            screenYaw: .pi / 2,
            bikeProfileID: bike)

        XCTAssertEqual(alignment.swipeConfidence ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(alignment.forwardInBody.y, 1.0, accuracy: 1e-9)

        // And the whole chain reads level: gravity anchor + swipe alignment must put
        // a stationary bike at 0 deg, or the calibration achieved nothing.
        let live = CalibrateOnceEstimator(config: Config(),
                                         alignment: alignment,
                                         bias: estimate.bias,
                                         gravityAnchor: gravity)
        XCTAssertEqual(live.pitch * 180 / .pi, 0, accuracy: 1e-6)
    }

    /// Ported from the deleted `MountAlignmentTests`, which was built around the
    /// two-gesture `AlignmentSolver`. An alignment is persisted per bike profile, so
    /// it has to survive a coding round trip exactly — a lossy one silently changes
    /// which tilt counts as a wheelie on the next launch.
    func testAlignmentRoundTripsThroughCoding() throws {
        let rest = Vector3(0, 0, -Conventions.g)
        let alignment = MountAlignment.fromMeasuredGravity(specificForce: rest,
                                                          screenYaw: .pi / 2,
                                                          bikeProfileID: UUID())
        let data = try JSONEncoder().encode(alignment)
        let decoded = try JSONDecoder().decode(MountAlignment.self, from: data)

        let eps = 1e-12
        XCTAssertEqual(alignment.forwardInBody.x, decoded.forwardInBody.x, accuracy: eps)
        XCTAssertEqual(alignment.forwardInBody.y, decoded.forwardInBody.y, accuracy: eps)
        XCTAssertEqual(alignment.forwardInBody.z, decoded.forwardInBody.z, accuracy: eps)
        XCTAssertEqual(alignment.upInBody.z, decoded.upInBody.z, accuracy: eps)
        XCTAssertEqual(alignment.leftInBody.x, decoded.leftInBody.x, accuracy: eps)
        XCTAssertEqual(alignment.swipeConfidence ?? -1,
                       decoded.swipeConfidence ?? -2, accuracy: eps)
        XCTAssertEqual(alignment.bikeProfileID, decoded.bikeProfileID)
    }

    /// Gravity alone still derives a usable alignment — the path a re-level takes,
    /// where heading is inherited rather than re-measured. Also ported.
    func testGravityOnlyDerivationIsOrthonormalAndRightHanded() {
        let rest = Vector3(0.3, -0.2, -Conventions.g)      // slightly crooked mount
        let a = MountAlignment.fromMeasuredGravity(specificForce: rest)

        XCTAssertEqual(a.forwardInBody.magnitude, 1.0, accuracy: 1e-9)
        XCTAssertEqual(a.upInBody.magnitude, 1.0, accuracy: 1e-9)
        XCTAssertEqual(a.leftInBody.magnitude, 1.0, accuracy: 1e-9)
        XCTAssertEqual(a.forwardInBody.dot(a.upInBody), 0, accuracy: 1e-9)
        XCTAssertEqual(a.forwardInBody.dot(a.leftInBody), 0, accuracy: 1e-9)
        // forward x left == up, per Conventions' right-handedness requirement.
        let cross = a.forwardInBody.cross(a.leftInBody)
        XCTAssertEqual(cross.x, a.upInBody.x, accuracy: 1e-9)
        XCTAssertEqual(cross.y, a.upInBody.y, accuracy: 1e-9)
        XCTAssertEqual(cross.z, a.upInBody.z, accuracy: 1e-9)
    }

    /// There is no preset alignment any more. A calibration that predates gravity
    /// capture reports nil, and the caller must refuse rather than guess.
    func testAnEstimateWithoutGravityCannotBuildAnAlignment() {
        let legacy = BiasEstimate(bias: .zero,
                                  sigma: .zero,
                                  sampleCount: 200,
                                  monotonicTime: 0,
                                  bikeProfileID: UUID())
        XCTAssertNil(legacy.measuredGravity,
                     "an estimate with no gravity must say so rather than defaulting")
    }

    func testAnalyticalPitchUncertaintyComponentsAndInvalidInputs() throws {
        let v = try XCTUnwrap(PitchUncertaintyModel.variance(initialVariance: 0.01,
            biasSigma: 0.02, rateNoisePSD: 0.0004, biasWalkPSD: 0.000003,
            calibrationAgeAtAnchor: 20, elapsed: 10))
        XCTAssertEqual(v, 0.061, accuracy: 1e-12)
        XCTAssertEqual(PitchUncertaintyModel.variance(initialVariance: 0, biasSigma: 0.02,
            rateNoisePSD: 0, biasWalkPSD: 0, calibrationAgeAtAnchor: 0, elapsed: 10)!, 0.04, accuracy: 1e-12)
        XCTAssertNil(PitchUncertaintyModel.variance(initialVariance: 0, biasSigma: -1,
            rateNoisePSD: 0, biasWalkPSD: 0, calibrationAgeAtAnchor: 0, elapsed: 1))
        XCTAssertNil(PitchUncertaintyModel.variance(initialVariance: 0, biasSigma: 1,
            rateNoisePSD: 0, biasWalkPSD: 0, calibrationAgeAtAnchor: 0, elapsed: .infinity))
    }
}
