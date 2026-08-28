import Charts
import MotoTelemetryCore
import SwiftUI

/// §9.4 — Swift Charts view: smooth LineMark for angle/speed over time,
/// target band as RectangleMark, max marker, scrubber with value dots.
struct TelemetryChart: View {
    let points: [Downsample.Point]
    let rawSamples: [TelemetrySample]
    let targetBand: MetricRange
    let metric: MetricKind
    let yDomain: ClosedRange<Double>
    let runDuration: TimeInterval
    @Binding var selectedTime: TimeInterval?

    // MARK: - Derived colours from AppColors tokens

    private var traceColor: Color {
        metric == .angle ? AppColors.angleMetric : AppColors.speedMetric
    }

    private var bandFillColor: Color {
        metric == .angle ? AppColors.targetBandChartAngle : AppColors.targetBandChartSpeed
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

    /// Interpolate value at a given time from raw samples.
    private func valueAt(_ time: TimeInterval) -> Double {
        guard rawSamples.count >= 2 else {
            let s = rawSamples.first
            return metric == .angle ? (s?.angleDegrees ?? 0) : (s?.speedKPH ?? 0)
        }
        var lo = 0
        var hi = rawSamples.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if rawSamples[mid].elapsed <= time { lo = mid } else { hi = mid }
        }
        let a = rawSamples[lo]
        let b = rawSamples[hi]
        guard b.elapsed != a.elapsed else {
            return metric == .angle ? a.angleDegrees : a.speedKPH
        }
        let u = max(0, min(1, (time - a.elapsed) / (b.elapsed - a.elapsed)))
        if metric == .angle {
            return a.angleDegrees + u * (b.angleDegrees - a.angleDegrees)
        } else {
            return a.speedKPH + u * (b.speedKPH - a.speedKPH)
        }
    }

    // MARK: - X-axis tick values

    private var xAxisStride: Double {
        switch runDuration {
        case ..<2:  return 0.5
        case ..<5:  return 1
        case ..<10: return 2
        case ..<30: return 5
        default:    return 10
        }
    }

    private var xAxisValues: [Double] {
        guard runDuration > 0 else { return [0] }
        // One tick per whole second with no stride produced a label for every second
        // of the domain — unreadable overprinting on a narrow chart. The trailing
        // exact-end tick made it worse by landing arbitrarily close to the last whole
        // second (e.g. "5s" beside "5.4s"). A duration-scaled stride keeps this to
        // roughly 4-6 evenly spaced labels at any attempt length.
        let step = xAxisStride
        var ticks: [Double] = []
        var t = 0.0
        while t <= runDuration + 1e-9 {
            ticks.append(t)
            t += step
        }
        return ticks
    }

    // MARK: - Y-axis tick values

    private var yAxisValues: [Double] {
        if metric == .angle {
            return [0, 45, 90]
        } else {
            return [0, 50, 100]
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Chart {
                // Target band behind everything
                RectangleMark(
                    xStart: .value("Start", 0),
                    xEnd: .value("End", runDuration),
                    yStart: .value("Lower", targetBand.lower),
                    yEnd: .value("Upper", targetBand.upper)
                )
                .foregroundStyle(bandFillColor)

                // Trace line
                ForEach(Array(points.enumerated()), id: \.offset) { _, pt in
                    LineMark(
                        x: .value("Time", pt.x),
                        y: .value("Value", pt.y)
                    )
                    .foregroundStyle(traceColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)
                }

                // Max marker
                if let maxT = maxTime {
                    PointMark(
                        x: .value("Time", maxT),
                        y: .value("Value", maxValue)
                    )
                    .foregroundStyle(AppColors.success)
                    .symbolSize(64)
                    .annotation(position: .top, spacing: 4) {
                        Text(maxAnnotationText)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(AppColors.success)
                    }
                }

                // NOTE: the vertical scrubber line is NOT drawn here — a single
                // shared line spanning both charts is drawn by the parent
                // (RunDetailsView) so it reads as one continuous line (M-UI8).

                // Scrubber value dot (stays inside this chart's plot area)
                if let time = selectedTime {
                    let val = valueAt(time)
                    PointMark(
                        x: .value("Time", time),
                        y: .value("Value", val)
                    )
                    .foregroundStyle(traceColor)
                    .symbolSize(50)
                    .annotation(position: .trailing, spacing: 4) {
                        Text(scrubberValueText(val))
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(traceColor)
                    }
                }
            }
            .chartXScale(domain: 0...runDuration)
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: xAxisValues) { value in
                    AxisValueLabel {
                        if let t = value.as(Double.self) {
                            Text(formatTimeAxis(t))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(AppColors.accent)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: yAxisValues) { value in
                    AxisValueLabel(horizontalSpacing: 4) {
                        if let v = value.as(Double.self) {
                            yAxisLabel(v)
                        }
                    }
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(AppColors.gridLine)
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
                        .preference(
                            key: ScrubberGeometryKey.self,
                            value: scrubberGeometry(proxy: proxy, geo: geo).map { [$0] } ?? []
                        )
                }
            }
            .frame(height: 180)

            // Target band label at right edge inside the band
            targetBandLabel
        }
        .accessibilityLabel("\(metric == .angle ? "Angle" : "Speed") chart")
        .accessibilityHint("Drag horizontally to scrub through time")
    }

