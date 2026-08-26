import Foundation
import MotoTelemetryCore
import Observation
import os

/// Persisted bike profile — mount geometry, vibration characterization, and calibration metadata.
struct BikeProfile: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var name: String
    var vibrationProfileID: UUID?
    var lastCalibration: Date?
    var mountAlignment: MountAlignment?

    init(id: UUID = UUID(),
         name: String,
         vibrationProfileID: UUID? = nil,
         lastCalibration: Date? = nil,
         mountAlignment: MountAlignment? = nil) {
        self.id = id
        self.name = name
        self.vibrationProfileID = vibrationProfileID
        self.lastCalibration = lastCalibration
        self.mountAlignment = mountAlignment
    }
}

/// CRUD store for bike profiles, JSON-backed in the documents directory.
@Observable
final class BikeProfileStore: @unchecked Sendable {

    // MARK: - Published

    private(set) var profiles: [BikeProfile] = []
    var selectedProfileID: UUID? {
        didSet { saveSelection() }
    }

    var selectedProfile: BikeProfile? {
        guard let id = selectedProfileID else { return profiles.first }
        return profiles.first { $0.id == id }
    }

    // MARK: - Private

    private let fileURL: URL
    private let selectionKey = "BikeProfileStore.selectedID"
    private let log = Logger(subsystem: "com.mototelemetry.app", category: "BikeProfileStore")

    // MARK: - Init

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.fileURL = docs.appendingPathComponent("bike_profiles.json")
        load()
        selectedProfileID = loadSelection()
    }

    // MARK: - CRUD

    @discardableResult
    func add(name: String, mountAlignment: MountAlignment? = nil) -> BikeProfile {
        let profile = BikeProfile(name: name, mountAlignment: mountAlignment)
        profiles.append(profile)
        save()
        log.info("Added bike profile: \(name) (\(profile.id))")
        return profile
    }

    func update(_ profile: BikeProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else {
            log.warning("Update failed: profile \(profile.id) not found")
            return
        }
        profiles[idx] = profile
        save()
    }

    func delete(id: UUID) {
        profiles.removeAll { $0.id == id }
        if selectedProfileID == id {
            selectedProfileID = profiles.first?.id
        }
        save()
        log.info("Deleted bike profile: \(id)")
    }

    func setMountAlignment(_ alignment: MountAlignment, for profileID: UUID) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[idx].mountAlignment = alignment
        save()
    }

    func recordCalibration(for profileID: UUID, at date: Date = Date()) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[idx].lastCalibration = date
        save()
    }

    func setVibrationProfile(_ vibrationID: UUID, for profileID: UUID) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[idx].vibrationProfileID = vibrationID
        save()
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("Failed to save profiles: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            profiles = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            profiles = try JSONDecoder().decode([BikeProfile].self, from: data)
            log.info("Loaded \(self.profiles.count) bike profiles")
        } catch {
            log.error("Failed to load profiles: \(error.localizedDescription)")
            profiles = []
        }
    }

    private func saveSelection() {
        if let id = selectedProfileID {
            UserDefaults.standard.set(id.uuidString, forKey: selectionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectionKey)
        }
    }

    private func loadSelection() -> UUID? {
        guard let str = UserDefaults.standard.string(forKey: selectionKey) else { return nil }
        return UUID(uuidString: str)
    }
}
