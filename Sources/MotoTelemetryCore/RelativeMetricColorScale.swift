import Foundation

// MARK: - Color representation (pure numeric, no SwiftUI/CoreGraphics)

/// A color as linear sRGB components in [0,1]. The app layer maps this to
/// platform colors; keeping it numeric here is what lets PurityTests pass.
public struct LinearRGB: Equatable, Sendable {
    public let r: Double
    public let g: Double
    public let b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Hex string without leading #, uppercase, e.g. "32E85B".
    public var hex: String {
        let ri = Int(round(sRGBTransferForward(r) * 255))
        let gi = Int(round(sRGBTransferForward(g) * 255))
        let bi = Int(round(sRGBTransferForward(b) * 255))
        return String(format: "%02X%02X%02X", ri, gi, bi)
    }

    /// sRGB (gamma-encoded) component values in [0,1].
    public var sRGB: (r: Double, g: Double, b: Double) {
        (sRGBTransferForward(r), sRGBTransferForward(g), sRGBTransferForward(b))
    }
}

// MARK: - sRGB ↔ Linear transfer functions

/// sRGB gamma → linear (inverse EOTF).
private func sRGBTransferInverse(_ c: Double) -> Double {
    if c <= 0.04045 {
        return c / 12.92
    }
    return pow((c + 0.055) / 1.055, 2.4)
}

/// Linear → sRGB gamma (EOTF).
private func sRGBTransferForward(_ c: Double) -> Double {
    if c <= 0.0031308 {
        return c * 12.92
    }
    return 1.055 * pow(c, 1.0 / 2.4) - 0.055
}

// MARK: - OKLab / OKLCH conversion

/// Intermediate Lab representation for colour-space maths.
private struct OKLab {
    var L: Double
    var a: Double
    var b: Double
}

/// Cylindrical form of OKLab — Lightness, Chroma, Hue (radians).
private struct OKLCH {
    var L: Double
    var C: Double
    var h: Double // radians
}

/// Linear RGB → OKLab via the Björn Ottosson method.
/// Reference: https://bottosson.github.io/posts/oklab/
private func linearRGBToOKLab(_ rgb: LinearRGB) -> OKLab {
    let l_ = 0.4122214708 * rgb.r + 0.5363325363 * rgb.g + 0.0514459929 * rgb.b
    let m_ = 0.2119034982 * rgb.r + 0.6806995451 * rgb.g + 0.1073969566 * rgb.b
    let s_ = 0.0883024619 * rgb.r + 0.2817188376 * rgb.g + 0.6299787005 * rgb.b

    let l = cbrt(l_)
    let m = cbrt(m_)
    let s = cbrt(s_)

    return OKLab(
        L: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    )
}

/// OKLab → Linear RGB (inverse of above).
private func okLabToLinearRGB(_ lab: OKLab) -> LinearRGB {
    let l = lab.L + 0.3963377774 * lab.a + 0.2158037573 * lab.b
    let m = lab.L - 0.1055613458 * lab.a - 0.0638541728 * lab.b
    let s = lab.L - 0.0894841775 * lab.a - 1.2914855480 * lab.b

    let l_ = l * l * l
    let m_ = m * m * m
    let s_ = s * s * s

    let r = +4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_
    let g = -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_
    let b = -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_

    // Clamp to [0,1] — out-of-gamut values can arise from OKLCH interpolation.
    return LinearRGB(
        r: min(max(r, 0), 1),
        g: min(max(g, 0), 1),
        b: min(max(b, 0), 1)
    )
}

private func okLabToOKLCH(_ lab: OKLab) -> OKLCH {
    let C = sqrt(lab.a * lab.a + lab.b * lab.b)
    let h = atan2(lab.b, lab.a)
    return OKLCH(L: lab.L, C: C, h: h)
}

private func oklchToOKLab(_ lch: OKLCH) -> OKLab {
    OKLab(L: lch.L, a: lch.C * cos(lch.h), b: lch.C * sin(lch.h))
}

// MARK: - OKLCH interpolation with shortest-arc hue

