import Foundation
import MotoTelemetryCore

// Replays a log (or the synthetic scenario) through the pipeline on the Mac,
// with no simulator and no phone. This is the loop you will live in.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage:
      motolog synth                 run the synthetic scenario
      motolog replay <log.ndjson>   replay a recorded session

    """.utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

let config = Config()

switch command {
case "synth":
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
    let url = URL(fileURLWithPath: args[1])
    let (header, items) = try LogFile.read(contentsOf: url)
    print("session:  \(header.sessionID)")
    print("device:   \(header.deviceModel)")
    print("config:   v\(header.config.version)")
    print("samples:  \(items.count)")

    var source = ReplaySource(measurements: items)
    var gate = ValidityGate(config: header.config)
    var gateOpen = 0
    while let m = source.next() {
        if case .imu(let s) = m, gate.process(s)?.isOpen == true { gateOpen += 1 }
    }
    print("gate-open samples: \(gateOpen)")

default:
    usage()
}
