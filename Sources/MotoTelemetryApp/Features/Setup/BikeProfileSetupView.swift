import MotoTelemetryCore
import SwiftUI

/// Create/edit bikes: name, list + select active.
///
/// Mount alignment is NOT captured here. It is performed at launch in the live
/// flow (`Features/Live/SwipeAlignmentScreen.swift`). An earlier version of this
/// screen showed a rest-gravity → accelerate → cross-product "wizard" that never
/// advanced past step 1 and whose completion copy claimed a rotation matrix had
/// been saved — both untrue. It was removed; do not restore it. See the Mount
/// Alignment section below for the honest replacement.
struct BikeProfileSetupView: View {
    @State private var store: BikeProfileStore
    @State private var isAddingNew = false
    @State private var editingProfile: BikeProfile?
    @State private var newBikeName = ""

    init(store: BikeProfileStore) {
        _store = State(wrappedValue: store)
    }

    var body: some View {
        List {
            Section("Bikes") {
                ForEach(store.profiles) { profile in
                    bikeRow(profile)
                }
                .onDelete { offsets in
                    for idx in offsets {
                        store.delete(id: store.profiles[idx].id)
                    }
                }

                Button {
                    isAddingNew = true
                } label: {
                    Label("Add Bike", systemImage: "plus.circle")
                }
            }

            Section("Mount Alignment") {
                alignmentSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.background)
        .navigationTitle("Bike Profiles")
        .alert("New Bike", isPresented: $isAddingNew) {
            TextField("Bike name", text: $newBikeName)
            Button("Add") {
                guard !newBikeName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                let profile = store.add(name: newBikeName)
                store.selectedProfileID = profile.id
                newBikeName = ""
            }
            Button("Cancel", role: .cancel) { newBikeName = "" }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Bike Row

    private func bikeRow(_ profile: BikeProfile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(profile.name)
                    .font(.body)
                    .foregroundStyle(AppColors.textPrimary)

                // Removed: an "Aligned"/"Not aligned" status derived from
                // profile.mountAlignment. On the calibrate-once branch nothing
                // ever writes mountAlignment back onto a BikeProfile (alignment
                // is resolved at launch and consumed live, not persisted), so
                // this row could only ever read "Not aligned" while implying
                // per-bike alignment is a thing you can store — the same false
                // persistence promise removed from the alignment section.
            }

            Spacer()

            if store.selectedProfileID == profile.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                    .accessibilityLabel("Active bike")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedProfileID = profile.id
        }
        .accessibilityLabel("\(profile.name)\(store.selectedProfileID == profile.id ? ", active" : "")")
    }

    // MARK: - Alignment Flow

    // Honest replacement for the removed alignment "wizard". This screen does
    // NOT capture mount alignment and does not save a profile: this branch
    // (calibrate-once) drops BikeProfile persistence and re-derives alignment
    // from the swipe gesture at launch. So there is nothing to start, nothing
    // to progress, and nothing to persist here — only an explanation of where
    // alignment actually happens.
    private var alignmentSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Captured at launch")
                .font(.headline)
                .foregroundStyle(AppColors.textPrimary)
            Text("Mount alignment is measured each time you start a ride, in the "
                 + "swipe alignment step of the live flow. It is not stored per "
                 + "bike, so there is nothing to set up here.")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}
