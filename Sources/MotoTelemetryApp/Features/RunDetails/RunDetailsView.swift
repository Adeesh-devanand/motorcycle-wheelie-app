import SwiftUI

/// §9 — Run Details, laid out to fit ONE portrait screen with no scrolling.
///
/// The page used to be a `ScrollView`: a 36 pt black "RUN DETAILS" title, a hero card,
/// two fixed 180 pt charts, an insight card, a colour legend and the timeline came to
/// roughly 1030 pt of content against about 715 pt of usable height on an iPhone 14,
/// so two thirds of a run's summary lived below the fold. Fitting it meant cutting real
/// rows, not just tightening padding:
///
///   - the title block collapsed into the nav row, so the header costs 44 pt instead of
///     ~95 and the empty band above it is gone;
///   - the hero card and the insight card merged into ONE card of two rows — six
///     numbers, one set of dividers, one set of card padding;
///   - the teal/blue legend row was deleted and each chart's own title took its
///     channel colour instead, which teaches the same thing in a row that already
///     existed;
///   - the "PERSONAL BEST" line under wheelie time went, because the LONGEST pill in
///     the header already says it;
///   - both charts became flexible-height and now split whatever is left over, so the
///     page adapts from an SE to a Pro Max rather than assuming 180 pt fits.
///
/// The tab bar is hidden here (`.toolbar(.hidden, for: .tabBar)`) — this is a pushed
/// detail with its own back button, and it returns ~49 pt to the charts.
struct RunDetailsView: View {
    @State private var viewModel: RunDetailsViewModel
    @Environment(\.dismiss) private var dismiss

    /// Whether this run genuinely holds the longest duration on record. Computed
    /// from the repository at init, never assumed: a badge that claims a record
    /// on every run is a false claim, and this project's whole premise is that
    /// every number it shows is one it can defend.
    private let isLongestRun: Bool
    private let exportURL: URL?

    /// Rider-selected channel colours, read once at init from persisted preferences
    /// (UserDefaults-backed, cheap). Applied to each chart's trace, target band and
    /// title so Run Details matches the live meters.
    private let angleColor: Color
    private let speedColor: Color

    /// Whether the angle-smoothing explanation popover is showing (change #4).
    @State private var showSmoothingInfo = false

