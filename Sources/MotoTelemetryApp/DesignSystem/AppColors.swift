import SwiftUI

// MARK: - Color Hex Initializer

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}

// MARK: - App Colors (Dark Theme)

enum AppColors {
    // MARK: Surfaces
    static let background = Color(hex: 0x0A0A0F)
    static let surfaceCard = Color(hex: 0x16161F)
    static let surfaceMeter = Color(hex: 0x1E1E2A)

    // MARK: Accent
    static let accent = Color(hex: 0x6C5CE7)
    static let accentGlow = Color(hex: 0x6C5CE7, opacity: 0.20)

    // MARK: Text
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.60)

    // MARK: Semantic Status
    static let success = Color(hex: 0x00B894)
    static let warning = Color(hex: 0xFDCB6E)
    static let danger = Color(hex: 0xFF6B6B)

    // MARK: Metric Range Indicators
    static let metricInRange = success
    static let metricNearRange = warning
    static let metricOutOfRange = danger

    // MARK: Target Band
    static let targetBandFill = Color(hex: 0x6C5CE7, opacity: 0.10)
    static let targetBandStroke = Color(hex: 0x6C5CE7, opacity: 0.40)

    // MARK: Utility
    static let cardBorder = Color.white.opacity(0.05)
}
