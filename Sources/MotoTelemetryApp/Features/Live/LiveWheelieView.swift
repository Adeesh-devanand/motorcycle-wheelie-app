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
struct LiveWheelieView: View {
    private enum Phase { case calibrating, swiping(BiasEstimate), live(MountAlignment) }

    @State private var phase: Phase = .calibrating
    private let calibrationService: CalibrationService
    private let preferences: RiderPreferences
    private let recorder: RunRecorder
    private let bikeStore: BikeProfileStore
    private let bikeProfileID = UUID()

    init(calibrationService: CalibrationService,
         preferences: RiderPreferences,
         recorder: RunRecorder,
         bikeStore: BikeProfileStore) {
        self.calibrationService = calibrationService
        self.preferences = preferences
        self.recorder = recorder
        self.bikeStore = bikeStore
    }

    var body: some View {
        Group {
            switch phase {
            case .calibrating:
                CalibrationScreen(service: calibrationService) { estimate in
                    phase = .swiping(estimate)
                }
                .onAppear { recorder.startSensing(bikeProfileID: bikeProfileID) }

            case .swiping(let estimate):
                SwipeAlignmentScreen(
                    gravityAnchor: estimate.measuredGravity ?? Vector3(0, 0, -Conventions.g),
                    config: Config(),
                    bikeProfileID: bikeProfileID,
                    onConfirmed: { alignment in phase = .live(alignment) },
                    onRecalibrate: {
                        calibrationService.restart()
                        phase = .calibrating
                    }
                )

            case .live(let alignment):
                LiveScreen(
                    calibrationService: calibrationService,
                    preferences: preferences,
                    recorder: recorder,
                    alignment: alignment,
                    bikeProfileID: bikeProfileID,
                    bikeStore: bikeStore
                )
            }
        }
    }
}

/// The live telemetry screen proper — reached only after calibration and swipe,
/// and handed a real measured alignment.
struct LiveScreen: View {
    @State private var viewModel: LiveWheelieViewModel
    @State private var showSettings = false
    /// Which target range the rider asked to edit, or nil for none. An enum
    /// rather than a Bool: a Bool cannot carry *which* meter was tapped, which
    /// is why one sheet used to open both ranges at once.
    @State private var editingTarget: TargetRangeEditor.Field?
    private let bikeStore: BikeProfileStore

    init(calibrationService: CalibrationService,
         preferences: RiderPreferences,
         recorder: RunRecorder,
         alignment: MountAlignment,
         bikeProfileID: UUID,
         bikeStore: BikeProfileStore) {
        self.bikeStore = bikeStore
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
            SettingsView(preferences: viewModel.preferences, bikeStore: bikeStore)
        }
        .sheet(item: $editingTarget) { field in
            TargetRangeEditor(
                preferences: viewModel.preferences,
                field: field,
                isDisabled: viewModel.eventActive || !viewModel.isCalibrated
            )
        }
    }

    // MARK: - Header

    /// Centered status pill (~62% width), circular gear button at trailing edge.
    private var headerBar: some View {
        ZStack {
            // Centered status pill
            StatusPill(state: viewModel.calibrationState) {
                viewModel.requestRecalibration()
            }
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
            // ANGLE meter — centered in the left half of the screen
            angleMeter
                .frame(maxWidth: .infinity)

            // SPEED meter — centered in the right half of the screen
            speedMeter
                .frame(maxWidth: .infinity)
        }
    }

    private var angleMeter: some View {
        var meter = VerticalTelemetryMeter(
            value: viewModel.currentAngle,
            range: 0...90,
            targetBand: viewModel.preferences.angleTarget,
            unit: "°",
            label: "ANGLE",
            valueFont: AppTypography.meterValue,
            rangeStatus: viewModel.angleInRange
        )
        meter.labelsOnLeading = true
        meter.onTargetEdit = targetEditDisabled ? nil : { editingTarget = .angle }
        return meter
    }

    /// Speed meter. The gauge maximum is fixed at 100 km/h for now and the old
    /// editable MAX chip has been removed (M-UI3), so the speed and angle meters
    /// share the same header height (M-UI10).
    private var speedMeter: some View {
        var meter = VerticalTelemetryMeter(
            value: viewModel.currentSpeed,
            range: 0...viewModel.preferences.speedGaugeMaximum,
            targetBand: viewModel.preferences.speedTarget,
            unit: "km/h",
            label: "SPEED",
            valueFont: AppTypography.meterValue,
            rangeStatus: viewModel.speedInRange
        )
        meter.labelsOnLeading = false
        meter.onTargetEdit = targetEditDisabled ? nil : { editingTarget = .speed }
        return meter
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
                sublabel: "MAX \(Int(viewModel.attemptMaxAngle))°"
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

            // SPEED card
            metricCard(
                label: "SPEED",
                valueContent: AnyView(
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text("\(Int(viewModel.currentSpeed))")
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppColors.textPrimary)
                        Text("km/h")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AppColors.accentBright)
                    }
                ),
                sublabel: "MAX \(Int(viewModel.attemptMaxSpeed))"
            )
        }
    }

    private func metricCard(label: String, valueContent: AnyView, sublabel: String?) -> some View {
        VStack(spacing: AppSpacing.xs) {
            Text(label)
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
