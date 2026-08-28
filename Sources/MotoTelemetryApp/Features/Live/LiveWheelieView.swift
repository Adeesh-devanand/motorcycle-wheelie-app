import SwiftUI

/// Live Wheelie screen — header with centered status pill + gear button,
/// dual vertical meters (angle left, speed right, mirrored), and three
/// bottom metric cards: ANGLE / WHEELIE TIME / SPEED.
struct LiveWheelieView: View {
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
         bikeStore: BikeProfileStore) {
        self.bikeStore = bikeStore
        _viewModel = State(wrappedValue: LiveWheelieViewModel(
            calibrationService: calibrationService,
            preferences: preferences,
            recorder: recorder
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

            if showCalibrationOverlay {
                CalibrationOverlay(
                    state: viewModel.calibrationState,
                    onDismiss: { viewModel.requestRecalibration() },
                    blockingReason: viewModel.blockingReason
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showCalibrationOverlay)
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
            unit: viewModel.preferences.speedUnit == .kph ? "km/h" : "mph",
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
                        Text(viewModel.preferences.speedUnit == .kph ? "km/h" : "mph")
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

    private var showCalibrationOverlay: Bool {
        switch viewModel.calibrationState {
        case .calibrating, .unavailable, .failed:
            return true
        default:
            return false
        }
    }

    private var targetEditDisabled: Bool {
        viewModel.eventActive || !viewModel.isCalibrated
    }
}
