import Foundation

/// Newline-delimited JSON. One header line, then one measurement per line in
/// monotonic time order.
///
/// The log is RAW and unfiltered by contract. Everything downstream is derived
/// and can be recomputed forever from this file. Filter or downsample before
/// writing and you have destroyed the aliasing evidence and your ability to
/// re-tune anything without another ride.
public struct LogHeader: Codable, Sendable {
    public var formatVersion: Int = 1
    public var build: String?
    public var kind: String?
    public var timestampUnit: String?
    public var speedUnit: String?
    public var sessionID: String
    public var startedAt: Date
    public var deviceModel: String
    public var appVersion: String
    /// The exact parameters that produced this log.
    public var config: Config
    /// Free-text notes and manual event tags added during the ride.
    public var notes: String

    public init(sessionID: String = UUID().uuidString,
                startedAt: Date = Date(),
                deviceModel: String = "unknown",
                appVersion: String = "0.0.0",
                config: Config = Config(),
                notes: String = "") {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.config = config
        self.notes = notes
    }
}

public enum LogFile {
    public static func encodeHeader(_ h: LogHeader) throws -> Data {
        var d = try JSONEncoder().encode(h)
        d.append(0x0A)
        return d
    }

    public static func encode(_ m: Sample) throws -> Data {
        var d = try JSONEncoder().encode(m)
        d.append(0x0A)
        return d
    }

    /// Reads a whole log into memory. Fine for a 30 min session (~16 KB/s);
    /// switch to streaming if sessions get long.
    public static func read(contentsOf url: URL) throws -> (LogHeader, [Sample]) {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let headerLine = lines.first else {
            throw NSError(domain: "LogFile", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "empty log"])
        }
        lines.removeFirst()
        let dec = JSONDecoder()
        let header = try dec.decode(LogHeader.self, from: Data(headerLine.utf8))
        let items: [Sample] = try lines.compactMap { line in
            let data = Data(line.utf8)
            if header.formatVersion >= 2,
               let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["kind"] != nil || object["cat"] != nil { return nil }
            return try dec.decode(Sample.self, from: data)
        }
        return (header, items)
    }
}

/// Replays a log through the pipeline. Orders on FIX time, not arrival time,
/// so a run on your desk is identical to the ride that produced it.
public struct ReplaySource: MeasurementSource {
    private var items: [Sample]
    private var index = 0

    public init(samples: [Sample]) {
        self.items = samples.sorted { $0.time < $1.time }
    }

    public mutating func next() -> Sample? {
        guard index < items.count else { return nil }
        defer { index += 1 }
        return items[index]
    }
}


/// Captured atomically before the first sample enters a new live pipeline.
/// Samples before this record belong to calibration and must not be replayed
/// using an invented mount or a calibration estimated from later motion.
public struct RecordingContext: Codable, Sendable {
    public var kind = "pipelineStart"
    public var time: TimeInterval
    public var sessionID: UUID
    public var config: Config
    public var alignment: MountAlignment
    public var initialBias: BiasEstimate?
    public var gravityAnchor: Vector3?
    public var speedEnabled: Bool
    public var angleTarget: [Double]
    public var speedTarget: [Double]
    public var orientationCheckpoint: Pipeline.OrientationCheckpoint?
    public init(time: TimeInterval, sessionID: UUID = UUID(), config: Config,
                alignment: MountAlignment, initialBias: BiasEstimate?,
                gravityAnchor: Vector3?, speedEnabled: Bool,
                angleTarget: [Double] = [], speedTarget: [Double] = [],
                orientationCheckpoint: Pipeline.OrientationCheckpoint? = nil) {
        self.time = time; self.sessionID = sessionID; self.config = config
        self.alignment = alignment; self.initialBias = initialBias
        self.gravityAnchor = gravityAnchor; self.speedEnabled = speedEnabled
        self.angleTarget = angleTarget; self.speedTarget = speedTarget
        self.orientationCheckpoint = orientationCheckpoint
    }
}

public struct RecordingControl: Codable, Sendable {
    public var kind = "pipelineControl"
    public var time: TimeInterval
    public var action: String
    public var speedEnabled: Bool?
    public init(time: TimeInterval, action: String, speedEnabled: Bool? = nil) {
        self.time = time; self.action = action; self.speedEnabled = speedEnabled
    }
}