    init(runID: UUID, repository: RunRepository) {
        self.exportURL = repository.exportURL(for: runID)
        let prefs = RiderPreferences()
        self.angleColor = Color(hex: prefs.angleColorHex)
        self.speedColor = Color(hex: prefs.speedColorHex)
        let allRuns = repository.allRuns
        let verifiedRuns = allRuns.filter { $0.qualityFlags.isTrustworthy }
        let run = allRuns.first { $0.id == runID }
            ?? WheelieRun(id: runID, startedAt: .now, endedAt: .now, samples: [],
                          configuration: RunConfigurationSnapshot(
                            angleTarget: MetricRange(lower: 35, upper: 45),
                            speedTarget: MetricRange(lower: 35, upper: 50),
                            speedGaugeMaximum: 100,
                            calibrationID: UUID()))

        // A single run is not a record holder — with nothing to compare against
        // "LONGEST" would be vacuous rather than earned.
        if verifiedRuns.count > 1, let longest = verifiedRuns.max(by: { $0.duration < $1.duration }) {
            self.isLongestRun = longest.id == run.id
        } else {
            self.isLongestRun = false
        }

        _viewModel = State(wrappedValue: RunDetailsViewModel(run: run))
    }

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            headerRow
            statsCard
            if !viewModel.run.qualityFlags.isTrustworthy {
                Text("Measurement quality is reduced or unverified. Excluded from verified bests.")
                    .font(.caption).foregroundStyle(AppColors.warning)
            }
            chartsGroup
            intervalTimeline
        }
        .padding(.horizontal, AppSpacing.screenPadding)
        .padding(.bottom, AppSpacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppColors.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header (nav + title + date + record badge, one row)

    private var headerRow: some View {
        HStack(spacing: AppSpacing.sm) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back to runs")

            Text("RUN DETAILS")
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize()

            Text(subtitleText)
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: AppSpacing.xs)

            if let exportURL {
                ShareLink(item: exportURL) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Export this attempt as JSON")
            }
            badgePill
        }
        // The row is exactly the back button's 44 pt hit target — the smallest this
        // can be without shrinking a control below the touch minimum. The old
        // `.padding(.top, .sm)` above it is gone; that padding plus the 36 pt title's
        // line box is the empty space at the top of the page.
        .frame(height: 44)
        // Removed with the old nav row: a share icon and a gear icon that were bare
        // `Image(systemName:)` views, not Buttons. They looked tappable, did nothing,
        // and were invisible to VoiceOver. A working export exists in DiagnosticsView,
        // on the real file URL.
    }

    private var subtitleText: String {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        let dayPart = formatter.string(from: viewModel.run.startedAt)

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        let timePart = timeFmt.string(from: viewModel.run.startedAt)

        return "\(dayPart) · \(timePart)"
    }

    @ViewBuilder
    private var badgePill: some View {
        if isLongestRun {
            Text("LONGEST")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColors.badgeSuccessText)
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, AppSpacing.xxs + 1)
                .background(AppColors.badgeSuccessFill)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .fixedSize()
        }
    }

    // MARK: - Stats (the old hero card and insight strip, merged)

    private var statsCard: some View {
        TelemetryCard {
            VStack(spacing: AppSpacing.xs) {
                HStack(spacing: 0) {
                    metricColumn(label: "WHEELIE TIME",
                                 value: String(format: "%.1f", viewModel.duration),
                                 unit: "s",
                                 valueSize: 26,
                                 color: AppColors.success,
                                 labelColor: AppColors.accent)
                    verticalDivider(height: 34)
                    metricColumn(label: "MAX ANGLE",
                                 value: String(format: "%.0f", viewModel.maxAngle),
                                 unit: "°",
                                 valueSize: 26,
                                 color: AppColors.angleMetric,
                                 labelColor: AppColors.accent)
                    verticalDivider(height: 34)
                    metricColumn(label: "MAX SPEED",
                                 value: String(format: "%.0f", viewModel.maxSpeed),
                                 unit: "km/h",
                                 valueSize: 26,
                                 // Was the angle channel's teal, so the speed hero was
                                 // lying about which channel it belonged to.
                                 color: AppColors.speedMetric,
                                 labelColor: AppColors.accent)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)

                HStack(spacing: 0) {
                    metricColumn(label: "ANGLE IN RANGE",
                                 value: String(format: "%.1f", viewModel.totalAngleInRange),
                                 unit: "s",
                                 valueSize: 17,
                                 color: AppColors.angleMetric)
                    verticalDivider(height: 24)
                    metricColumn(label: "SPEED IN RANGE",
                                 value: String(format: "%.1f", viewModel.totalSpeedInRange),
                                 unit: "s",
                                 valueSize: 17,
                                 color: AppColors.speedMetric)
                    verticalDivider(height: 24)
                    metricColumn(label: "AVG SPEED",
                                 value: String(format: "%.0f", viewModel.averageSpeed),
                                 unit: "km/h",
                                 valueSize: 17,
                                 color: AppColors.speedMetric)
                }
            }
        }
    }

    private func verticalDivider(height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: height)
    }

    /// One labelled number. `labelColor` defaults to secondary because the lower row's
    /// labels are quieter than the three headline metrics above them.
    private func metricColumn(label: String,
                              value: String,
                              unit: String?,
                              valueSize: CGFloat,
                              color: Color,
                              labelColor: Color = AppColors.textSecondary) -> some View {
        VStack(spacing: 1) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 10, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            HStack(alignment: .lastTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: valueSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                if let unit {
                    if unit == "°" {
                        // The degree sign rides on TOP of the number as a superscript
                        // (44°), hugging the last digit — not a spaced unit sitting
                        // beside it on the baseline like "s" or "km/h".
                        Text(unit)
                            .font(.system(size: valueSize * 0.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(color)
                            .baselineOffset(valueSize * 0.42)
                    } else {
                        Text(unit)
                            .font(.system(size: valueSize * 0.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(color)
                    }
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value) \(unit ?? "")")
    }

    // MARK: - Charts (§9.4)

    /// Both charts stacked, with ONE continuous scrubber line drawn across them
    /// as a single overlay (M-UI8). Each chart reports its plot rect + scrubber x
    /// via `ScrubberGeometryKey`; the overlay joins them into one line and floats
    /// the time bubble at the scrubber's x.
    ///
    /// This group is the page's only flexible element, so it absorbs every point the
    /// fixed rows above and below do not use, and its two children split that equally.
    private var chartsGroup: some View {
        VStack(spacing: AppSpacing.sm) {
            angleChart
            speedChart
        }
        .overlayPreferenceValue(ScrubberGeometryKey.self) { frames in
            GeometryReader { geo in
                sharedScrubberOverlay(frames: frames, container: geo)
            }
        }
    }

    @ViewBuilder
    private func sharedScrubberOverlay(frames: [ScrubberFrame], container: GeometryProxy) -> some View {
        // Convert the reported global plot rects into this container's local space.
        let origin = container.frame(in: .global).origin
        let angle = frames.first { $0.metric == .angle }
        let speed = frames.first { $0.metric == .speed }

        if viewModel.selectedTime != nil,
           let angle, let speed,
           let gx = angle.scrubberX ?? speed.scrubberX {
            let x = gx - origin.x
            let topY = angle.plotRect.minY - origin.y
            let bottomY = speed.plotRect.maxY - origin.y

            // One continuous vertical line from the top of the angle plot to the
            // bottom of the speed plot.
            Path { p in
                p.move(to: CGPoint(x: x, y: topY))
                p.addLine(to: CGPoint(x: x, y: bottomY))
            }
            .stroke(AppColors.textPrimary.opacity(0.85), lineWidth: 1)
            .allowsHitTesting(false)

            // Time bubble tracking the scrubber x, above the angle chart.
            if let time = viewModel.selectedTime {
                Text(String(format: "%.1fs", time))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppColors.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(hex: 0x1A1A20).opacity(0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .fixedSize()
                    .position(x: x, y: max(topY - 14, 10))
                    .allowsHitTesting(false)
            }

            // Each chart's reading, centered ON the scrubber line just above that
            // chart's dot. Drawn AFTER the line and with an opaque background, so the
            // line is occluded behind the chip rather than striking through the digits
            // — which is the "line disappears around it" effect without having to
            // measure the text and split the path into segments.
            //
            // The reading used to sit immediately right of the dot, where the trace
            // continues, so it was drawn over its own line. Above the dot on the
            // scrubber is empty by construction: the trace cannot be there, because the
            // trace passes through the dot.
            ForEach([angle, speed], id: \.metric) { frame in
                readingChip(frame: frame, x: x, origin: origin)
            }
        }
    }

    /// The scrubber reading for one chart. Positioned above the dot, clamped so it stays
    /// inside that chart's plot, and flipped below the dot when the reading is high
    /// enough that there is no room above it.
    @ViewBuilder
    private func readingChip(frame: ScrubberFrame, x: CGFloat, origin: CGPoint) -> some View {
        if let text = frame.valueText, let gy = frame.dotY {
            let dotY = gy - origin.y
            let plotTop = frame.plotRect.minY - origin.y
            let plotBottom = frame.plotRect.maxY - origin.y
            // Half the chip's height plus the dot's radius and a small gap. A constant
            // rather than a measurement: the chip is one short monospaced line at a
            // fixed size, so its height does not vary with the value.
            let offset: CGFloat = 20
            let above = dotY - offset
            // If the chip would leave the plot, put it below the dot instead. A peak
            // reading sits at the very top of the axis, which is exactly when "above"
            // has nowhere to go.
            let y = above < plotTop + 10 ? min(dotY + offset, plotBottom - 10) : above
            let color = frame.metric == .angle ? AppColors.angleMetric : AppColors.speedMetric

            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color(hex: 0x1A1A20).opacity(0.95))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(color.opacity(0.45), lineWidth: 1)
                )
                .fixedSize()
                .position(x: x, y: y)
                .allowsHitTesting(false)
        }
    }

    private var angleChart: some View {
        TelemetryCard {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                // Change #4: plain "ANGLE" heading + an info button that explains the
                // actual (offline, zero-phase jitter-blur) smoothing in plain language.
                HStack(spacing: AppSpacing.xs) {
                    chartTitle("ANGLE", color: angleColor)
                    Button {
                        showSmoothingInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .accessibilityLabel("About angle smoothing")
                    .popover(isPresented: $showSmoothingInfo) {
                        smoothingInfoPopover
                    }
                }

                TelemetryChart(
                    points: viewModel.anglePoints,
                    segments: viewModel.angleSegments,
                    rawSamples: viewModel.displaySamples,
                    targetBand: viewModel.angleTarget,
                    metric: .angle,
                    yDomain: viewModel.angleDomain,
                    runDuration: viewModel.duration,
                    selectedTime: $viewModel.selectedTime,
                    plotHeight: nil,
                    accentColor: angleColor,
                    bandColor: angleColor.opacity(0.14)
                )
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Plain-language explanation of the angle smoothing, written against the actual
    /// `JitterBlur` implementation: offline, zero-phase, removes vibration jitter only,
    /// does NOT correct drift, and falls back to the raw angle ("when available").
    private var smoothingInfoPopover: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("About the angle line")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
            Text("""
                After a run, the angle is lightly smoothed to remove sensor vibration \
                jitter. The smoothing looks at each point's neighbours on both sides, so \
                it doesn't shift the line in time — peaks stay where they happened. It \
                only cleans up fast wiggle; it does not correct slow drift, and it never \
                changes your stored measurements or your max angle. Very short runs can't \
                be smoothed, so the raw angle is shown instead.
                """)
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Done") { showSmoothingInfo = false }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppColors.accent)
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: 320)
        .presentationCompactAdaptation(.popover)
    }

    private var speedChart: some View {
        TelemetryCard {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                chartTitle("SPEED", color: speedColor)

                TelemetryChart(
                    points: viewModel.speedPoints,
                    segments: viewModel.speedSegments,
                    rawSamples: viewModel.displaySamples,
                    targetBand: viewModel.speedTarget,
                    metric: .speed,
                    yDomain: viewModel.speedDomain,
                    runDuration: viewModel.duration,
                    selectedTime: $viewModel.selectedTime,
                    plotHeight: nil,
                    accentColor: speedColor,
                    bandColor: speedColor.opacity(0.16)
                )
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// The channel name in the channel's own colour. This is what replaced the separate
    /// teal-dot / blue-dot legend row: with each chart titled in its own colour the
    /// legend taught what the label already shows, and it cost a row this page does not
    /// have to spare.
    private func chartTitle(_ text: String, color: Color) -> some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(color)
    }

    // MARK: - Interval Timeline (§9.6)

    private var intervalTimeline: some View {
        RangeIntervalTimeline(
            angleIntervals: viewModel.angleIntervals,
            speedIntervals: viewModel.speedIntervals,
            duration: viewModel.duration,
            selectedTime: $viewModel.selectedTime,
            totalAngleInRange: viewModel.totalAngleInRange,
            totalSpeedInRange: viewModel.totalSpeedInRange
        )
    }
}
