import Foundation

/// Independent GNSS stop evidence plus half-second IMU means. Comparing individual
/// gyro samples rejects ordinary sensor noise; comparing gravity magnitude alone
/// misses slow lean. Block means and vector spread cover both cases.
struct StationaryWindow {
    struct Correction {
        let bias: Vector3
        let gravity: Vector3
        let meanSigma: Double
    }
    private var startedAt: TimeInterval?
    private var lastTime: TimeInterval?
    private var firstMeanForce: Vector3?
    private var firstMeanRate: Vector3?
    private var count = 0
    private var rateSum = Vector3.zero
    private var rateSquares = Vector3.zero
    private var forceSum = Vector3.zero

    private var blockStartedAt: TimeInterval?
    private var blockCount = 0
    private var blockRate = Vector3.zero
    private var blockForce = Vector3.zero
    private var blockForceSquared = 0.0

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
              (sample.rotationRate - bias).magnitude <= config.gateMaxRotationRate,
              abs(sample.specificForce.magnitude - Conventions.g) <= config.stationaryForceTolerance
        else { reset(); return nil }

        if let previous = lastTime,
           sample.time <= previous || sample.time - previous > min(config.maxSampleGap, 0.1) {
            reset()
        }
        if startedAt == nil { startedAt = sample.time }
        if blockStartedAt == nil { blockStartedAt = sample.time }
        lastTime = sample.time
        count += 1
        blockCount += 1
        let rate = sample.rotationRate
        rateSum = rateSum + rate
        rateSquares = rateSquares + Vector3(rate.x * rate.x, rate.y * rate.y, rate.z * rate.z)
        forceSum = forceSum + sample.specificForce
        blockRate = blockRate + rate
        blockForce = blockForce + sample.specificForce
        blockForceSquared += sample.specificForce.dot(sample.specificForce)

        guard let blockStart = blockStartedAt, sample.time - blockStart >= 0.5 else { return nil }
        let meanForce = blockForce / Double(blockCount)
        let meanRate = blockRate / Double(blockCount)
        let forceSpread = max(0, blockForceSquared / Double(blockCount) - meanForce.dot(meanForce)).squareRoot()
        guard (meanRate - bias).magnitude <= config.stationaryMaxRate,
              forceSpread <= config.stationaryForceStdDev,
              firstMeanForce.map({ (meanForce - $0).magnitude <= config.stationaryForceChange }) ?? true,
              firstMeanRate.map({ (meanRate - $0).magnitude <= config.stationaryGyroChange }) ?? true
        else { reset(); return nil }
        if firstMeanForce == nil { firstMeanForce = meanForce; firstMeanRate = meanRate }
        blockStartedAt = nil; blockCount = 0
        blockRate = .zero; blockForce = .zero; blockForceSquared = 0

        guard let start = startedAt, sample.time - start >= config.stationaryDwell,
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
