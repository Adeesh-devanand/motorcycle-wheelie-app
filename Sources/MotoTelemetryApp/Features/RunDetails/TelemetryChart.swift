import Charts
import MotoTelemetryCore
import SwiftUI

/// §9.4 — Swift Charts view: smooth LineMark for angle/speed over time,
/// target band as RectangleMark, max marker, scrubber with value dots.
struct TelemetryChart: View {
    let points: [Downsample.Point]
    var segments: [[Downsample.Point]]? = nil
    let rawSamples: [TelemetrySample]
    let targetBand: MetricRange
    let metric: MetricKind
    let yDomain: ClosedRange<Double>
    let runDuration: TimeInterval
    @Binding var selectedTime: TimeInterval?

    /// Height of the plot area. A number keeps the original fixed-height chart; `nil`
    /// means "fill whatever the parent gives me", which is how Run Details fits both
    /// charts plus the summary and timeline on one screen with no scrolling.
    ///
    /// Declared last on purpose: the memberwise initialiser follows declaration order,
    /// so a defaulted property placed earlier would silently reorder every existing
    /// call site's arguments.
    var plotHeight: CGFloat? = 180

    /// Optional rider-selected accent overrides. Nil (the default) falls back to the
    /// metric-based `AppColors` tokens, preserving every existing call site and the
    /// memberwise-init argument order. Declared last for the same reason as `plotHeight`.
    var accentColor: Color? = nil
    var bandColor: Color? = nil

    /// Applied as `.frame(height:)`. Nil leaves the plot unconstrained so the
    /// companion `flexiblePlotMax` can let it fill the parent instead.
    private var fixedPlotHeight: CGFloat? { plotHeight }

    /// Applied as `.frame(maxHeight:)`. Only non-nil in the flexible case, where it
    /// makes the plot claim all the height the parent offers. Both the chart and the
    /// band-label overlay take the same pair, because they MUST agree — the label
    /// positions its caption by offset inside its own frame, so a mismatch floats the
    /// range text off the band it is labelling.
    private var flexiblePlotMax: CGFloat? { plotHeight == nil ? .infinity : nil }

    // MARK: - Derived colours from AppColors tokens

    private var traceColor: Color {
        accentColor ?? (metric == .angle ? AppColors.angleMetric : AppColors.speedMetric)
    }

    private var bandFillColor: Color {
        // Prefer a derived translucent shade of the rider accent; else the token.
        if let bandColor { return bandColor }
        return metric == .angle ? AppColors.targetBandChartAngle : AppColors.targetBandChartSpeed
    }

    private var maxValue: Double {
        metric == .angle
            ? rawSamples.map(\.angleDegrees).max() ?? 0
            : rawSamples.map(\.speedKPH).filter(\.isFinite).max() ?? 0
    }

