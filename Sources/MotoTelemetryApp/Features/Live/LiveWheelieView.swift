import SwiftUI
import MotoTelemetryCore

/// The Live tab's flow container: calibration, then swipe alignment, then the live
/// screen. Calibration runs on EVERY launch (no persistence), so this sequence is
/// the front door, not an occasional interruption.
///
/// One sensor session spans all three phases. `RunRecorder.startSensing()` begins
/// CoreMotion updates and feeds `CalibrationService` immediately; the same running
/// session is promoted to a recording session (with the captured alignment) when the
/// rider confirms the swipe. That ordering resolves the chicken-and-egg — calibration
/// needs the sensor stream, and the alignment the live view needs is what calibration
/// produces — without starting the stream twice.
/// `@MainActor` for the same reason `LiveScreen` and `CalibrationScreen` are: it owns
/// the flow `phase` and calls `CalibrationService.restart()`, which is main-actor
/// isolated so it can publish the observable mirrors synchronously.
@MainActor
struct LiveWheelieView: View {
    private enum Phase { case calibrating, swiping(BiasEstimate), live(MountAlignment) }

    @State private var phase: Phase = .calibrating
    private let calibrationService: CalibrationService
    private let preferences: RiderPreferences
    private let recorder: RunRecorder
    private let bikeProfileID = UUID()

    init(calibrationService: CalibrationService,
         preferences: RiderPreferences,
         recorder: RunRecorder) {
        self.calibrationService = calibrationService
        self.preferences = preferences
        self.recorder = recorder
    }

    var body: some View {
        VStack(spacing: 0) {
            if !recorder.unsavedRuns.isEmpty {
                Button("\(recorder.unsavedRuns.count) unsaved attempt(s) — Retry saving") {
                    recorder.retryUnsavedRuns()
                }
                .foregroundStyle(AppColors.warning)
                .padding()
                Text("Keep the app open until saving succeeds.")
                    .font(.caption)
            }
            phaseContent
        }
    }

    private var phaseContent: some View {
        Group {
            switch phase {
            case .calibrating:
                CalibrationScreen(service: calibrationService, onMeasured: { estimate in
                    phase = .swiping(estimate)
                }, onRetry: restart)
                .onAppear { recorder.startSensing(bikeProfileID: bikeProfileID) }

            case .swiping(let estimate):
                SwipeAlignmentScreen(
                    gravityAnchor: estimate.measuredGravity ?? Vector3(0, 0, -Conventions.g),
                    config: Config(),
                    bikeProfileID: bikeProfileID,
                    onConfirmed: { alignment in phase = .live(alignment) },
                    onRecalibrate: restart
                )

            case .live(let alignment):
                LiveScreen(
                    calibrationService: calibrationService,
                    preferences: preferences,
                    recorder: recorder,
                    alignment: alignment,
                    bikeProfileID: bikeProfileID,
                    onRecalibrate: restart
                )
            }
        }
    }

    /// Return to the front of the flow: the calibration screen, then the swipe.
    ///
    /// Owned here rather than in `LiveWheelieViewModel` because `phase` lives here.
    /// The view model's old `requestRecalibration()` did half the job — it restarted
    /// the service but could not move the phase it does not own, so the rider stayed
    /// on the live screen watching a pill that said CALIBRATING while the angle they
    /// were reading was derived from the bias being replaced.
    ///
    /// Ordering is deliberate and matches the swipe screen's own path: restart the
    /// service, then change phase. `LiveScreen` disappearing runs
    /// `LiveWheelieViewModel.onDisappear` -> `recorder.stopSession()`, which returns
    /// the recorder to `.idle`, and `CalibrationScreen.onAppear` then calls
    /// `startSensing` whose guard requires exactly that. A new alignment is required
    /// too: a re-zero without a fresh swipe would keep an alignment measured against
    /// the old reference.
    private func restart() {
        recorder.stopSession()
        calibrationService.restart()
        if case .calibrating = phase { recorder.startSensing(bikeProfileID: bikeProfileID) }
        phase = .calibrating
    }
}

/// The live telemetry screen proper — reached only after calibration and swipe,
/// and handed a real measured alignment.
///
/// `@MainActor` because every property it reads — `LiveWheelieViewModel` and, one
/// layer down, `RunRecorder`'s display mirrors — is main-actor isolated by the
/// concurrency fix. SwiftUI's `body` is not itself isolated in Swift 5, so without
/// this the view reads main-actor state from a nonisolated context and the app
/// does not compile.
@MainActor
struct LiveScreen: View {
    @State private var viewModel: LiveWheelieViewModel
    @State private var showSettings = false
    /// Sends the rider back to the calibration screen. Owned by `LiveWheelieView`,
    /// which holds the phase.
    private let onRecalibrate: @MainActor () -> Void

    init(calibrationService: CalibrationService,
         preferences: RiderPreferences,
         recorder: RunRecorder,
         alignment: MountAlignment,
         bikeProfileID: UUID,
         onRecalibrate: @escaping @MainActor () -> Void) {
        self.onRecalibrate = onRecalibrate
        _viewModel = State(wrappedValue: LiveWheelieViewModel(
            calibrationService: calibrationService,
            preferences: preferences,
            recorder: recorder,
            alignment: alignment,
            bikeProfileID: bikeProfileID
        ))
    }

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()

            VStack(spacing: AppSpacing.lg) {
                Text(viewModel.acquisitionStatus)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .accessibilityAddTraits(.updatesFrequently)
                headerBar
                metersSection
                    .frame(maxHeight: .infinity)
                bottomMetrics
            }
            .padding(AppSpacing.screenPadding)
        }
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(preferences: viewModel.preferences)
            }
        }
    }

    // MARK: - Header

    /// Centered status pill (~62% width), circular gear button at trailing edge.
    private var headerBar: some View {
        ZStack {
            // Centered status pill
            StatusPill(state: viewModel.calibrationState, onTapRecalibrate: onRecalibrate)
                .frame(width: UIScreen.main.bounds.width * 0.62)

            // Gear button at trailing edge
            HStack {
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Circle()
                        .fill(AppColors.surfaceButton)
                        .frame(width: 48, height: 48)
                        .overlay(
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(AppColors.textSecondary)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
        }
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
                        .foregroundStyle(AppColors.textPrimary)
                ),
                sublabel: String(localized: "MAX \(Int(viewModel.attemptMaxAngle))°")
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
                                .foregroundStyle(AppColors.textPrimary)
                            Text("km/h")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(AppColors.accentBright)
                        }
                    ),
                    sublabel: String(localized: "MAX \(Int(viewModel.attemptMaxSpeed))")
                )
            }
        }
    }

    private func metricCard(label: String, valueContent: AnyView, sublabel: String?) -> some View {
        VStack(spacing: AppSpacing.xs) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 12, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(AppColors.accent)

            valueContent

            if let sublabel {
                Text(sublabel)
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textSecondary)
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
        viewModel.eventActive || !viewModel.isCalibrated
    }
}
