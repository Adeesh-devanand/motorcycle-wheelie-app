import SwiftUI

/// Live Wheelie screen — header with centered status pill + gear button,
/// dual vertical meters (angle left, speed right, mirrored), and three
/// bottom metric cards: ANGLE / WHEELIE TIME / SPEED.
struct LiveWheelieView: View {
    @State private var viewModel: LiveWheelieViewModel
    @State private var showSettings = false
    @State private var showTargetEditor = false
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
        .sheet(isPresented: $showTargetEditor) {
            TargetRangeEditor(
                preferences: viewModel.preferences,
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
        HStack(spacing: AppSpacing.meterGap) {
            // ANGLE meter — labels on left
            angleMeter

            // SPEED meter — labels on right, with max chip above
            speedMeter
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
        meter.onTargetEdit = targetEditDisabled ? nil : { showTargetEditor = true }
        return meter
    }

    private var speedMeter: some View {
        VStack(spacing: AppSpacing.xs) {
            // MAX chip above the speed meter
            gaugeMaxChip

            speedMeterContent
        }
    }

    private var speedMeterContent: some View {
        let speedUnit = viewModel.preferences.speedUnit == .kph ? "km/h" : "mph"
        var meter = VerticalTelemetryMeter(
            value: viewModel.currentSpeed,
            range: 0...viewModel.preferences.speedGaugeMaximum,
            targetBand: viewModel.preferences.speedTarget,
            unit: speedUnit,
            label: "SPEED",
            valueFont: AppTypography.meterValue,
            rangeStatus: viewModel.speedInRange
        )
        meter.labelsOnLeading = false
        meter.onTargetEdit = targetEditDisabled ? nil : { showTargetEditor = true }
        return meter
    }

    /// Small rounded chip: "MAX 100 km/h" with pencil + chevron.
    private var gaugeMaxChip: some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: "pencil")
                .font(.system(size: 11))
            Text("MAX \(Int(viewModel.preferences.speedGaugeMaximum)) \(viewModel.preferences.speedUnit == .kph ? "km/h" : "mph")")
                .font(.system(size: 13, weight: .medium))
            Image(systemName: "chevron.right")
                .font(.system(size: 10))
        }
        .foregroundStyle(AppColors.textSecondary)
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .background(AppColors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.chip))
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
