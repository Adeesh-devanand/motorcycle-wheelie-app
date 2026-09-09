import SwiftUI

/// §8 — Past Runs list. Custom nav, sort chips, column headers, filtered history.
struct PastRunsView: View {
    @State private var viewModel: PastRunsViewModel
    @State private var showingSettings = false
    @State private var runPendingDelete: WheelieRun?
    @State private var showingDeleteRunConfirm = false
    @Environment(\.dismiss) private var dismiss

    init(repository: RunRepository) {
        _viewModel = State(wrappedValue: PastRunsViewModel(repository: repository))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    navRow
                    scrollContent
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: UUID.self) { runID in
                RunDetailsView(runID: runID, repository: viewModel.repository)
            }
            .sheet(isPresented: $showingSettings) {
                RunSettingsSheet(
                    filters: $viewModel.filters,
                    onApply: { viewModel.applyFilters() },
                    totalRunCount: viewModel.repository.allRuns.count,
                    onDeleteAll: { viewModel.deleteAllRuns() }
                )
            }
            .confirmationDialog(
                "Delete this run?",
                isPresented: $showingDeleteRunConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete Run", role: .destructive) {
                    if let run = runPendingDelete {
                        viewModel.deleteRun(id: run.id)
                    }
                    runPendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    runPendingDelete = nil
                }
            } message: {
                if let run = runPendingDelete {
                    Text(Self.deleteSummary(for: run))
                } else {
                    Text("This cannot be undone.")
                }
            }
            // The delete-all confirmation that used to be attached here moved INTO
            // `RunSettingsSheet`. A `confirmationDialog` on the view beneath a presented
            // sheet does not appear while that sheet is up, so triggering it from inside
            // the sheet would have looked like a dead button.
        }
        .preferredColorScheme(.dark)
    }

    /// One line identifying the run being deleted, so the dialog confirms a
    /// specific run rather than an anonymous one.
    private static func deleteSummary(for run: WheelieRun) -> String {
        let when = run.startedAt.formatted(date: .abbreviated, time: .shortened)
        let seconds = String(format: "%.1f", run.duration)
        let angle = String(format: "%.0f", run.maxAngle)
        return "\(when) · \(seconds)s · \(angle)° max. This cannot be undone."
    }

    // MARK: - Nav Row

    private var navRow: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(AppColors.textSecondary)
            }
            .accessibilityLabel("Back")

            Spacer()

            if viewModel.hasRuns {
                // ONE control, top right, gear, opening ONE sheet. There used to be two
                // icons — an `ellipsis` menu here holding Delete All and a separate
                // `slider.horizontal.3` button down in the sort-chip row for Filters —
                // then briefly one gear presenting a menu of two items. The menu is gone
                // too: a menu whose entries are "Filters" (which just opens the sheet)
                // and "Delete All Runs" (which belongs beside the filters it warns you
                // it ignores) is a tap that carries no decision.
                //
                // Merging also fixed a real dead end: the filter button lived inside
                // `runListContent`, so filtering down to zero runs swapped in the empty
                // state and took the only way to loosen the filters off screen with it.
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(width: 44, height: 44)
                        .background(AppColors.surfaceButton, in: Circle())
                }
                .accessibilityLabel("Run settings")
                .accessibilityHint("Filters and delete all runs")
            }
        }
        .padding(.horizontal, AppSpacing.screenPadding)
        .padding(.vertical, AppSpacing.sm)
    }

    // MARK: - Scroll Content

    private var scrollContent: some View {
        Group {
            if viewModel.isLoading {
                skeletonContent
            } else if viewModel.filteredRuns.isEmpty {
                emptyState
            } else {
                runListContent
            }
        }
    }

    private var runListContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                titleSection
                sortChipRow
                captionLabel
                columnHeaders
                runRows
            }
            .padding(.horizontal, AppSpacing.screenPadding)
            .padding(.bottom, AppSpacing.xl)
        }
    }

    // MARK: - Title Section

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("PAST RUNS")
                .font(.system(size: 36, weight: .black))
                .tracking(1.2)
                .foregroundStyle(AppColors.textPrimary)

            Text(viewModel.subtitleText)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(AppColors.textSecondary)
        }
    }

    // MARK: - Sort Chip Row

    /// Four sort chips. The filter control that used to sit at the trailing edge
    /// here has moved into the single gear menu in the nav row, which also gives the
    /// chips the full width instead of scrolling them under a pinned button.
    private var sortChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                sortChip(key: .recency, label: "RECENT")
                sortChip(key: .time, label: "TIME")
                sortChip(key: .angle, label: "ANGLE")
                sortChip(key: .speed, label: "SPEED")
            }
        }
        .frame(height: 44)
    }

    private func sortChip(key: PastRunsViewModel.SortKey, label: String) -> some View {
        let isSelected = viewModel.sortKey == key
        return Button {
            if viewModel.sortKey == key {
                viewModel.sortDescending.toggle()
            } else {
                viewModel.sortKey = key
                viewModel.sortDescending = true
            }
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Text(label)
                    .font(.system(size: 15, weight: .medium))
                // The arrow shows the ACTIVE direction, and only on the selected
                // chip: a static up/down glyph on three inactive chips says
                // nothing, and dropping it is part of what lets four chips fit.
                if isSelected {
                    Image(systemName: viewModel.sortDescending ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(isSelected ? AppColors.chipSelectedText : AppColors.chipText)
            .padding(.horizontal, AppSpacing.md)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? AppColors.chipSelectedFill : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? AppColors.chipSelectedBorder : AppColors.chipBorder,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(label.lowercased())")
        .accessibilityValue(isSelected
            ? (viewModel.sortDescending ? "selected, descending" : "selected, ascending")
            : "not selected")
    }

    // MARK: - Caption

    private var captionLabel: some View {
        Text("Color ranked to your personal range")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(AppColors.textTertiary)
    }

    // MARK: - Column Headers

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            // Spacer matching the time column width
            Color.clear.frame(width: 96)

            HStack(spacing: 0) {
                Text("TIME")
                    .frame(maxWidth: .infinity)
                Text("ANGLE")
                    .frame(maxWidth: .infinity)
                Text("SPEED")
                    .frame(maxWidth: .infinity)
            }

            // Space for chevron
            Color.clear.frame(width: 20)
        }
        .font(.system(size: 13, weight: .medium))
        .tracking(0.8)
        .foregroundStyle(AppColors.textSecondary)
    }

    // MARK: - Run Rows

    /// A run earns a metric badge only when it holds the field maximum, there is
    /// more than one run to compare against (a lone run is not "the longest"),
    /// and that maximum is a real positive value — so a set of runs that all
    /// recorded zero speed does not light up FASTEST on every row. Ties award the
    /// badge to every run holding the max, which is correct: two identical-max
    /// runs are jointly the best.
    private func isSuperlative(_ value: Double, max: Double) -> Bool {
        viewModel.filteredRuns.count > 1 && max > 0 && value == max
    }

    private var runRows: some View {
        LazyVStack(spacing: AppSpacing.sm) {
            ForEach(Array(viewModel.filteredRuns.enumerated()), id: \.element.id) { index, run in
                NavigationLink(value: run.id) {
                    RunHistoryRow(
                        run: run,
                        colorScale: viewModel.colorScale,
                        fieldAnchors: viewModel.fieldAnchors,
                        isLatest: index == 0 && viewModel.sortKey == .recency && viewModel.sortDescending,
                        isLongest: isSuperlative(run.duration, max: viewModel.fieldAnchors.durationMax),
                        isFastest: isSuperlative(run.maxSpeed, max: viewModel.fieldAnchors.speedMax),
                        isHighest: isSuperlative(run.maxAngle, max: viewModel.fieldAnchors.angleMax)
                    )
                }
                .buttonStyle(.plain)
                // Long-press to delete. These rows are cards in a LazyVStack, not
                // List rows, so `.swipeActions` is unavailable here; a context
                // menu is the affordance that works without rebuilding the list
                // as a List and losing the card layout.
                .contextMenu {
                    Button(role: .destructive) {
                        runPendingDelete = run
                        showingDeleteRunConfirm = true
                    } label: {
                        Label("Delete Run", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: AppSpacing.lg) {
            Spacer()

            if viewModel.hasActiveFilters {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(AppColors.textSecondary)
                Text("No runs match these filters")
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)
                Button("Clear filters") {
                    viewModel.resetFilters()
                }
                .buttonStyle(.bordered)
            } else {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 40))
                    .foregroundStyle(AppColors.textSecondary)
                Text("No runs yet")
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)
                Text("Complete a wheelie to see it here.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Skeleton

    private var skeletonContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                // Title placeholder
                RoundedRectangle(cornerRadius: 6)
                    .fill(AppColors.surfaceCard)
                    .frame(width: 180, height: 30)
                    .shimmer()

                // Subtitle placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppColors.surfaceCard)
                    .frame(width: 120, height: 16)
                    .shimmer()

                // Chip row placeholder
                HStack(spacing: AppSpacing.sm) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 10)
                            .fill(AppColors.surfaceCard)
                            .frame(width: 80, height: 44)
                            .shimmer()
                    }
                }

                // Row placeholders — grey capsules, no fake numbers
                ForEach(0..<5, id: \.self) { _ in
                    skeletonRow
                }
            }
            .padding(.horizontal, AppSpacing.screenPadding)
        }
    }

    private var skeletonRow: some View {
        HStack(spacing: AppSpacing.md) {
            // Time column placeholder
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 60, height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.04))
                    .frame(width: 48, height: 10)
            }
            .frame(width: 96, alignment: .leading)

            // Metric placeholders
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(spacing: AppSpacing.xs) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 44, height: 18)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.04))
                            .frame(height: 4)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Color.clear.frame(width: 20)
        }
        .padding(.vertical, AppSpacing.lg)
        .padding(.horizontal, AppSpacing.cardPadding)
        .background(AppColors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.card)
                .strokeBorder(AppColors.cardBorder, lineWidth: 1)
        )
        .frame(height: 80)
        .shimmer()
    }
}

// MARK: - Shimmer Modifier

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.05), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase)
                .onAppear {
                    withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                        phase = 300
                    }
                }
            )
            .clipped()
    }
}

private extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}
