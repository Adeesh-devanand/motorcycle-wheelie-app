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
      --stages <out.ndjson> dump per-sample PipelineOutput
      --cues                print cue timeline
      --json                output in JSON format

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
    var showCues = false
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
            stagesOutputPath = args[i]
        case "--cues":
            showCues = true
        case "--json":
            jsonOutput = true
        default:
            FileHandle.standardError.write(Data("error: unknown option '\(args[i])'\n".utf8))
            exit(1)
        }
        i += 1
    }

    // Read session
    let url = URL(fileURLWithPath: sessionPath)
    let (header, items) = try LogFile.read(contentsOf: url)

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
        print("samples:  \(items.count)")
        print("")
    }

    // Run the full pipeline
    let alignment = MountAlignment.identity()
    var pipeline = Pipeline(config: effectiveConfig,
                            alignment: alignment,
                            initialBias: nil)

    var segmenter = EventSegmenter(config: effectiveConfig)
    var scorer = RunScorer(config: effectiveConfig)

    // CueEngine: use eventEntryPitch * 2.5 as default angle target upper bound (~25 deg)
    let angleTargetUpper = effectiveConfig.eventEntryPitch * 2.5
    var cueEngine = CueEngine(
        angleTargetUpper: angleTargetUpper,
        timeToThresholdWarn: effectiveConfig.timeToThresholdWarn,
        audioLatencyCompensation: effectiveConfig.audioLatencyCompensation,
        loopOutPitchRate: effectiveConfig.loopOutPitchRate,
        cueReleaseTime: effectiveConfig.cueReleaseTime
    )

    var source = ReplaySource(samples: items)
    var pipelineOutputs: [PipelineOutput] = []
    var events: [EventMetrics] = []
    var cueTimeline: [(time: TimeInterval, cue: CueState)] = []
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
                pipeline.lastEventEndTime = endTime
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

        // Cue engine
        let cue = cueEngine.process(pitch: output.pitch,
                                    pitchRate: output.pitchRate,
                                    time: output.time)
        if showCues && cue.tone != .silent {
            cueTimeline.append((time: output.time, cue: cue))
        }
    }

    stagesHandle?.closeFile()

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
                  cueTimeline: showCues ? cueTimeline : nil,
                  intervals: intervals,
                  totalSamples: pipelineOutputs.count)
    } else {
        printText(summary: summary, events: events,
                  cueTimeline: showCues ? cueTimeline : nil,
                  intervals: intervals,
                  totalSamples: pipelineOutputs.count)
    }

default:
    usage()
}

// MARK: - Text output

func printText(summary: SessionSummary,
               events: [EventMetrics],
               cueTimeline: [(time: TimeInterval, cue: CueState)]?,
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

    if let timeline = cueTimeline, !timeline.isEmpty {
        print("")
        print("─── Cue Timeline ───")
        for entry in timeline {
            let tttStr: String
            if let ttt = entry.cue.timeToThreshold {
                tttStr = String(format: "ttt=%.3fs", ttt)
            } else {
                tttStr = "ttt=nil"
            }
            print("  \(String(format: "%8.3f", entry.time))s  \(entry.cue.tone.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))  urgency=\(String(format: "%.2f", entry.cue.urgency))  \(tttStr)")
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

    struct CueEntry: Codable {
        var time: Double
        var tone: String
        var urgency: Double
        var timeToThreshold: Double?
    }

    struct IntervalInfo: Codable {
        var start: Double
        var end: Double
        var duration: Double
    }

    var header: HeaderInfo
    var summary: SummaryInfo
    var events: [EventInfo]
    var cueTimeline: [CueEntry]?
    var intervals: [IntervalInfo]
}

func printJSON(header: LogHeader, config: Config,
               configOverride: Bool,
               summary: SessionSummary, events: [EventMetrics],
               cueTimeline: [(time: TimeInterval, cue: CueState)]?,
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
        cueTimeline: cueTimeline?.map { entry in
            .init(
                time: entry.time,
                tone: entry.cue.tone.rawValue,
                urgency: entry.cue.urgency,
                timeToThreshold: entry.cue.timeToThreshold
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
