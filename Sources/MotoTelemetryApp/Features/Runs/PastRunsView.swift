import SwiftUI

/// §8 — Past Runs list. NavigationStack with sorted/filtered history,
/// swipe-delete, empty state, and filter toolbar.
struct PastRunsView: View {
    @State private var viewModel: PastRunsViewModel
    @State private var showingFilters = false

    init(repository: RunRepository) {
        _viewModel = State(wrappedValue: PastRunsViewModel(repository: repository))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    skeletonRows
                } else if viewModel.filteredRuns.isEmpty {
                    emptyState
                } else {
                    runList
                }
            }
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle("PAST RUNS")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .navigationDestination(for: UUID.self) { runID in
                RunDetailsView(runID: runID, repository: viewModel.repository)
            }
            .sheet(isPresented: $showingFilters) {
                RunFiltersSheet(filters: $viewModel.filters) {
                    viewModel.applyFilters()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Run List

    private var runList: some View {
        ScrollView {
            LazyVStack(spacing: AppSpacing.sm) {
                subtitle

                ForEach(viewModel.filteredRuns) { run in
                    NavigationLink(value: run.id) {
                        RunHistoryRow(
                            run: run,
                            colorScale: viewModel.colorScale,
                            fieldAnchors: viewModel.fieldAnchors
                        )
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            viewModel.deleteRun(id: run.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, AppSpacing.screenPadding)
        }
    }

    private var subtitle: some View {
        Text(viewModel.subtitleText)
            .font(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, AppSpacing.xs)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: AppSpacing.lg) {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Skeleton

    private var skeletonRows: some View {
        ScrollView {
            LazyVStack(spacing: AppSpacing.sm) {
                ForEach(0..<5, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: AppSpacing.CornerRadius.card)
                        .fill(AppColors.surfaceCard)
                        .frame(height: 80)
                        .shimmer()
                }
            }
            .padding(.horizontal, AppSpacing.screenPadding)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingFilters = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .accessibilityLabel("Filters")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort", selection: $viewModel.sortKey) {
                    Label("Time", systemImage: "clock").tag(PastRunsViewModel.SortKey.time)
                    Label("Angle", systemImage: "angle").tag(PastRunsViewModel.SortKey.angle)
                    Label("Speed", systemImage: "speedometer").tag(PastRunsViewModel.SortKey.speed)
                }
                Divider()
                Toggle("Descending", isOn: $viewModel.sortDescending)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .accessibilityLabel("Sort")
            }
        }
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