    private var maxTime: TimeInterval? {
        if metric == .angle {
            return rawSamples.max(by: { $0.angleDegrees < $1.angleDegrees })?.elapsed
        } else {
            return rawSamples.filter { $0.speedKPH.isFinite }.max(by: { $0.speedKPH < $1.speedKPH })?.elapsed
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
        guard b.elapsed - a.elapsed <= 0.25 else { return .nan }
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
            // Was a hardcoded [0, 50, 100]. The speed gauge maximum is rider-set
            // (50-300 km/h), so a fixed 100 either labelled a tick the axis does not
            // contain or stopped a third of the way up a 300 km/h axis.
            let top = yDomain.upperBound
            return [0, (top / 2).rounded(), top]
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
                // The range caption, drawn as the BAND's own annotation rather than as a
                // sibling overlay. `.overlay` centers it on the mark in both axes, which
                // is exactly "inside the highlight, in the middle" — and it comes from
                // the chart's own coordinate space, so it is exact at any plot height.
                //
                // The previous version was a separate `Canvas`-era overlay offset a
                // fixed 40 pt from the top of the whole chart frame and right-aligned:
                // on the 0-90 deg axis that is ~70 deg, so it sat above the band it was
                // labelling, and it needed manual geometry that went wrong the moment
                // the plot height stopped being a constant 180.
                .annotation(position: .overlay) {
                    Text(bandRangeText)
                        .font(.system(size: 11, weight: .semibold))
                        // The band's own colour family, dimmed so it reads as the band's
                        // label rather than competing with the trace drawn in the full
                        // strength of the same hue.
                        .foregroundStyle(traceColor.opacity(0.75))
                        .fixedSize()
                }

                // Trace line
                ForEach(Array((segments ?? [points]).enumerated()), id: \.offset) { segmentIndex, segment in
                ForEach(Array(segment.enumerated()), id: \.offset) { _, pt in
                    LineMark(
                        x: .value("Time", pt.x),
                        y: .value("Value", pt.y),
                        series: .value("Segment", segmentIndex)
                    )
                    .foregroundStyle(traceColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.linear)
                }
                }

                // Max marker
                if let maxT = maxTime {
                    PointMark(
                        x: .value("Time", maxT),
                        y: .value("Value", maxValue)
                    )
                    .foregroundStyle(traceColor)
                    .symbolSize(64)
                    .annotation(position: .top, spacing: 4) {
                        Text(maxAnnotationText)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(traceColor)
                    }
                }

                // NOTE: the vertical scrubber line is NOT drawn here — a single
                // shared line spanning both charts is drawn by the parent
                // (RunDetailsView) so it reads as one continuous line (M-UI8).

                // Scrubber value DOT only. The value text used to ride along here as
                // `.annotation(position: .trailing)` — immediately to the right of the
                // dot, which is precisely where the trace continues, so the reading was
                // drawn on top of its own line and became unreadable as soon as the
                // scrubber was anywhere but the far right. The text is now drawn by the
                // parent, centered on the shared scrubber line above this dot, where
                // nothing else lives.
                if let time = selectedTime {
                    let val = valueAt(time)
                    if val.isFinite {
                    PointMark(
                        x: .value("Time", time),
                        y: .value("Value", val)
                    )
                    .foregroundStyle(traceColor)
                    .symbolSize(50)
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
            .frame(height: fixedPlotHeight)
            .frame(maxHeight: flexiblePlotMax)
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
        var dotY: CGFloat?
        var text: String?
        if let time = selectedTime {
            if let localX = proxy.position(forX: time) {
                scrubX = plot.minX + localX
            }
            // Same space as `scrubX`: `chartOverlay`'s geometry covers the plot area and
            // `proxy.position(forY:)` is relative to it, so one origin shift converts
            // both. Reported even when `scrubX` is nil is not useful, but harmless.
            let value = valueAt(time)
            if value.isFinite {
                if let localY = proxy.position(forY: value) {
                    dotY = plot.minY + localY
                }
                text = scrubberValueText(value)
            }
        }
        return ScrubberFrame(metric: metric, plotRect: plot, scrubberX: scrubX,
                             dotY: dotY, valueText: text)
    }

    // MARK: - Target Band Label
    //
    // There is no overlay here any more. The caption is the band `RectangleMark`'s own
    // `.annotation(position: .overlay)`, which centers it on the band in both axes using
    // the chart's coordinate space. That deleted a `GeometryReader`, a fraction-of-height
    // positioning helper, and the approximation they carried (the outer frame includes
    // the x-axis label strip, so any offset measured from it sits a few points low).

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
                .foregroundStyle(traceColor)
        } else {
            if v == 100 {
                VStack(spacing: 0) {
                    Text("\(Int(v))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(traceColor)
                    Text("km/h")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(traceColor)
                }
            } else {
                Text("\(Int(v))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(traceColor)
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
    /// Global y of the scrubbed value's dot on the trace. The parent places this
    /// chart's reading chip just above it, so the number sits next to the point it
    /// describes instead of at a fixed height far from it.
    let dotY: CGFloat?
    /// The already-formatted reading ("42°", "38 km/h"). Formatting stays with the
    /// chart because only the chart knows its metric's unit.
    let valueText: String?
}

/// Collects the per-chart `ScrubberFrame`s reported up to the parent.
struct ScrubberGeometryKey: PreferenceKey {
    static var defaultValue: [ScrubberFrame] = []
    static func reduce(value: inout [ScrubberFrame], nextValue: () -> [ScrubberFrame]) {
        value.append(contentsOf: nextValue())
    }
}
