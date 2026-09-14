import SwiftUI
import MotoTelemetryCore

/// One persistent Live page owns meters, calibration, alignment and pause controls.
@MainActor
struct LiveWheelieView: View {
    let calibrationService: CalibrationService
    let preferences: RiderPreferences
    let recorder: RunRecorder

    var body: some View {
        LiveScreen(calibrationService: calibrationService, preferences: preferences,
                   recorder: recorder, alignment: nil, bikeProfileID: UUID())
    }
}

@MainActor
struct LiveScreen: View {
    @State private var viewModel: LiveWheelieViewModel
    @State private var showSettings = false
    private let calibrationService: CalibrationService
    private let recorder: RunRecorder

    init(calibrationService: CalibrationService, preferences: RiderPreferences,
         recorder: RunRecorder, alignment: MountAlignment?, bikeProfileID: UUID) {
        self.calibrationService = calibrationService
        self.recorder = recorder
        _viewModel = State(wrappedValue: LiveWheelieViewModel(
            calibrationService: calibrationService, preferences: preferences,
            recorder: recorder, alignment: alignment, bikeProfileID: bikeProfileID))
    }

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()
            VStack(spacing: AppSpacing.lg) {
                headerBar
                if !recorder.unsavedRuns.isEmpty {
                    Button("Retry saving unsaved attempts") { recorder.retryUnsavedRuns() }
                        .foregroundStyle(AppColors.warning)
                }
                if !viewModel.acquisitionStatus.isEmpty {
                    Text(viewModel.acquisitionStatus)
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
                instrumentContent.frame(maxHeight: .infinity)
                if !viewModel.isCalibrating {
                    bottomMetrics.opacity(viewModel.metersEnabled ? 1 : 0.25)
                }
            }
            .padding(AppSpacing.screenPadding)
        }
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView(preferences: viewModel.preferences) }
        }
    }

    @ViewBuilder
    private var instrumentContent: some View {
        switch viewModel.phase {
        case .meters:
            metersSection
                .opacity(viewModel.metersEnabled ? 1 : 0.25)
                .allowsHitTesting(viewModel.metersEnabled)
        case .calibrating:
            CalibrationScreen(service: calibrationService,
                onMeasured: viewModel.didMeasureCalibration,
                onRetry: viewModel.beginCalibration,
                onSkip: viewModel.skipCalibration)
        case .aligning(let estimate):
            VStack(spacing: 8) {
                SwipeAlignmentScreen(
                    gravityAnchor: estimate.measuredGravity ?? Vector3(0, 0, -Conventions.g),
                    config: Config(), bikeProfileID: viewModel.profileID,
                    onConfirmed: viewModel.confirmAlignment,
                    onRecalibrate: viewModel.beginCalibration)
                Button("Skip for now", action: viewModel.skipCalibration)
                    .padding(.bottom, 8)
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Button(action: viewModel.beginCalibration) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(viewModel.isCalibrating ? Color.yellow :
                              (viewModel.isCalibrated ? Color.green : Color.red))
                        .frame(width: 8, height: 8)
                    Text(viewModel.isCalibrating ? "Calibrating" :
                         (viewModel.isCalibrated ? "Recalibrate" : "Calibrate"))
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(minHeight: 44)
                .padding(.horizontal, 12)
                .background(AppColors.surfaceButton, in: Capsule())
            }
            .accessibilityLabel(viewModel.isCalibrating ? "Restart calibration" :
                                (viewModel.isCalibrated ? "Recalibrate" : "Calibrate"))

            Button(action: viewModel.togglePause) {
                Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 44, height: 44)
                    .background(AppColors.surfaceButton, in: Circle())
            }
            .disabled(!viewModel.isCalibrated || viewModel.isCalibrating)
            .accessibilityLabel(viewModel.isPaused ? "Resume meters and recording" : "Pause meters and recording")
            Spacer(minLength: 0)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .frame(width: 44, height: 44)
                    .background(AppColors.surfaceButton, in: Circle())
            }
            .accessibilityLabel("Settings")
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppColors.textPrimary)
    }

    // MARK: - Meters Section

    private var metersSection: some View {
        HStack(spacing: 0) {
            // ANGLE meter — centered in the left half, or in the whole width when
            // speed is switched off.
            angleMeter
                .frame(maxWidth: .infinity)

            if viewModel.speedometerEnabled {
                // SPEED meter — centered in the right half of the screen
                speedMeter
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var angleMeter: some View {
        var meter = VerticalTelemetryMeter(
            value: viewModel.currentAngle,
            range: 0...90,
            targetBand: viewModel.effectiveAngleTarget,
            unit: "°",
            label: "ANGLE",
            valueFont: AppTypography.meterValue,
            rangeStatus: viewModel.angleInRange
        )
        meter.labelsOnLeading = true
        meter.accentColor = Color(hex: viewModel.preferences.angleColorHex)
        meter.targetDragStep = 2.5
        // Only when the two meters share the width. On its own the angle meter has the
        // whole screen and shifting it would just look off-centre.
        meter.trackShiftTowardCenter = viewModel.speedometerEnabled ? 16 : 0
        meter.onTargetChange = targetEditDisabled ? nil : { band in
            viewModel.preferences.angleTarget = clamped(band, to: 0...90)
        }
        return meter
    }

    /// Speed meter. The gauge maximum is a rider setting (50–300 km/h), so the
    /// scale's top label is how they see the ceiling they chose.
    private var speedMeter: some View {
        let ceiling = viewModel.effectiveSpeedMaximum
        var meter = VerticalTelemetryMeter(
            value: viewModel.currentSpeed,
            range: 0...ceiling,
            targetBand: viewModel.effectiveSpeedTarget,
            unit: "km/h",
            label: "SPEED",
            valueFont: AppTypography.meterValue,
            rangeStatus: viewModel.speedInRange
        )
        meter.labelsOnLeading = false
        meter.accentColor = Color(hex: viewModel.preferences.speedColorHex)
        meter.targetDragStep = 2.5
        // The one meter that can genuinely have nothing to report: GNSS may hold no speed
        // solution. The view model HOLDS the last displayed speed in that case rather than
        // smoothing toward a fabricated 0, so without this the meter renders that held
        // number as if it were live — which is how it ended up stuck at 8 km/h.
        meter.valueAvailable = viewModel.speedAvailable
        // The speed meter only appears alongside angle, so it always shares the width.
        meter.trackShiftTowardCenter = 16
        meter.onTargetChange = targetEditDisabled ? nil : { band in
            viewModel.preferences.speedTarget = clamped(band, to: 0...ceiling)
        }
        return meter
    }

    /// Final guard on a dragged band. The meter already clamps to its own scale;
    /// this repeats it at the write so a band can never be stored outside the range
    /// it will be drawn in, whatever the caller passed as a scale.
    private func clamped(_ band: MetricRange, to bounds: ClosedRange<Double>) -> MetricRange {
        MetricRange(lower: min(max(band.lower, bounds.lowerBound), bounds.upperBound),
                    upper: min(max(band.upper, bounds.lowerBound), bounds.upperBound))
    }

    // MARK: - Bottom Metrics (three equal cards)

    private var bottomMetrics: some View {
        HStack(spacing: AppSpacing.sm) {
            // ANGLE card
            metricCard(
                label: "ANGLE",
                valueContent: AnyView(
                    Text("\(Int(viewModel.currentAngle))°")
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(hex: viewModel.preferences.angleColorHex))
                ),
                sublabel: String(localized: "MAX \(Int(viewModel.attemptMaxAngle))°"),
                labelColor: Color(hex: viewModel.preferences.angleColorHex)
            )

            // WHEELIE TIME card
            metricCard(
                label: "WHEELIE TIME",
                valueContent: AnyView(
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(String(format: "%.1f", viewModel.wheelieTime))
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppColors.textPrimary)
                        Text("s")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(AppColors.accentBright)
                    }
                ),
                sublabel: nil
            )

            // SPEED card — omitted entirely when speed is switched off, rather than
            // shown reading zero. A zero there is a claim about the bike.
            if viewModel.speedometerEnabled {
                metricCard(
                    label: "SPEED",
                    valueContent: AnyView(
                        HStack(alignment: .lastTextBaseline, spacing: 2) {
                            // 0, not a dash, when GNSS has no speed solution — matching the
                            // meter above. A rider's call, made knowingly against R15.3:
                            // "stopped" and "no satellites" now look the same here.
                            //
                            // The "0" is a LITERAL and deliberately not `currentSpeed`,
                            // which is what stops the stuck-reading bug returning: the view
                            // model HOLDS the last displayed speed while no fix exists, so
                            // rendering it would put a stale number back on screen — the
                            // reading that pinned this at 8 km/h. `speedAvailable` is still
                            // published, still logged, and still forces `speedInRange` to
                            // `.outOfRange`, so a held value cannot light the meter green.
                            Text(viewModel.speedAvailable
                                 ? "\(Int(viewModel.currentSpeed))" : "0")
                                .font(.system(size: 34, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color(hex: viewModel.preferences.speedColorHex))
                            Text("km/h")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color(hex: viewModel.preferences.speedColorHex))
                        }
                    ),
                    sublabel: String(localized: "MAX \(Int(viewModel.attemptMaxSpeed))"),
                    labelColor: Color(hex: viewModel.preferences.speedColorHex)
                )
            }
        }
    }

    private func metricCard(label: String, valueContent: AnyView, sublabel: String?,
                            labelColor: Color = AppColors.accent) -> some View {
        VStack(spacing: AppSpacing.xs) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 12, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(labelColor)

            valueContent

            if let sublabel {
                Text(sublabel)
                    .font(.system(size: 13))
                    .foregroundStyle(labelColor)
            } else {
                Text(" ")
                    .font(.system(size: 13))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.cardPadding)
        .background(AppColors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.card)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Helpers

    private var targetEditDisabled: Bool {
        viewModel.eventActive || !viewModel.metersEnabled
    }
}
