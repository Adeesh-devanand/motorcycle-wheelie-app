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

    /// An opaque, darker shade of this colour for use as an unfilled bar track —
    /// the same hue as the fill, scaled toward black so it reads as "the rest of
    /// the bar" rather than a blank grey. Uses UIColor to read the resolved sRGB
    /// components so it works for dynamically-built metric colours too.
    var darkenedTrack: Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let factor: CGFloat = 0.32
        return Color(.sRGB, red: Double(r * factor), green: Double(g * factor), blue: Double(b * factor), opacity: 1.0)
    }

    /// A darker shade of this colour, scaled toward black by `amount` (0 = unchanged,
    /// 1 = black). Used to derive the mid stop of a meter fill gradient from its accent.
    func darkened(_ amount: CGFloat) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let f = max(0, 1 - amount)
        return Color(.sRGB, red: Double(r * f), green: Double(g * f), blue: Double(b * f), opacity: Double(a))
    }

    /// A lighter shade of this colour, blended toward white by `amount` (0 = unchanged,
    /// 1 = white). Used for the bright value readout and cursor glow derived from the accent.
    func lightened(_ amount: CGFloat) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func mix(_ c: CGFloat) -> Double { Double(c + (1 - c) * amount) }
        return Color(.sRGB, red: mix(r), green: mix(g), blue: mix(b), opacity: Double(a))
    }
}

// MARK: - App Colors (Dark Theme)

/// Palette taken from the reference designs. Blue is the instrument colour, teal
/// is the angle channel, green means "best" — and there is no yellow anywhere,
/// which ui-spec §8.4 requires of the ranking scale.
enum AppColors {

    // MARK: Surfaces

    static let background = Color(hex: 0x08080B)
    /// Metric cards, run rows, chart panels.
    static let surfaceCard = Color(hex: 0x111116)
    /// The unfilled portion of a meter track.
    static let surfaceMeter = Color(hex: 0x0E0E13)
    /// Whole-screen dim behind the calibrating overlay (§7.4).
    static let surfaceOverlay = Color(hex: 0x000000, opacity: 0.82)
    /// Circular icon buttons (gear, filter, back).
    static let surfaceButton = Color(hex: 0x1A1A20)

    // MARK: Accent — blue is the instrument colour

    static let accent = Color(hex: 0x3B82F6)
    static let accentBright = Color(hex: 0x4A9EFF)
    static let accentGlow = Color(hex: 0x3B82F6, opacity: 0.22)

    // MARK: Meter fill gradient (dark navy at the bottom → moderate blue at the cursor)
    //
    // Two-stop ramp (M-UI1): the top reads as a *moderate* blue, not a bright
    // accent. `meterFillMid` is retained for any callers but is no longer used
    // by the meter fill.

    static let meterFillBottom = Color(hex: 0x0A1F3D)
    static let meterFillMid = Color(hex: 0x1656A8)
    static let meterFillTop = Color(hex: 0x1E5FB0)

    // MARK: Text

    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color(hex: 0x8E9BB0)
    static let textTertiary = Color(hex: 0x5C6675)

    // MARK: Semantic Status

    /// CALIBRATED dot, personal bests, chart maximum markers.
    static let success = Color(hex: 0x35D15A)
    static let danger = Color(hex: 0xFF5A5A)
    /// Data-quality warnings in the integrity report (§4.4-§4.6) — a degraded
    /// rate, a gap, a saturated sample. Amber is correct HERE and only here:
    /// §8.4 bars yellow from the run RANKING scale, which is a different thing.
    /// Never use this for a metric value or a rank.
    static let warning = Color(hex: 0xE0A020)

    // MARK: Metric channels (§9.4 — angle and speed are distinguishable)

    static let angleMetric = Color(hex: 0x25D0C0)
    static let speedMetric = Color(hex: 0x3B82F6)

    // MARK: Metric Range Indicators
    //
    // Deliberately blue/teal/green only. A meter that turns red or yellow when
    // the rider leaves the band would be telling them off mid-wheelie, and
    // ui-spec §8.4 bars yellow from the scale outright.

    static let metricInRange = Color(hex: 0x35D15A)
    static let metricNearRange = Color(hex: 0x25D0C0)
    static let metricOutOfRange = Color(hex: 0x3B82F6)

    // MARK: Target Band

    static let targetBandFill = Color(hex: 0x3B82F6, opacity: 0.18)
    static let targetBandStroke = Color(hex: 0x5B9BF8, opacity: 0.85)
    /// Recorded band drawn behind a chart trace (§9.4).
    static let targetBandChartAngle = Color(hex: 0x25D0C0, opacity: 0.14)
    static let targetBandChartSpeed = Color(hex: 0x3B82F6, opacity: 0.16)

    // MARK: Personal-range ranking scale (§8.4)
    //
    // Four stops, purple → blue → teal → green, interpolated by
    // `RelativeMetricColorScale` in the core. Bright green is the personal best.

    static let rankLowest = Color(hex: 0x7B5CD6)
    static let rankLow = Color(hex: 0x3B82F6)
    static let rankMid = Color(hex: 0x25D0C0)
    static let rankBest = Color(hex: 0x4ADE50)

    // MARK: Badges (LATEST / LONGEST / PERSONAL BEST)

    static let badgeFill = Color(hex: 0x1D4ED8, opacity: 0.55)
    static let badgeText = Color(hex: 0x93BBFD)
    static let badgeSuccessFill = Color(hex: 0x15803D, opacity: 0.40)
    static let badgeSuccessText = Color(hex: 0x5BE383)

    // MARK: Sort / filter chips (§8.2)

    static let chipBorder = Color.white.opacity(0.16)
    static let chipText = Color(hex: 0xB8C2D0)
    static let chipSelectedBorder = Color(hex: 0x3B82F6)
    static let chipSelectedFill = Color(hex: 0x3B82F6, opacity: 0.14)
    static let chipSelectedText = Color(hex: 0x6BA6FA)

    // MARK: Utility

    static let cardBorder = Color.white.opacity(0.06)
    static let tickMark = Color.white.opacity(0.45)
    static let gridLine = Color.white.opacity(0.10)
    /// The crisp cursor line and its marker (§7.3).
    static let cursor = Color.white
}
