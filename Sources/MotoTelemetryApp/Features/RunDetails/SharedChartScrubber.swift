import SwiftUI

/// §9.4 — Draggable vertical hairline that syncs across angle and speed charts.
/// Provides a @Binding<TimeInterval?> for shared scrubber position and a tooltip.
struct SharedChartScrubber: View {
    @Binding var selectedTime: TimeInterval?
    let domain: ClosedRange<TimeInterval>
    let chartWidth: CGFloat
    let valueAtTime: (_ time: TimeInterval) -> (angle: Double, speed: Double)

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Transparent hit area for drag gesture
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(scrubGesture(in: geo.size.width))
                    .onTapGesture { location in
                        let time = timeFromX(location.x, width: geo.size.width)
                        selectedTime = time
                    }

                // Hairline + tooltip when active
                if let time = selectedTime {
                    let x = xFromTime(time, width: geo.size.width)

                    // Vertical hairline
                    Rectangle()
                        .fill(AppColors.textPrimary.opacity(0.7))
                        .frame(width: 1)
                        .offset(x: x)

                    // Tooltip bubble above
                    tooltipBubble(time: time)
                        .offset(x: x - 40, y: -28)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Chart scrubber")
        .accessibilityValue(scrubberAccessibilityValue)
        .accessibilityAdjustableAction { direction in
            adjustScrubber(direction: direction)
        }
    }

    // MARK: - Tooltip

    private func tooltipBubble(time: TimeInterval) -> some View {
        let values = valueAtTime(time)
        return VStack(spacing: 2) {
            Text(formatElapsed(time))
                .font(.system(.caption2, design: .monospaced, weight: .medium))
            HStack(spacing: AppSpacing.xs) {
                Text("\(String(format: "%.0f", values.angle))°")
                    .foregroundStyle(Color(hex: 0x10B9B7))
                Text("\(String(format: "%.0f", values.speed))")
                    .foregroundStyle(Color(hex: 0x238CD8))
            }
            .font(.system(.caption2, design: .monospaced, weight: .medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(AppColors.surfaceCard.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .frame(width: 80)
    }

    // MARK: - Gesture

    private func scrubGesture(in width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isDragging = true
                let time = timeFromX(value.location.x, width: width)
                selectedTime = time
            }
            .onEnded { _ in
                isDragging = false
            }
    }

    // MARK: - Conversions

    private func timeFromX(_ x: CGFloat, width: CGFloat) -> TimeInterval {
        let fraction = max(0, min(1, x / width))
        let span = domain.upperBound - domain.lowerBound
        return domain.lowerBound + span * Double(fraction)
    }

    private func xFromTime(_ time: TimeInterval, width: CGFloat) -> CGFloat {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return 0 }
        let fraction = (time - domain.lowerBound) / span
        return CGFloat(fraction) * width
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let mins = Int(t) / 60
        let secs = t - Double(mins * 60)
        return String(format: "%d:%05.2f", mins, secs)
    }

    // MARK: - Accessibility

    private var scrubberAccessibilityValue: String {
        guard let time = selectedTime else { return "No selection" }
        let values = valueAtTime(time)
        return "\(formatElapsed(time)), \(String(format: "%.0f", values.angle)) degrees, \(String(format: "%.0f", values.speed)) km/h"
    }

    private func adjustScrubber(direction: AccessibilityAdjustmentDirection) {
        let span = domain.upperBound - domain.lowerBound
        let step = span / 20.0
        let current = selectedTime ?? domain.lowerBound
        switch direction {
        case .increment:
            selectedTime = min(current + step, domain.upperBound)
        case .decrement:
            selectedTime = max(current - step, domain.lowerBound)
        @unknown default:
            break
        }
    }
}