/// Interpolate two OKLCH colours, taking the shortest arc for hue.
private func interpolateOKLCH(_ a: OKLCH, _ b: OKLCH, t: Double) -> OKLCH {
    let L = a.L + (b.L - a.L) * t
    let C = a.C + (b.C - a.C) * t

    // Shortest-arc hue interpolation
    var dh = b.h - a.h
    if dh > .pi { dh -= 2 * .pi }
    if dh < -.pi { dh += 2 * .pi }
    let h = a.h + dh * t

    return OKLCH(L: L, C: C, h: h)
}

// MARK: - Hex parsing helper

private func linearRGBFromHex(_ hex: String) -> LinearRGB {
    let chars = Array(hex)
    let ri = Int(String(chars[0...1]), radix: 16)!
    let gi = Int(String(chars[2...3]), radix: 16)!
    let bi = Int(String(chars[4...5]), radix: 16)!
    return LinearRGB(
        r: sRGBTransferInverse(Double(ri) / 255.0),
        g: sRGBTransferInverse(Double(gi) / 255.0),
        b: sRGBTransferInverse(Double(bi) / 255.0)
    )
}

// MARK: - RelativeMetricColorScale

/// Normalises metric values per-field to [0,1] against the rider's personal
/// range, then maps to a four-stop gradient (indigo → blue → teal → green).
///
/// Each metric field (duration, angle, speed) is normalised INDEPENDENTLY.
/// Anchors come from the full date scope BEFORE row-level filters hide rows,
/// so colours never jump when the user adjusts a filter or sorts.
public struct RelativeMetricColorScale: Sendable {

    // The four canonical stops from ui-spec §8.4.
    // Pre-converted to OKLCH at init time for fast interpolation.
    private static let stopHexes = ["6559D8", "2F86D7", "10B5B4", "32E85B"]
    private static let stopPositions: [Double] = [0.0, 0.33, 0.66, 1.0]

    private let stopsOKLCH: [OKLCH]

    public init() {
        stopsOKLCH = Self.stopHexes.map { hex in
            let rgb = linearRGBFromHex(hex)
            let lab = linearRGBToOKLab(rgb)
            return okLabToOKLCH(lab)
        }
    }

    // MARK: Normalisation

    /// Compute `t` for a single value given field anchors.
    ///
    /// - Parameters:
    ///   - value: The metric value for this field.
    ///   - fieldMinimum: Personal worst (lowest value) in the active date scope,
    ///     computed BEFORE row-level metric filters.
    ///   - fieldMaximum: Personal best (highest value) in the same scope.
    /// - Returns: `t` clamped to [0,1]. If min == max, returns 1.0 because every
    ///   value equals the personal best (ui-spec §8.4).
    public func normalise(value: Double, fieldMinimum: Double, fieldMaximum: Double) -> Double {
        // All equal → every row shares the personal best → t = 1.
        guard fieldMaximum != fieldMinimum else { return 1.0 }
        let t = (value - fieldMinimum) / (fieldMaximum - fieldMinimum)
        return min(max(t, 0.0), 1.0)
    }

    // MARK: Colour mapping

    /// Map a normalised `t ∈ [0,1]` to a colour via OKLCH interpolation between
    /// the four piecewise stops.
    public func color(forT t: Double) -> LinearRGB {
        let clamped = min(max(t, 0.0), 1.0)

        // Find the segment [i, i+1] that contains `clamped`.
        let positions = Self.stopPositions
        var segIndex = 0
        for i in 0 ..< (positions.count - 1) {
            if clamped >= positions[i] { segIndex = i }
        }

        let segStart = positions[segIndex]
        let segEnd = positions[segIndex + 1]
        let localT = (clamped - segStart) / (segEnd - segStart)

        let interpolated = interpolateOKLCH(stopsOKLCH[segIndex], stopsOKLCH[segIndex + 1], t: localT)
        let lab = oklchToOKLab(interpolated)
        return okLabToLinearRGB(lab)
    }

    /// Convenience: normalise then map to colour in one call.
    public func color(value: Double, fieldMinimum: Double, fieldMaximum: Double) -> LinearRGB {
        let t = normalise(value: value, fieldMinimum: fieldMinimum, fieldMaximum: fieldMaximum)
        return color(forT: t)
    }
}
