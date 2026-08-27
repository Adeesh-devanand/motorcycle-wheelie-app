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

    /// Recreated by `start()` — see `MotionService.samples`. A cancelled consumer
    /// terminates an `AsyncStream` permanently, so a restarted session handed the old
    /// stream would receive no fixes and speed would sit at 0 forever.
    public private(set) var fixes: AsyncStream<Sample>

    // MARK: - Private

    private var continuation: AsyncStream<Sample>.Continuation
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
        locationManager.pausesLocationUpdatesAutomatically = false
        // `allowsBackgroundLocationUpdates` is NOT set here. Setting it before
        // authorization is granted throws on current iOS, and it is only legal
        // once the app holds when-in-use (or always) authorization. It is set in
        // `locationManagerDidChangeAuthorization` instead.
    }

    // MARK: - Lifecycle

    public func start() {
        // Fresh stream per session — see MotionService.start().
        continuation.finish()
        var cont: AsyncStream<Sample>.Continuation!
        fixes = AsyncStream { cont = $0 }
        continuation = cont

        // Ask for authorization before starting updates. Without this call the
        // status stays `.notDetermined`, iOS silently delivers NO fixes and no
        // error, and speed reads 0 forever — R19.2 requires the request.
        switch locationManager.authorizationStatus {
        case .notDetermined:
            log.info("Requesting when-in-use location authorization")
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        case .denied, .restricted:
            // R15.3: no location means speed is UNAVAILABLE, never a fabricated 0.
            log.error("Location denied/restricted — speed and distance unavailable")
        @unknown default:
            locationManager.requestWhenInUseAuthorization()
        }
    }

    public func stop() {
        locationManager.stopUpdatingLocation()
        // Deliberately NOT calling `continuation.finish()` — see MotionService.stop().
        // Finishing the once-created stream here would make every later session
        // receive no fixes at all, permanently pinning speed at 0.
        log.info("SpeedService stopped")
    }

    deinit {
        continuation.finish()
    }

    // MARK: - CLLocationManagerDelegate

    /// Authorization is asynchronous: `start()` only asks. Updates begin here,
    /// once the user has actually answered the prompt.
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            log.info("Location authorized — starting updates")
            beginUpdates()
        case .denied, .restricted:
            log.error("Location denied/restricted — speed and distance unavailable")
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    private func beginUpdates() {
        // R19.1: recording must continue with the screen off and the app
        // backgrounded. This property requires only the `location` value in
        // UIBackgroundModes (present in Info.plist) — NOT always-authorization —
        // so when-in-use is enough, which R19.2 calls the minimum. Gating it on
        // `.authorizedAlways` would silently disable background recording for
        // exactly the authorization level the spec targets.
        let status = locationManager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            locationManager.allowsBackgroundLocationUpdates = true
        }
        locationManager.startUpdatingLocation()
        log.info("SpeedService started (bestForNavigation, no distance filter)")
    }

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
