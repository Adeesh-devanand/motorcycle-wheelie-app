import SwiftUI

// MARK: - TelemetryCard View

/// A styled card container with optional title and content slots.
/// Dark surface background, 12pt corners, flat (no shadow), optional subtle border.
struct TelemetryCard<Content: View>: View {
    let title: String?
    let showBorder: Bool
    @ViewBuilder let content: () -> Content

    init(
        title: String? = nil,
        showBorder: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.showBorder = showBorder
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if let title {
                Text(title)
                    .font(AppTypography.cardTitle)
                    .foregroundStyle(AppColors.textPrimary)
            }
            content()
        }
        .padding(AppSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.card)
                .strokeBorder(AppColors.cardBorder, lineWidth: showBorder ? 1 : 0)
        )
    }
}

// MARK: - ViewModifier Variant

struct TelemetryCardModifier: ViewModifier {
    var showBorder: Bool = true

    func body(content: Content) -> some View {
        content
            .padding(AppSpacing.cardPadding)
            .background(AppColors.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.card))
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.card)
                    .strokeBorder(AppColors.cardBorder, lineWidth: showBorder ? 1 : 0)
            )
    }
}

extension View {
    func telemetryCard(showBorder: Bool = true) -> some View {
        modifier(TelemetryCardModifier(showBorder: showBorder))
    }
}
