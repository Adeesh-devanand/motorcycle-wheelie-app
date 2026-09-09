import SwiftUI

/// §8.2 — Run settings: the history filters plus the destructive delete-all action.
///
/// Deliberately built to match `SettingsView` (the Live tab's sheet) so the two gear
/// buttons in this app open the same KIND of surface. What that alignment means
/// concretely, and why each difference went away:
///
///   - **No `presentationDetents`.** A full-height sheet with one detent: it is either
///     up or dismissed, with nothing to get stuck half-way. This sheet used to declare
///     `[.medium, .large]`, and a detent SET opens at its SMALLEST member, so it came up
///     half-height with the Delete All Runs warning below the fold.
///   - **`List`, not `Form`.** Same container as `SettingsView`, so section headers,
///     row insets and separators match.
///   - **A large navigation title**, not `.inline`.
///   - **No toolbar.** `SettingsView` has no Cancel/Apply because its changes take
///     effect as you make them, and filters now behave the same way — see below. Reset
///     moved into the list as a row, beside the other action, which is where Delete All
///     already lives.
///
/// The Reset/Apply toolbar it replaced was not just extra chrome: it meant edits sat in
/// local copies until committed, so dragging the sheet down silently discarded them.
/// `PastRunsViewModel.applyFilters()` is a no-op — the list observes `filters` directly —
/// so applying live costs nothing and the run count behind the sheet moves as you set a
/// filter. `onApply` is still called on every change and kept in the signature: it is
/// the seam the parent owns, and preserving it means this rewrite touches no other file.
struct RunSettingsSheet: View {
    @Binding var filters: PastRunsViewModel.Filters
    let onApply: () -> Void
    /// Number of runs on disk — every run, not the filtered subset, because that is
    /// what the button deletes.
    let totalRunCount: Int
    let onDeleteAll: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// Draft text for the two numeric filters. Held separately from `filters` so a
    /// partially-typed value ("1" on the way to "15") is not applied as a filter under
    /// the rider's fingers — the same reason `SettingsView` drafts its gauge maximum.
    @State private var minDurationDraft: String = ""
    @State private var minAngleDraft: String = ""
    @FocusState private var focusedField: NumericField?
    @State private var showingDeleteAllConfirm = false

    private enum NumericField: Hashable { case duration, angle }

    private var hasActiveFilters: Bool { filters != PastRunsViewModel.Filters() }

    var body: some View {
        NavigationStack {
            List {
                Section("Date Range") {
                    Toggle("From date", isOn: dateFromEnabled)
                    if filters.dateFrom != nil {
                        DatePicker("From", selection: dateFromValue,
                                   displayedComponents: .date)
                    }

                    Toggle("To date", isOn: dateToEnabled)
                    if filters.dateTo != nil {
                        DatePicker("To", selection: dateToValue,
                                   displayedComponents: .date)
                    }
                }

                Section("Minimums") {
                    HStack {
                        Text("Min Duration")
                        Spacer()
                        TextField("0", text: $minDurationDraft)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .duration)
                            .frame(width: 70)
                            .onSubmit { commitDrafts() }
                        Text("s")
                            .foregroundStyle(AppColors.textSecondary)
                    }

                    HStack {
                        Text("Min Angle")
                        Spacer()
                        TextField("0", text: $minAngleDraft)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .angle)
                            .frame(width: 70)
                            .onSubmit { commitDrafts() }
                        Text("°")
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }

                Section {
                    Button("Reset Filters") {
                        filters = PastRunsViewModel.Filters()
                        loadDrafts()
                        onApply()
                    }
                    .disabled(!hasActiveFilters)
                }

                Section {
                    Button(role: .destructive) {
                        showingDeleteAllConfirm = true
                    } label: {
                        Label("Delete All Runs", systemImage: "trash")
                    }
                    .disabled(totalRunCount == 0)
                } footer: {
                    // States the scope up front, because this sits in the same sheet as
                    // the filters: "delete all" next to a set of filters invites the
                    // reading "delete all the ones I'm looking at".
                    Text("Deletes every recorded run, including runs hidden by the filters above. This cannot be undone.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.background)
            .navigationTitle("Settings")
            .onAppear { loadDrafts() }
            .onChange(of: focusedField) { _, focused in
                // Commit when focus LEAVES a field, so intermediate keystrokes are
                // never applied as a filter.
                if focused == nil { commitDrafts() }
            }
            .confirmationDialog(
                "Delete all runs?",
                isPresented: $showingDeleteAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete All \(totalRunCount) Runs", role: .destructive) {
                    onDeleteAll()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every recorded run is permanently deleted, including runs hidden by the current filters. This cannot be undone.")
            }
        }
        // No `presentationDetents` — matches the Live tab's sheet: full height, one
        // detent, either up or dismissed.
        .preferredColorScheme(.dark)
    }

    // MARK: - Date bindings
    //
    // These write straight through to `filters` rather than into local copies, so the
    // list behind the sheet re-filters as the control moves.

    private var dateFromEnabled: Binding<Bool> {
        Binding(
            get: { filters.dateFrom != nil },
            set: { on in
                filters.dateFrom = on ? (filters.dateFrom ?? Date()) : nil
                onApply()
            }
        )
    }

    private var dateToEnabled: Binding<Bool> {
        Binding(
            get: { filters.dateTo != nil },
            set: { on in
                filters.dateTo = on ? (filters.dateTo ?? Date()) : nil
                onApply()
            }
        )
    }

    private var dateFromValue: Binding<Date> {
        Binding(
            get: { filters.dateFrom ?? Date() },
            set: { filters.dateFrom = $0; onApply() }
        )
    }

    private var dateToValue: Binding<Date> {
        Binding(
            get: { filters.dateTo ?? Date() },
            set: { filters.dateTo = $0; onApply() }
        )
    }

    // MARK: - Numeric drafts

    private func loadDrafts() {
        minDurationDraft = filters.minDuration.map { String(format: "%.1f", $0) } ?? ""
        minAngleDraft = filters.minAngle.map { String(format: "%.0f", $0) } ?? ""
    }

    /// An empty field clears that filter rather than storing 0 — a "minimum 0" filter
    /// excludes nothing and would leave `hasActiveFilters` true forever, so the empty
    /// state and the no-filter state must be the same thing.
    private func commitDrafts() {
        filters.minDuration = Double(minDurationDraft)
        filters.minAngle = Double(minAngleDraft)
        loadDrafts()
        onApply()
    }
}
