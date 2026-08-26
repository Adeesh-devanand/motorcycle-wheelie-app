import MotoTelemetryCore
import SwiftUI

/// Create/edit bikes: name, mount alignment gesture flow
/// (rest gravity → accelerate → cross product), list + select active.
struct BikeProfileSetupView: View {
    @State private var store: BikeProfileStore
    @State private var isAddingNew = false
    @State private var editingProfile: BikeProfile?
    @State private var newBikeName = ""
    @State private var alignmentStep: AlignmentStep = .idle

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

            if let selected = store.selectedProfile {
                Section("Mount Alignment") {
                    alignmentSection(for: selected)
                }
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

                if profile.mountAlignment != nil {
                    Text("Aligned")
                        .font(.caption)
                        .foregroundStyle(AppColors.success)
                } else {
                    Text("Not aligned")
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
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

    private func alignmentSection(for profile: BikeProfile) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            switch alignmentStep {
            case .idle:
                if profile.mountAlignment != nil {
                    Text("Mount alignment recorded.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                }
                Button("Start Alignment") {
                    alignmentStep = .restGravity
                }
                .buttonStyle(.borderedProminent)

            case .restGravity:
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text("Step 1: Rest Gravity")
                        .font(.headline)
                        .foregroundStyle(AppColors.textPrimary)
                    Text("Place the phone in the mount on the stationary bike. Keep still for 3 seconds.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                    ProgressView()
                        .tint(Color(hex: 0x10B9B7))
                }
                .accessibilityElement(children: .combine)

            case .accelerate:
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text("Step 2: Accelerate")
                        .font(.headline)
                        .foregroundStyle(AppColors.textPrimary)
                    Text("Accelerate forward in a straight line. This captures the forward axis.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                    ProgressView()
                        .tint(Color(hex: 0x238CD8))
                }

            case .complete:
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(AppColors.success)
                    Text("Alignment Complete")
                        .font(.headline)
                        .foregroundStyle(AppColors.textPrimary)
                    Text("Cross-product computed. Mount rotation matrix saved.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                    Button("Done") {
                        alignmentStep = .idle
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    enum AlignmentStep {
        case idle, restGravity, accelerate, complete
    }
}
