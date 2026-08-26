import SwiftUI

/// §8.2 — Filter sheet: date range, bike, min duration, min angle. Apply/Reset.
struct RunFiltersSheet: View {
    @Binding var filters: PastRunsViewModel.Filters
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    // Local editing copies
    @State private var dateFrom: Date?
    @State private var dateTo: Date?
    @State private var minDuration: String = ""
    @State private var minAngle: String = ""

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
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.background)
            .navigationTitle("Filters")
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
        }
        .presentationDetents([.medium])
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
