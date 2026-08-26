import Foundation

// MARK: - Overlapping Allan Deviation

/// Computes overlapping Allan deviation (ADEV) from a rate series (gyro or accel).
///
/// The overlapping estimator uses ALL possible cluster averages of length m,
/// not just non-overlapping blocks. This gives better confidence at long tau
/// from a finite data set. The formula implemented:
///
///   ADEV^2(tau) = 1 / (2 * tau^2 * (N - 2m))
///                * SUM_{j=0}^{N-2m-1} [ x(j+2m) - 2*x(j+m) + x(j) ]^2
///
/// where x(j) = cumulative sum of the rate series (i.e. integrated angle in rad),
/// tau = m * tau0, tau0 = 1/sampleRate, and N is the number of PHASE points
/// (one more than the number of rate samples). The sum has (N-2m) terms because
/// x is indexed 0..N-1 and j+2m must not exceed N-1.
///
/// Reference: IEEE Std 1139-2008, eq (10).
///
/// Why overlapping rather than non-overlapping: non-overlapping ADEV uses N/m
/// clusters and becomes noisy at large m. Overlapping uses (N-2m+1) second-
/// differences and is strictly more efficient for the same data length, which
/// matters because bench sessions are expensive to collect.
public struct AllanDeviation {

    /// One point on the tau-domain ADEV curve.
    public struct Point: Sendable {
        public let tau: Double       // averaging time (seconds)
        public let adev: Double      // Allan deviation at this tau (same units as input rate)
    }

    /// Result of a full Allan deviation analysis on a gyro rate axis.
    public struct GyroResult: Sendable {
        /// Angle random walk in rad/s/sqrt(Hz).
        /// Read off the -1/2 slope at tau = 1 s: ARW = ADEV(tau=1) / sqrt(1).
        /// In the white-noise regime ADEV(tau) = sigma / sqrt(tau), so at tau=1
        /// the ADEV value IS the noise density in rad/s/sqrt(Hz).
        public let gyroNoiseDensity: Double

        /// Bias instability in rad/s.
        /// Read as the minimum of the ADEV curve divided by 0.664 (the conversion
        /// factor from the flicker-floor ADEV minimum to the underlying BI).
        public let gyroBiasInstability: Double

        /// The full tau-domain curve so the caller can judge whether the recording
        /// was long enough (the curve should show the -1/2 slope for at least a
        /// decade before flattening).
        public let curve: [Point]
    }

    /// Result of a full Allan deviation analysis on an accelerometer rate axis.
    public struct AccelResult: Sendable {
        /// Velocity random walk (noise density) in m/s^2/sqrt(Hz).
        public let accelNoiseDensity: Double

        /// The full tau-domain curve.
        public let curve: [Point]
    }

    // MARK: - Computation

    /// Compute the overlapping Allan deviation curve for a rate series.
    ///
    /// - Parameters:
    ///   - rates: the rate samples (rad/s for gyro, m/s^2 for accel), equally spaced.
    ///   - tau0: sample interval in seconds (1/sampleRate).
    ///   - maxOctave: maximum number of octave doublings for tau. If nil, uses
    ///     the largest m where (N - 2m + 1) >= 1.
    /// - Returns: Array of (tau, adev) points, one per octave of averaging time.
    ///
    /// The tau values are octave-spaced (m = 1, 2, 4, 8, ...) because that gives
    /// even log-spacing on the ADEV plot and keeps computation O(N * log(N/2)).
    public static func compute(rates: [Double], tau0: Double, maxOctave: Int? = nil) -> [Point] {
        let N = rates.count + 1  // number of phase points
        guard N >= 3 else { return [] }

        // Build cumulative phase (integrated rate) from the rate series.
        // x[0] = 0, x[j] = x[j-1] + rate[j-1] * tau0
        var x = [Double](repeating: 0, count: N)
        for j in 1..<N {
            x[j] = x[j - 1] + rates[j - 1] * tau0
        }

        var points: [Point] = []
        var m = 1
        while 2 * m < N {
            // j ranges from 0 to (N - 2m - 1) because x[j + 2m] must be valid.
            // x has N elements indexed 0..(N-1), so j + 2m <= N-1, i.e. j <= N-2m-1.
            // Number of valid second-differences: N - 2*m.
            let terms = N - 2 * m
            guard terms >= 1 else { break }

            let tau = Double(m) * tau0
            var sum = 0.0
            for j in 0..<terms {
                let diff = x[j + 2 * m] - 2 * x[j + m] + x[j]
                sum += diff * diff
            }

            let adev2 = sum / (2.0 * tau * tau * Double(terms))
            let adev = adev2.squareRoot()
            points.append(Point(tau: tau, adev: adev))

            if let maxOct = maxOctave, points.count >= maxOct { break }
            m *= 2
        }

        return points
    }

