import SwiftUI

// MARK: - App Typography

enum AppTypography {
    /// Primary meter readout — large monospaced digits (56pt)
    static let meterValue: Font = .system(size: 56, weight: .bold, design: .monospaced)

    /// Secondary meter readout — smaller monospaced digits (32pt)
    static let meterValueSmall: Font = .system(size: 32, weight: .bold, design: .monospaced)

    /// Meter label — uppercase 11pt medium
    static let meterLabel: Font = .system(size: 11, weight: .medium)

    /// Card title — 15pt semibold
    static let cardTitle: Font = .system(size: 15, weight: .semibold)

    /// Card subtitle — 13pt regular, secondary color
    static let cardSubtitle: Font = .system(size: 13)

    /// Section header — uppercase 13pt medium, 0.5pt tracking
    static let sectionHeader: Font = .system(size: 13, weight: .medium)

    /// Body text — 15pt regular
    static let bodyText: Font = .system(size: 15)

    /// Chip / pill label — 12pt medium
    static let chipLabel: Font = .system(size: 12, weight: .medium)
}

// MARK: - View Modifiers for Styled Text

extension View {
    /// Applies meter label styling: uppercased, secondary color
    func meterLabelStyle() -> some View {
        self
            .font(AppTypography.meterLabel)
            .textCase(.uppercase)
            .foregroundStyle(AppColors.textSecondary)
    }

    /// Applies section header styling: uppercased, 0.5pt tracking, secondary color
    func sectionHeaderStyle() -> some View {
        self
            .font(AppTypography.sectionHeader)
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(AppColors.textSecondary)
    }
}
