import CoreLocation
import Foundation
import MotoTelemetryCore
import os

// MARK: - Protocol

/// Delivers a stream of `Sample.gnss` from CoreLocation.
public protocol SpeedProviding: Sendable {
    var fixes: AsyncStream<Sample> { get }
    func start()
    func stop()
}

// MARK: - Implementation

/// Wraps CLLocationManager in `.bestForNavigation` mode and emits `GNSSFix`
/// samples with both fix-time (when the satellite measurement was taken) and
/// arrival-time (when CoreLocation delivered it), so downstream can measure and
/// compensate for GNSS latency.
public final class SpeedService: NSObject, CLLocationManagerDelegate,
                                  SpeedProviding, @unchecked Sendable {

    // MARK: - Public

    public let fixes: AsyncStream<Sample>

    // MARK: - Private

    private let continuation: AsyncStream<Sample>.Continuation
    private let locationManager = CLLocationManager()
    private let log = Logger(subsystem: "com.mototelemetry.app", category: "SpeedService")

    /// Reference date for converting CLLocation.timestamp (wall clock) to the
    /// monotonic ProcessInfo.systemUptime domain used throughout the pipeline.
    /// Set on the first fix: `monotonicOffset = systemUptime - location.timestamp`.
    private var monotonicOffset: TimeInterval?

    // MARK: - Init

    public override init() {
        var cont: AsyncStream<Sample>.Continuation!
        self.fixes = AsyncStream { cont = $0 }
        self.continuation = cont
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    // MARK: - Lifecycle

    public func start() {
        locationManager.startUpdatingLocation()
        log.info("SpeedService started (bestForNavigation, no distance filter)")
    }

    public func stop() {
        locationManager.stopUpdatingLocation()
        continuation.finish()
        log.info("SpeedService stopped")
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManager(_ manager: CLLocationManager,
                                didUpdateLocations locations: [CLLocation]) {
        let arrivalTime = ProcessInfo.processInfo.systemUptime

        for location in locations {
            // Establish monotonic offset on first fix
            if monotonicOffset == nil {
                monotonicOffset = arrivalTime - location.timestamp.timeIntervalSinceReferenceDate
            }

            let fixTime = location.timestamp.timeIntervalSinceReferenceDate
                + (monotonicOffset ?? 0)

            let fix = GNSSFix(
                fixTime: fixTime,
                arrivalTime: arrivalTime,
                speed: location.speed,
                speedAccuracy: location.speedAccuracy,
                course: location.course,
                courseAccuracy: location.courseAccuracy,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitude: location.altitude,
                horizontalAccuracy: location.horizontalAccuracy
            )

            continuation.yield(.gnss(fix))
        }
    }

    public func locationManager(_ manager: CLLocationManager,
                                didFailWithError error: Error) {
        log.error("CLLocationManager error: \(error.localizedDescription)")
    }
}
