import SwiftUI

/// §8.2 — Run settings: the history filters plus the destructive delete-all action.
///
/// This was `RunFiltersSheet`, reachable only through a gear MENU whose two items were
/// "Filters" and "Delete All Runs". A menu of two, one of which just opens this sheet,
/// is a tap that carries no decision — so the gear now presents this sheet directly and
/// the delete action moved in here, at the bottom, behind its own confirmation.
///
/// The confirmation lives HERE rather than on `PastRunsView` deliberately. A
/// `confirmationDialog` attached to the view underneath a presented sheet does not
/// appear while the sheet is up; the rider would tap Delete All and see nothing happen.
struct RunSettingsSheet: View {
    @Binding var filters: PastRunsViewModel.Filters
    let onApply: () -> Void
    /// Number of runs on disk — every run, not the filtered subset, because that is
    /// what the button deletes.
    let totalRunCount: Int
    let onDeleteAll: () -> Void
    @Environment(\.dismiss) private var dismiss

    // Local editing copies
    @State private var dateFrom: Date?
    @State private var dateTo: Date?
    @State private var minDuration: String = ""
    @State private var minAngle: String = ""
    @State private var showingDeleteAllConfirm = false
    /// Which detent the sheet is showing. Seeded to `.large` because a
    /// `presentationDetents` SET opens at its SMALLEST member — so declaring
    /// `[.medium, .large]` without a selection opened the sheet half-height and cut off
    /// the Delete All Runs footer, which is the one line explaining that the button
    /// ignores the filters above it. A warning you have to scroll to find is not a
    /// warning. Both detents are still offered, so the sheet can be dragged down.
    @State private var detent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            Form {
                Section("Date Range") {
                    Toggle("From date", isOn: dateFromBinding)
                    if dateFrom != nil {
                        DatePicker("From", selection: Binding(
                            get: { dateFrom ?? Date() },
                            set: { dateFrom = $0 }
                        ), displayedComponents: .date)
                    }

                    Toggle("To date", isOn: dateToBinding)
                    if dateTo != nil {
                        DatePicker("To", selection: Binding(
                            get: { dateTo ?? Date() },
                            set: { dateTo = $0 }
                        ), displayedComponents: .date)
                    }
                }

                Section("Minimums") {
                    HStack {
                        Text("Min Duration (s)")
                        Spacer()
                        TextField("0", text: $minDuration)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }

                    HStack {
                        Text("Min Angle (°)")
                        Spacer()
                        TextField("0", text: $minAngle)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showingDeleteAllConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            Label("Delete All Runs", systemImage: "trash")
                            Spacer()
                        }
                    }
                    .disabled(totalRunCount == 0)
                } footer: {
                    // States the scope up front, because the sheet the button sits in is
                    // the filter sheet: "delete all" next to a set of filters invites
                    // the reading "delete all the ones I'm looking at".
                    Text("Deletes every recorded run, including runs hidden by the "
                         + "filters above. This cannot be undone.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        resetAll()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        applyAndDismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { loadFromBinding() }
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
                Text("Every recorded run is permanently deleted, including runs "
                     + "hidden by the current filters. This cannot be undone.")
            }
        }
        // `selection:` is what makes this open at `.large`. Without it the set's
        // smallest member wins and the destructive action's explanation sits below the
        // fold — see `detent` above.
        .presentationDetents([.medium, .large], selection: $detent)
        .preferredColorScheme(.dark)
    }

    // MARK: - Helpers

    private var dateFromBinding: Binding<Bool> {
        Binding(
            get: { dateFrom != nil },
            set: { dateFrom = $0 ? (filters.dateFrom ?? Date()) : nil }
        )
    }

    private var dateToBinding: Binding<Bool> {
        Binding(
            get: { dateTo != nil },
            set: { dateTo = $0 ? (filters.dateTo ?? Date()) : nil }
        )
    }

    private func loadFromBinding() {
        dateFrom = filters.dateFrom
        dateTo = filters.dateTo
        minDuration = filters.minDuration.map { String(format: "%.1f", $0) } ?? ""
        minAngle = filters.minAngle.map { String(format: "%.0f", $0) } ?? ""
    }

    private func applyAndDismiss() {
        filters.dateFrom = dateFrom
        filters.dateTo = dateTo
        filters.minDuration = Double(minDuration)
        filters.minAngle = Double(minAngle)
        onApply()
        dismiss()
    }

    private func resetAll() {
        dateFrom = nil
        dateTo = nil
        minDuration = ""
        minAngle = ""
        filters = PastRunsViewModel.Filters()
        onApply()
        dismiss()
    }
}