    // MARK: - Shared scrubber geometry

    /// Report this chart's plot rect (global coords) and the x of the current
    /// scrubber time, so the parent can draw ONE line spanning both charts (M-UI8).
    private func scrubberGeometry(proxy: ChartProxy, geo: GeometryProxy) -> ScrubberFrame? {
        guard metric == .angle || metric == .speed else { return nil }
        let plot = geo.frame(in: .global)
        var scrubX: CGFloat?
        if let time = selectedTime, let localX = proxy.position(forX: time) {
            scrubX = plot.minX + localX
        }
        return ScrubberFrame(metric: metric, plotRect: plot, scrubberX: scrubX)
    }

    // MARK: - Target Band Label

    private var targetBandLabel: some View {
        VStack {
            Spacer()
                .frame(height: 40) // Position inside band area roughly
            HStack {
                Spacer()
                Text(bandRangeText)
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(.trailing, AppSpacing.sm)
            }
            Spacer()
        }
        .frame(height: 180)
        .allowsHitTesting(false)
    }

    private var bandRangeText: String {
        if metric == .angle {
            return "\(Int(targetBand.lower))°-\(Int(targetBand.upper))°"
        } else {
            return "\(Int(targetBand.lower))-\(Int(targetBand.upper)) km/h"
        }
    }

    // MARK: - Helpers

    private var maxAnnotationText: String {
        if metric == .angle {
            return "\(Int(maxValue))°"
        } else {
            return "\(Int(maxValue))"
        }
    }

    private func scrubberValueText(_ val: Double) -> String {
        if metric == .angle {
            return "\(Int(val))°"
        } else {
            return "\(Int(val)) km/h"
        }
    }

    @ViewBuilder
    private func yAxisLabel(_ v: Double) -> some View {
        if metric == .angle {
            Text("\(Int(v))°")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(AppColors.accent)
        } else {
            if v == 100 {
                VStack(spacing: 0) {
                    Text("\(Int(v))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(AppColors.accent)
                    Text("km/h")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(AppColors.accent)
                }
            } else {
                Text("\(Int(v))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(AppColors.accent)
            }
        }
    }

    private func formatTimeAxis(_ t: Double) -> String {
        if t == Double(Int(t)) {
            return "\(Int(t))s"
        } else {
            return String(format: "%.1fs", t)
        }
    }
}


/// Plot geometry a `TelemetryChart` publishes so the parent can draw one shared
/// scrubber line spanning both charts (M-UI8). Rects are in the `.global` space.
struct ScrubberFrame: Equatable {
    let metric: MetricKind
    let plotRect: CGRect
    let scrubberX: CGFloat?
}

/// Collects the per-chart `ScrubberFrame`s reported up to the parent.
struct ScrubberGeometryKey: PreferenceKey {
    static var defaultValue: [ScrubberFrame] = []
    static func reduce(value: inout [ScrubberFrame], nextValue: () -> [ScrubberFrame]) {
        value.append(contentsOf: nextValue())
    }
}
