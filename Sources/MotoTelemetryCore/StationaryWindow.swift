import Foundation

/// Stop evidence is independent of the estimated angle. No low-angle gate or
/// display-speed zero: either would let an already-drifted estimate certify itself.
struct StationaryWindow {
    struct Correction {
        let bias: Vector3
        let gravity: Vector3
        let meanSigma: Double
    }
    private var first: IMUSample?
    private var lastTime: TimeInterval?
    private var count = 0
    private var rateSum = Vector3.zero
    private var rateSquares = Vector3.zero
    private var forceSum = Vector3.zero

    mutating func reset() { self = StationaryWindow() }

    mutating func process(_ sample: IMUSample, fix: GNSSFix?, bias: Vector3,
                          eventActive: Bool, config: Config) -> Correction? {
        guard !eventActive, !sample.saturated, sample.time.isFinite,
              sample.rotationRate.magnitude.isFinite, sample.specificForce.magnitude.isFinite,
              let fix, fix.fixTime <= sample.time, fix.arrivalTime <= sample.time,
              fix.arrivalTime >= fix.fixTime,
              sample.time - fix.fixTime <= Pipeline.speedFreshnessLimit,
              fix.speed.isFinite, fix.speed >= 0, fix.speed <= config.stationaryMaxSpeed,
              fix.speedAccuracy.isFinite, fix.speedAccuracy >= 0,
              fix.speedAccuracy <= config.stationaryMaxSpeedAccuracy,
              (sample.rotationRate - bias).magnitude <= config.stationaryMaxRate,
              abs(sample.specificForce.magnitude - Conventions.g) <= config.stationaryForceTolerance
        else { reset(); return nil }

        if let previous = lastTime,
           sample.time <= previous || sample.time - previous > min(config.maxSampleGap, 0.1) {
            reset()
        }
        if let first,
           (sample.specificForce - first.specificForce).magnitude > config.stationaryForceChange ||
           (sample.rotationRate - first.rotationRate).magnitude > config.stationaryGyroChange {
            reset()
        }
        if first == nil { first = sample }
        lastTime = sample.time
        count += 1
        rateSum = rateSum + sample.rotationRate
        let rate = sample.rotationRate
        rateSquares = rateSquares + Vector3(rate.x * rate.x, rate.y * rate.y, rate.z * rate.z)
        forceSum = forceSum + sample.specificForce
        guard let first, sample.time - first.time >= config.stationaryDwell,
              count >= max(2, Int(config.stationaryDwell * config.nominalSampleRate * 0.5))
        else { return nil }
        let n = Double(count)
        let mean = rateSum / n
        let variance = rateSquares / n - Vector3(mean.x * mean.x, mean.y * mean.y, mean.z * mean.z)
        let sigma = (max(0, max(variance.x, max(variance.y, variance.z))) / (n - 1)).squareRoot()
        let result = Correction(bias: mean, gravity: forceSum / n, meanSigma: sigma)
        reset()
        return result
    }
}
