import SwiftUI

// MARK: - App Spacing

enum AppSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32

    // MARK: Semantic Spacing
    static let screenPadding: CGFloat = 16
    static let cardPadding: CGFloat = 12
    static let meterGap: CGFloat = 16

    // MARK: Corner Radii
    enum CornerRadius {
        static let card: CGFloat = 12
        static let meter: CGFloat = 16
        static let chip: CGFloat = 8
        static let button: CGFloat = 10
    }
}