public struct RecordedOutput: Codable, Sendable {
    public var kind = "pipelineOutput"
    public var output: PipelineOutput
    public init(_ output: PipelineOutput) { self.output = output }
}

/// Delay bounded in seconds, rather than depending on the display's frame rate.
/// This is display-only: never feed it to detection, scoring or raw recording.
public struct ResponsiveDisplayFilter {
    private var value: Double?
    private var lastTime: TimeInterval?
    public init() {}
    public mutating func update(_ target: Double, time: TimeInterval) -> Double {
        guard target.isFinite, time.isFinite else { return value ?? 0 }
        defer { lastTime = time }
        guard let previous = value, let lastTime, time > lastTime,
              time - lastTime < 0.25 else { value = target; return target }
        let dt = time - lastTime
        let tau = abs(target - previous) > 2 ? 0.015 : 0.045
        let alpha = 1 - exp(-dt / tau)
        let next = previous + alpha * (target - previous)
        value = next
        return next
    }
    public mutating func reset() { value = nil; lastTime = nil }
}


/// Reconstruct the live pipeline in recorded arrival order, including reset and
/// speed-control boundaries. Compare ALL recorded output fields, not just pitch.
public enum RecordingAudit {
    public struct Report: Codable {
        public var rawSamples = 0
        public var pipelineStarts = 0
        public var pipelineOutputs = 0
        public var comparedOutputs = 0
        public var mismatchedOutputs = 0
        public var maxPitchErrorDegrees = 0.0
        public var validSpeedFixes = 0
        public var unavailableSpeedFixes = 0
        public var maxSpeedKPH: Double?
        public var endedMidLine = false
        public var closedCleanly = false
        public var incomplete = false
        public var configOverridden = false
    }
    public static func run(url: URL, configOverride: Config? = nil,
                           stagesURL: URL? = nil) throws -> Report {
        var reader = try LogStreamReader(url: url)
        defer { reader.close() }
        guard reader.header.formatVersion >= 2 else {
            throw NSError(domain: "RecordingAudit", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Legacy file lacks live calibration and mount state; exact replay is unavailable."])
        }
        var report = Report()
        report.configOverridden = configOverride != nil
        let decoder = JSONDecoder()
        var pipeline: Pipeline?
        var segmenter: EventSegmenter?
        var speedEnabled = true
        var expected: PipelineOutput?
        var stages: FileHandle?
        if let stagesURL {
            FileManager.default.createFile(atPath: stagesURL.path, contents: nil)
            stages = try FileHandle(forWritingTo: stagesURL)
        }
        defer { try? stages?.close() }
        let encoder = JSONEncoder()
        while let line = try reader.nextRecord() {
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw NSError(domain: "RecordingAudit", code: 2)
            }
            switch object["kind"] as? String {
            case "pipelineStart":
                let context = try decoder.decode(RecordingContext.self, from: line)
                let config = configOverride ?? context.config
                pipeline = Pipeline(config: config, alignment: context.alignment,
                    initialBias: context.initialBias, gravityAnchor: context.gravityAnchor)
                if let checkpoint = context.orientationCheckpoint { pipeline?.restoreOrientation(checkpoint) }
                segmenter = EventSegmenter(config: config)
                speedEnabled = context.speedEnabled
                expected = nil
                report.pipelineStarts += 1
            case "pipelineControl":
                let control = try decoder.decode(RecordingControl.self, from: line)
                if control.action == "stop" {
                    _ = segmenter?.finish(); pipeline = nil; segmenter = nil; expected = nil
                } else if control.action == "speedChanged" {
                    pipeline?.clearSpeed(); speedEnabled = control.speedEnabled ?? true
                } else {
                    throw NSError(domain: "RecordingAudit", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Unknown pipeline control: \(control.action)"])
                }
            case "pipelineOutput":
                let recorded = try decoder.decode(RecordedOutput.self, from: line).output
                report.comparedOutputs += 1
                if let expected {
                    report.maxPitchErrorDegrees = max(report.maxPitchErrorDegrees,
                        abs(recorded.pitch - expected.pitch) * 180 / .pi)
                    let a = try JSONSerialization.jsonObject(with: encoder.encode(recorded))
                    let b = try JSONSerialization.jsonObject(with: encoder.encode(expected))
                    if !equivalent(a, b) { report.mismatchedOutputs += 1 }
                } else { report.mismatchedOutputs += 1 }
                expected = nil
            case "recordingEnd":
                report.closedCleanly = true
                if object["complete"] as? Bool != true { report.incomplete = true }
            case "recordingIncomplete": report.incomplete = true
            case "display", "detectorTransition", "settings": break
            case .some(let kind):
                throw NSError(domain: "RecordingAudit", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported recording record: \(kind)"])
            case .none:
                if object["cat"] != nil {
                    if object["msg"] as? String == "events dropped" {
                        // Coalesced diagnostics are distinct from dropped raw/output records;
                        // the recording footer is authoritative for buffer overflow.
                    }
                    continue
                }
                let sample = try decoder.decode(Sample.self, from: line)
                report.rawSamples += 1
                if case .gnss(let fix) = sample {
                    if fix.isSpeedValid {
                        report.validSpeedFixes += 1
                        report.maxSpeedKPH = max(report.maxSpeedKPH ?? 0, fix.speed * 3.6)
                    } else { report.unavailableSpeedFixes += 1 }
                    if !speedEnabled { continue }
                }
                guard var pipe = pipeline else { continue }
                if segmenter?.state == .idle { pipe.resetQualityFlags() }
                let output = pipe.process(sample)
                pipeline = pipe
                if let output {
                    report.pipelineOutputs += 1
                    expected = output
                    if let stages {
                        var data = try encoder.encode(output); data.append(10)
                        try stages.write(contentsOf: data)
                    }
                    _ = segmenter?.process(time: output.time, pitch: output.pitch,
                        pitchRate: output.pitchRate)
                    pipeline?.eventActive = segmenter?.state == .active || segmenter?.state == .disarming
                }
            }
        }
        report.endedMidLine = reader.endedMidLine
        if reader.endedMidLine || !report.closedCleanly { report.incomplete = true }
        if report.pipelineOutputs != report.comparedOutputs { report.incomplete = true }
        return report
    }

    private static func equivalent(_ a: Any, _ b: Any) -> Bool {
        if let x = a as? [String: Any], let y = b as? [String: Any] {
            return x.keys.count == y.keys.count && x.allSatisfy { key, value in
                guard let other = y[key] else { return false }
                return equivalent(value, other)
            }
        }
        if let x = a as? [Any], let y = b as? [Any] {
            return x.count == y.count && zip(x, y).allSatisfy { equivalent($0.0, $0.1) }
        }
        if let x = a as? NSNumber, let y = b as? NSNumber {
            return abs(x.doubleValue - y.doubleValue) <= 1e-9
        }
        if a is NSNull, b is NSNull { return true }
        return (a as? String) == (b as? String) && a is String && b is String
    }
}


public struct RecordedDisplay: Codable, Sendable {
    public var kind = "display"
    public var time: TimeInterval
    public var sourceTime: TimeInterval
    public var angleDegrees: Double
    public var speedKPH: Double?
    public var filter = "responsive-v1"
    public init(time: TimeInterval, sourceTime: TimeInterval, angleDegrees: Double, speedKPH: Double?) {
        self.time = time; self.sourceTime = sourceTime
        self.angleDegrees = angleDegrees; self.speedKPH = speedKPH
    }
}


public struct RecordedDetection: Codable, Sendable {
    public var kind = "detectorTransition"
    public var time: TimeInterval
    public var transition: String
    public var boundaryTime: TimeInterval?
    public var discardedDuration: TimeInterval?
    public var confidence: String
    public init(time: TimeInterval, transition: EventSegmenter.Transition) {
        self.time = time
        confidence = transition.confidence == .confident ? "confident" : "weak"
        switch transition.kind {
        case .onset(let t): self.transition = "onset"; boundaryTime = t
        case .end(let t): self.transition = "end"; boundaryTime = t
        case .discarded(let duration): self.transition = "discarded"; discardedDuration = duration
        }
    }
}

public struct RecordedSettings: Codable, Sendable {
    public var kind = "settings"
    public var time: TimeInterval
    public var angleTarget: [Double]
    public var speedTarget: [Double]
    public var speedGaugeMaximum: Double
    public var speedEnabled: Bool
    public init(time: TimeInterval, angleTarget: [Double], speedTarget: [Double],
                speedGaugeMaximum: Double, speedEnabled: Bool) {
        self.time = time; self.angleTarget = angleTarget; self.speedTarget = speedTarget
        self.speedGaugeMaximum = speedGaugeMaximum; self.speedEnabled = speedEnabled
    }
}
