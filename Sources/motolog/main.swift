import Foundation
import MotoTelemetryCore

// MARK: - Usage

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage:
      motolog synth                              run the synthetic scenario
      motolog replay <log.ndjson> [options]       replay a recorded session

    replay options:
      --config <file>       override Config from a JSON file
      --stages <out.ndjson> dump per-sample PipelineOutput      --json                output in JSON format

    """.utf8))
    exit(2)
}

// MARK: - Argument parsing

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch command {
case "synth":
    let config = Config()
    var source = SyntheticSource()
    var gate = ValidityGate(config: config)
    var imuCount = 0, gnssCount = 0, gateOpenCount = 0

    while let m = source.next() {
        switch m {
        case .imu(let s):
            imuCount += 1
            if gate.process(s)?.isOpen == true { gateOpenCount += 1 }
        case .gnss:  gnssCount += 1
        case .baro, .wheelSpeed: break
        }
    }
    print("imu samples:       \(imuCount)")
    print("gnss fixes:        \(gnssCount)")
    print("gate-open samples: \(gateOpenCount)")

case "replay":
    guard args.count >= 2 else { usage() }
    let sessionPath = args[1]

    // Parse optional flags
    var configOverridePath: String?
    var stagesOutputPath: String?
    var jsonOutput = false

    var i = 2
    while i < args.count {
        switch args[i] {
        case "--config":
            i += 1
            guard i < args.count else {
                FileHandle.standardError.write(Data("error: --config requires a path\n".utf8))
                exit(1)
            }
            configOverridePath = args[i]
        case "--stages":
            i += 1
            guard i < args.count else {
                FileHandle.standardError.write(Data("error: --stages requires a path\n".utf8))
                exit(1)
            }
            stagesOutputPath = args[i]        case "--json":
            jsonOutput = true
        default:
            FileHandle.standardError.write(Data("error: unknown option '\(args[i])'\n".utf8))
            exit(1)
        }
        i += 1
    }

    // Read session.
    //
    // `StreamingReplaySource` rather than `LogFile.read`, for two reasons that both
    // matter for a replay tool. It reads in chunks instead of materialising the whole
    // trace, and a raw trace is capped at 64 MB. More importantly it TOLERATES a
    // truncated final line, reporting it via `endedMidLine`, where `LogFile.read`
    // throws — and a log truncated mid-line is exactly what a crash or a force-quit
    // produces, i.e. the ride you most want to look at. The two readers disagreed on
    // crash recovery and the CLI was using the unforgiving one.
    //
    // Two passes over the file, because the calibration pre-pass and the replay both
    // start from the beginning and a stream is consumed once. Re-opening is cheaper
    // than holding the trace in memory.
    let url = URL(fileURLWithPath: sessionPath)
    let headerProbe = try StreamingReplaySource(url: url)
    let header = headerProbe.header

    // Determine effective config
    var effectiveConfig = header.config
    if let overridePath = configOverridePath {
        let overrideURL = URL(fileURLWithPath: overridePath)
        let overrideData = try Data(contentsOf: overrideURL)
        effectiveConfig = try JSONDecoder().decode(Config.self, from: overrideData)
    }

    // Print header info
    if !jsonOutput {
        print("session:  \(header.sessionID)")
        print("device:   \(header.deviceModel)")
        print("config:   v\(header.config.version)", terminator: "")
        if configOverridePath != nil {
            print(" (override: v\(effectiveConfig.version))")
        } else {
            print("")
        }
    }

    // Run the full pipeline
    let alignment = MountAlignment.identity()

    // Replay MUST anchor the estimator. `CalibrateOnceEstimator` publishes nothing
    // until a gravity vector fixes the world frame (`Pipeline.processIMU` guards on
    // `isAnchored`), so a pipeline built without one returns nil for every single
    // sample and this tool printed "pipeline samples: 0 / events: 0" on a perfectly
    // good log. It was silent because `gravityAnchor:` is a defaulted parameter —
    // omitting a required step compiled clean. Every test passes it explicitly and
    // the app passes real measured gravity; replay was the one caller that forgot,
    // and no test covers this file.
    //
    // Prefer a real calibration measured from the log's OWN opening samples: that is
    // exactly what the device does, so replay becomes equivalent to live rather than
    // merely similar — which is the entire point of the pipeline being a pure
    // function over a sample stream. Fall back to the first IMU sample's specific
    // force when the log has no clean at-rest window (a log that starts mid-ride),
    // so such a log still replays, with the substitution stated rather than hidden.
    var calibrator = BiasEstimator(config: effectiveConfig,
                                   bikeProfileID: UUID())
    var replayBias: BiasEstimate?
    var firstSpecificForce: Vector3?
    var sampleCount = 0
    var calibrationPass = try StreamingReplaySource(url: url)
    while let sample = calibrationPass.next() {
        sampleCount += 1
        guard case .imu(let imu) = sample else { continue }
        if firstSpecificForce == nil { firstSpecificForce = imu.specificForce }
        if replayBias == nil, case .done(let estimate) = calibrator.process(imu) {
            replayBias = estimate
        }
    }
    if let failure = calibrationPass.failure {
        FileHandle.standardError.write(Data(
            "warning: log decode stopped early: \(failure)\n".utf8))
    }
    if calibrationPass.endedMidLine {
        FileHandle.standardError.write(Data(
            "warning: log ends mid-line — it was truncated, most likely by a crash or force-quit. Replaying what decoded.\n".utf8))
    }

    if !jsonOutput {
        print("samples:  \(sampleCount)")
        print("")
    }

    let anchorSource: String
    let gravityAnchor: Vector3?
    if let measured = replayBias?.measuredGravity {
        gravityAnchor = measured
        anchorSource = "calibrated from the log's opening samples"
    } else if let first = firstSpecificForce {
        gravityAnchor = first
        anchorSource = "FALLBACK: first IMU sample's specific force "
            + "(no clean at-rest window in this log — attitude is relative to "
            + "whatever the bike was doing at t=0)"
    } else {
        gravityAnchor = nil
        anchorSource = "none — no IMU samples in this log"
    }

    if !jsonOutput {
        print("anchor:   \(anchorSource)")
        if let b = replayBias {
            let degPerSec = 180.0 / .pi
            print(String(format: "bias:     %.4f, %.4f, %.4f deg/s",
                         b.bias.x * degPerSec, b.bias.y * degPerSec, b.bias.z * degPerSec))
        }
        print("")
    }

    var pipeline = Pipeline(config: effectiveConfig,
                            alignment: alignment,
                            initialBias: replayBias,
                            gravityAnchor: gravityAnchor)

    var segmenter = EventSegmenter(config: effectiveConfig)
    var scorer = RunScorer(config: effectiveConfig)

    // Upper bound of the in-range angle band used for the interval report below.
    // (There is no `--intervals` flag; intervals are always reported.)
    let angleTargetUpper = effectiveConfig.eventEntryPitch * 2.5

    var source = try StreamingReplaySource(url: url)
    var pipelineOutputs: [PipelineOutput] = []
    var events: [EventMetrics] = []
    var eventActive = false
    var lastSpeed: Double?

    // Stages file handle
    var stagesHandle: FileHandle?
    if let stagesPath = stagesOutputPath {
        FileManager.default.createFile(atPath: stagesPath, contents: nil)
        stagesHandle = FileHandle(forWritingAtPath: stagesPath)
    }
    let stagesEncoder = JSONEncoder()

    while let sample = source.next() {
        // Track GNSS speed for scorer
        if case .gnss(let fix) = sample, fix.isSpeedValid {
            lastSpeed = fix.speed
            if eventActive {
                scorer.addGNSSFix(time: fix.fixTime, speed: fix.speed)
            }
        }

        // Pipeline processing
        pipeline.eventActive = eventActive
        guard let output = pipeline.process(sample) else { continue }
        pipelineOutputs.append(output)

        // Write stages output
        if let handle = stagesHandle {
            var data = try stagesEncoder.encode(output)
            data.append(0x0A)
            handle.write(data)
        }

        // Event segmentation
        let transition = segmenter.process(time: output.time,
                                           pitch: output.pitch,
                                           pitchRate: output.pitchRate)
        if let t = transition {
            switch t.kind {
            case .onset(let onsetTime):
                eventActive = true
                pipeline.eventActive = true
                scorer.beginEvent(onset: onsetTime,
                                  entrySpeed: lastSpeed,
                                  flags: output.flags)
            case .end(let endTime):
                eventActive = false
                pipeline.eventActive = false
                let metrics = scorer.finalise(end: endTime)
                events.append(metrics)
            case .discarded:
                eventActive = false
                pipeline.eventActive = false
            }
        }

        // Feed scorer while event is active
        if eventActive {
            scorer.addSample(time: output.time,
                            pitch: output.pitch,
                            pitchRate: output.pitchRate,
                            roll: output.roll)
        }
    }

    // Close an event still open at the last sample. A log that ends mid-wheelie
    // otherwise loses the event entirely, and the longest holds are the most likely
    // to be cut off — so the loss was biased toward the best runs.
    if let t = segmenter.finish() {
        switch t.kind {
        case .end(let endTime):
            let metrics = scorer.finalise(end: endTime)
            events.append(metrics)
        case .discarded, .onset:
            break
        }
        eventActive = false
    }

    stagesHandle?.closeFile()

    // An empty pipeline is a FAILURE, not a finding. Printing "pipeline samples: 0"
    // as though it were a measurement is what let the missing gravity anchor go
    // unnoticed: the tool reported zero output in the same shape it reports real
    // output, so nothing distinguished "this ride had no wheelies" from "this tool
    // processed nothing at all".
    if pipelineOutputs.isEmpty && sampleCount > 0 {
        FileHandle.standardError.write(Data("""
        error: the pipeline produced no output from \(sampleCount) decoded samples.
               The estimator never anchored, so every sample was dropped. Check that
               the log contains .imu records with a usable specificForce.

        """.utf8))
        exit(2)
    }

    // Compute session summary
    let summary = SessionSummary(events: events)

    // Interval detection
    let angleSeries = pipelineOutputs.map { (time: $0.time, value: $0.pitch) }
    let intervalDetector = IntervalDetector(
        range: effectiveConfig.eventExitPitch...angleTargetUpper,
        minDuration: effectiveConfig.intervalMinDuration,
        mergeGap: effectiveConfig.intervalMergeGap
    )
    let intervals = intervalDetector.intervals(over: angleSeries)

    // Output
    if jsonOutput {
        printJSON(header: header, config: effectiveConfig,
                  configOverride: configOverridePath != nil,
                  summary: summary, events: events,
                  intervals: intervals,
                  totalSamples: pipelineOutputs.count)
    } else {
        printText(summary: summary, events: events,
                  intervals: intervals,
                  totalSamples: pipelineOutputs.count)
    }

default:
    usage()
}

// MARK: - Text output

func printText(summary: SessionSummary,
               events: [EventMetrics],
               intervals: [IntervalDetector.Interval],
               totalSamples: Int) {
    print("─── Session Summary ───")
    print("  pipeline samples: \(totalSamples)")
    print("  events:           \(summary.eventCount)")
    print("  cumulative hold:  \(String(format: "%.2f", summary.cumulativeHoldTime)) s")

    if let best = summary.bestMaxAngle {
        print("  best max angle:   \(String(format: "%.1f", best.liveMaxAngle * 180 / .pi))°")
    }
    if let best = summary.bestDuration {
        print("  best duration:    \(String(format: "%.2f", best.duration)) s")
    }
    if let best = summary.bestDistance, let d = best.distance {
        print("  best distance:    \(String(format: "%.1f", d)) m")
    }
    if let best = summary.bestConsistency {
        print("  best consistency: \(String(format: "%.3f", best.angleStdDev * 180 / .pi))° σ")
    }

    if !intervals.isEmpty {
        let totalInRange = intervals.reduce(0.0) { $0 + $1.duration }
        print("  in-range time:    \(String(format: "%.2f", totalInRange)) s (\(intervals.count) intervals)")
    }

    if !events.isEmpty {
        print("")
        print("─── Per-Event Metrics ───")
        for (idx, e) in events.enumerated() {
            print("  event \(idx + 1):")
            print("    onset:          \(String(format: "%.3f", e.onset)) s")
            print("    end:            \(String(format: "%.3f", e.end)) s")
            print("    duration:       \(String(format: "%.3f", e.duration)) s")
            print("    max angle live: \(String(format: "%.1f", e.liveMaxAngle * 180 / .pi))°")
            print("    avg held angle: \(String(format: "%.1f", e.averageHeldAngle * 180 / .pi))°")
            print("    angleStdDev:    \(String(format: "%.3f", e.angleStdDev * 180 / .pi))°")
            if let d = e.distance {
                print("    distance:       \(String(format: "%.1f", d)) m")
            }
            if let s = e.entrySpeed {
                print("    entry speed:    \(String(format: "%.1f", s)) m/s")
            }
            print("    hold window:    \(e.holdWindowResolved ? "resolved" : "heuristic")")
        }
    }
}

// MARK: - JSON output

struct ReplayOutput: Codable {
    struct HeaderInfo: Codable {
        var sessionID: String
        var deviceModel: String
        var headerConfigVersion: Int
        var effectiveConfigVersion: Int
        var configOverridden: Bool
        var sampleCount: Int
    }

    struct SummaryInfo: Codable {
        var eventCount: Int
        var cumulativeHoldTime: Double
        var bestMaxAngleDeg: Double?
        var bestDuration: Double?
        var bestDistanceMeters: Double?
        var bestConsistencyDeg: Double?
        var pipelineSamples: Int
    }

    struct EventInfo: Codable {
        var index: Int
        var onset: Double
        var end: Double
        var duration: Double
        var maxAngleLiveDeg: Double
        var avgHeldAngleDeg: Double
        var angleStdDevDeg: Double
        var distanceMeters: Double?
        var entrySpeedMps: Double?
        var holdWindowResolved: Bool
    }

    struct IntervalInfo: Codable {
        var start: Double
        var end: Double
        var duration: Double
    }

    var header: HeaderInfo
    var summary: SummaryInfo
    var events: [EventInfo]
    var intervals: [IntervalInfo]
}

func printJSON(header: LogHeader, config: Config,
               configOverride: Bool,
               summary: SessionSummary, events: [EventMetrics],
               intervals: [IntervalDetector.Interval],
               totalSamples: Int) {
    let output = ReplayOutput(
        header: .init(
            sessionID: header.sessionID,
            deviceModel: header.deviceModel,
            headerConfigVersion: header.config.version,
            effectiveConfigVersion: config.version,
            configOverridden: configOverride,
            sampleCount: totalSamples
        ),
        summary: .init(
            eventCount: summary.eventCount,
            cumulativeHoldTime: summary.cumulativeHoldTime,
            bestMaxAngleDeg: summary.bestMaxAngle.map { $0.liveMaxAngle * 180 / .pi },
            bestDuration: summary.bestDuration?.duration,
            bestDistanceMeters: summary.bestDistance?.distance,
            bestConsistencyDeg: summary.bestConsistency.map { $0.angleStdDev * 180 / .pi },
            pipelineSamples: totalSamples
        ),
        events: events.enumerated().map { idx, e in
            .init(
                index: idx + 1,
                onset: e.onset,
                end: e.end,
                duration: e.duration,
                maxAngleLiveDeg: e.liveMaxAngle * 180 / .pi,
                avgHeldAngleDeg: e.averageHeldAngle * 180 / .pi,
                angleStdDevDeg: e.angleStdDev * 180 / .pi,
                distanceMeters: e.distance,
                entrySpeedMps: e.entrySpeed,
                holdWindowResolved: e.holdWindowResolved
            )
        },
        intervals: intervals.map { .init(start: $0.start, end: $0.end, duration: $0.duration) }
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(output),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}
