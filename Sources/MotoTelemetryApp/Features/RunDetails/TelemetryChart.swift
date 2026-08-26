import Charts
import MotoTelemetryCore
import SwiftUI

/// §9.4 — Swift Charts view: LineMark+AreaMark for angle/speed over time,
/// target band as RectangleMark, in-range color segments. X-axis is mm:ss elapsed.
struct TelemetryChart: View {
    let points: [Downsample.Point]
    let rawSamples: [TelemetrySample]
    let targetBand: MetricRange
    let metric: MetricKind
    let yDomain: ClosedRange<Double>
    let runDuration: TimeInterval
    @Binding var selectedTime: TimeInterval?

    /// Colour for the line trace.
    private var traceColor: Color {
        metric == .angle
            ? Color(hex: 0x10B9B7)
            : Color(hex: 0x238CD8)
    }

    private var bandFillColor: Color {
        metric == .angle
            ? Color(hex: 0x10B9B7).opacity(0.12)
            : Color(hex: 0x238CD8).opacity(0.12)
    }

    private var bandStrokeColor: Color {
        metric == .angle
            ? Color(hex: 0x10B9B7).opacity(0.45)
            : Color(hex: 0x238CD8).opacity(0.45)
    }

    private var maxValue: Double {
        metric == .angle
            ? rawSamples.map(\.angleDegrees).max() ?? 0
            : rawSamples.map(\.speedKPH).max() ?? 0
    }

    private var maxTime: TimeInterval? {
        if metric == .angle {
            return rawSamples.max(by: { $0.angleDegrees < $1.angleDegrees })?.elapsed
        } else {
            return rawSamples.max(by: { $0.speedKPH < $1.speedKPH })?.elapsed
        }
    }

    var body: some View {
        Chart {
            // Target band
            RectangleMark(
                xStart: .value("Start", 0),
                xEnd: .value("End", runDuration),
                yStart: .value("Lower", targetBand.lower),
                yEnd: .value("Upper", targetBand.upper)
            )
            .foregroundStyle(bandFillColor)

            // Trace line + area
            ForEach(Array(points.enumerated()), id: \.offset) { _, pt in
                LineMark(
                    x: .value("Time", pt.x),
                    y: .value("Value", pt.y)
                )
                .foregroundStyle(traceColor)

                AreaMark(
                    x: .value("Time", pt.x),
                    y: .value("Value", pt.y)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [traceColor.opacity(0.3), traceColor.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            // Max marker
            if let maxT = maxTime {
                PointMark(
                    x: .value("Time", maxT),
                    y: .value("Value", maxValue)
                )
                .foregroundStyle(Color(hex: 0x32E85B))
                .symbolSize(36)
                .annotation(position: .top) {
                    Text(metric == .angle
                         ? "\(String(format: "%.0f", maxValue))°"
                         : "\(String(format: "%.0f", maxValue))")
                    .font(.system(.caption2, design: .monospaced, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x32E85B))
                }
            }

            // Scrubber rule
            if let time = selectedTime {
                RuleMark(x: .value("Scrubber", time))
                    .foregroundStyle(AppColors.textPrimary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
            }
        }
        .chartXScale(domain: 0...runDuration)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                AxisValueLabel {
                    if let t = value.as(Double.self) {
                        Text(formatElapsed(t))
                            .font(.system(.caption2, design: .monospaced))
                    }
                }
                AxisGridLine()
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(metric == .angle ? "\(Int(v))°" : "\(Int(v))")
                            .font(.system(.caption2, design: .monospaced))
                    }
                }
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if let time: TimeInterval = proxy.value(atX: value.location.x) {
                                    selectedTime = max(0, min(runDuration, time))
                                }
                            }
                    )
                    .onTapGesture { location in
                        if let time: TimeInterval = proxy.value(atX: location.x) {
                            selectedTime = max(0, min(runDuration, time))
                        }
                    }
            }
        }
        .frame(height: 180)
        .accessibilityLabel("\(metric == .angle ? "Angle" : "Speed") chart")
        .accessibilityHint("Drag horizontally to scrub through time")
    }

    private func formatElapsed(_ t: Double) -> String {
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