    /// Analyse a gyro rate axis (rad/s) and extract ARW and bias instability.
    ///
    /// - Parameters:
    ///   - rates: gyro rate samples in rad/s from a stationary bench session.
    ///   - sampleRate: sampling rate in Hz.
    /// - Returns: A `GyroResult` with noise density and bias instability.
    public static func analyseGyro(rates: [Double], sampleRate: Double) -> GyroResult {
        let tau0 = 1.0 / sampleRate
        let curve = compute(rates: rates, tau0: tau0)

        // ARW: ADEV at tau=1s. If we don't have exactly tau=1, interpolate in log-log.
        let arw = interpolateLogLog(curve: curve, targetTau: 1.0) ?? (curve.first?.adev ?? 0)

        // Bias instability: minimum of the curve / 0.664
        // The 0.664 factor converts the ADEV flicker-floor minimum to the
        // underlying rate random walk (bias instability) coefficient.
        let minAdev = curve.map(\.adev).min() ?? 0
        let biasInstability = minAdev / 0.664

        return GyroResult(
            gyroNoiseDensity: arw,
            gyroBiasInstability: biasInstability,
            curve: curve
        )
    }

    /// Analyse an accelerometer axis (m/s^2) and extract velocity random walk.
    ///
    /// - Parameters:
    ///   - rates: accelerometer samples in m/s^2 from a stationary bench session.
    ///   - sampleRate: sampling rate in Hz.
    /// - Returns: An `AccelResult` with noise density.
    public static func analyseAccel(rates: [Double], sampleRate: Double) -> AccelResult {
        let tau0 = 1.0 / sampleRate
        let curve = compute(rates: rates, tau0: tau0)
        let noiseDensity = interpolateLogLog(curve: curve, targetTau: 1.0) ?? (curve.first?.adev ?? 0)
        return AccelResult(accelNoiseDensity: noiseDensity, curve: curve)
    }

    /// Format the analysis results as Config field strings ready to paste.
    public static func formatAsConfig(gyroY: GyroResult, accelZ: AccelResult) -> String {
        // The Config stores:
        //   gyroNoiseDensity     in rad/s/sqrt(Hz)
        //   gyroBiasInstability  in rad/s
        //   accelNoiseDensity    in m/s^2/sqrt(Hz)
        let lines = [
            "gyroNoiseDensity     = \(gyroY.gyroNoiseDensity)    // rad/s/sqrt(Hz)",
            "gyroBiasInstability  = \(gyroY.gyroBiasInstability)    // rad/s",
            "accelNoiseDensity    = \(accelZ.accelNoiseDensity)    // m/s^2/sqrt(Hz)",
        ]
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Log-log interpolation to find ADEV at an arbitrary tau from octave-spaced points.
    /// Returns nil if the curve is empty or targetTau is out of range.
    private static func interpolateLogLog(curve: [Point], targetTau: Double) -> Double? {
        guard !curve.isEmpty else { return nil }

        // If targetTau matches a point exactly (or is below the first), return directly.
        if targetTau <= curve[0].tau { return curve[0].adev }
        if targetTau >= curve[curve.count - 1].tau { return curve[curve.count - 1].adev }

        // Find the bracketing pair.
        for i in 0..<(curve.count - 1) {
            if curve[i].tau <= targetTau && curve[i + 1].tau >= targetTau {
                let logTau0 = Foundation.log(curve[i].tau)
                let logTau1 = Foundation.log(curve[i + 1].tau)
                let logAdev0 = Foundation.log(curve[i].adev)
                let logAdev1 = Foundation.log(curve[i + 1].adev)
                let t = (Foundation.log(targetTau) - logTau0) / (logTau1 - logTau0)
                let logResult = logAdev0 + t * (logAdev1 - logAdev0)
                return Foundation.exp(logResult)
            }
        }
        return nil
    }

    /// Fit a line in log-log space to a subset of the curve and return the slope.
    /// Used to verify the -1/2 slope in the white-noise regime.
    ///
    /// - Parameters:
    ///   - curve: the ADEV points.
    ///   - tauRange: closed range of tau values to include in the fit.
    /// - Returns: The slope of the best-fit line in log(tau) vs log(adev) space,
    ///   or nil if fewer than 2 points fall in the range.
    public static func fitLogLogSlope(curve: [Point], tauRange: ClosedRange<Double>) -> Double? {
        let pts = curve.filter { tauRange.contains($0.tau) }
        guard pts.count >= 2 else { return nil }

        // Simple least-squares linear regression in log-log space.
        let n = Double(pts.count)
        var sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumXY = 0.0
        for p in pts {
            let lx = Foundation.log(p.tau)
            let ly = Foundation.log(p.adev)
            sumX += lx
            sumY += ly
            sumXX += lx * lx
            sumXY += lx * ly
        }
        let denom = n * sumXX - sumX * sumX
        guard denom.magnitude > 1e-30 else { return nil }
        return (n * sumXY - sumX * sumY) / denom
    }
}
