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

    // MARK: - Diagnostics ("sensor")

    private var diag = DiagnosticEmitter(sink: DiagnosticLog.shared, category: "sensor")
    private var fixCount = 0
    private var sawFirstFix = false
    private var firstFixTime: TimeInterval?
    private var streamGeneration = 0

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
        let now = ProcessInfo.processInfo.systemUptime
        diag.always(time: now, level: .info, message: "stream finished (start: replacing old)",
                    values: ["generation": Double(streamGeneration), "streamEnded": 1])
        continuation.finish()
        var cont: AsyncStream<Sample>.Continuation!
        fixes = AsyncStream { cont = $0 }
        continuation = cont
        streamGeneration += 1
        sawFirstFix = false
        fixCount = 0
        firstFixTime = nil
        diag.always(time: now, level: .info, message: "speed stream created (start)",
                    values: ["generation": Double(streamGeneration),
                             "authStatus": Double(locationManager.authorizationStatus.rawValue)])

        // Ask for authorization before starting updates. Without this call the
        // status stays `.notDetermined`, iOS silently delivers NO fixes and no
        // error, and speed reads 0 forever — R19.2 requires the request.
        switch locationManager.authorizationStatus {
        case .notDetermined:
            log.info("Requesting when-in-use location authorization")
            diag.always(time: now, level: .info, message: "requesting location authorization",
                        values: ["authStatus": Double(locationManager.authorizationStatus.rawValue)])
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        case .denied, .restricted:
            // R15.3: no location means speed is UNAVAILABLE, never a fabricated 0.
            log.error("Location denied/restricted — speed and distance unavailable")
            diag.always(time: now, level: .error, message: "location denied/restricted — speed unavailable",
                        values: ["authStatus": Double(locationManager.authorizationStatus.rawValue)])
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
        diag.always(time: ProcessInfo.processInfo.systemUptime, level: .info,
                    message: "stopped (stream NOT finished — still live)",
                    values: ["streamEnded": 0,
                             "generation": Double(streamGeneration), "fixes": Double(fixCount)])
    }

    deinit {
        continuation.finish()
    }

    // MARK: - CLLocationManagerDelegate

    /// Authorization is asynchronous: `start()` only asks. Updates begin here,
    /// once the user has actually answered the prompt.
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let now = ProcessInfo.processInfo.systemUptime
        diag.always(time: now, level: .info, message: "authorization changed",
                    values: ["authStatus": Double(manager.authorizationStatus.rawValue)])
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            log.info("Location authorized — starting updates")
            beginUpdates()
        case .denied, .restricted:
            log.error("Location denied/restricted — speed and distance unavailable")
            diag.always(time: now, level: .error, message: "location denied/restricted — speed unavailable",
                        values: ["authStatus": Double(manager.authorizationStatus.rawValue)])
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
        diag.always(time: ProcessInfo.processInfo.systemUptime, level: .info,
                    message: "speed updates started",
                    values: ["authStatus": Double(status.rawValue),
                             "background": locationManager.allowsBackgroundLocationUpdates ? 1 : 0])
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

            // Diagnostics on the fix's monotonic (systemUptime-domain) time, so speed
            // lines interleave with sensor lines. 1 Hz heartbeat carries live speed.
            fixCount += 1
            if !sawFirstFix {
                sawFirstFix = true
                diag.always(time: fixTime, level: .info, message: "first GNSS fix",
                            values: ["generation": Double(streamGeneration),
                                     "speed": fix.speed, "speedAcc": fix.speedAccuracy])
            }
            if firstFixTime == nil { firstFixTime = fixTime }
            diag.emit("live", time: fixTime, level: .info, message: "speed heartbeat",
                      values: ["speed": fix.speed, "speedAcc": fix.speedAccuracy,
                               "count": Double(fixCount),
                               "hAcc": fix.horizontalAccuracy])
        }
    }

    public func locationManager(_ manager: CLLocationManager,
                                didFailWithError error: Error) {
        log.error("CLLocationManager error: \(error.localizedDescription)")
        diag.always(time: ProcessInfo.processInfo.systemUptime, level: .error,
                    message: "CLLocationManager error",
                    values: ["code": Double((error as NSError).code)])
    }
}
