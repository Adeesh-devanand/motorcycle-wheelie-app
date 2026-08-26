import Foundation
import MotoTelemetryCore
import Observation

/// §8 view model — filtered+sorted run list with relative colour anchors.
@Observable
final class PastRunsViewModel {

    enum SortKey: String, CaseIterable {
        case time, angle, speed
    }

    struct Filters: Equatable {
        var dateFrom: Date?
        var dateTo: Date?
        var bikeProfileID: UUID?
        var minDuration: Double?
        var minAngle: Double?
    }

    struct FieldAnchors: Equatable {
        var durationMin: Double = 0
        var durationMax: Double = 0
        var angleMin: Double = 0
        var angleMax: Double = 0
        var speedMin: Double = 0
        var speedMax: Double = 0
    }

    // MARK: - Public State

    var sortKey: SortKey = .time { didSet { recompute() } }
    var sortDescending: Bool = true { didSet { recompute() } }
    var filters = Filters() { didSet { recompute() } }

    private(set) var filteredRuns: [WheelieRun] = []
    private(set) var fieldAnchors = FieldAnchors()
    private(set) var isLoading = false

    let colorScale = RelativeMetricColorScale()
    let repository: RunRepository

    // MARK: - Computed

    var hasActiveFilters: Bool {
        filters != Filters()
    }

    var subtitleText: String {
        let count = filteredRuns.count
        let noun = count == 1 ? "run" : "runs"
        if hasActiveFilters {
            return "\(count) \(noun) (filtered)"
        }
        return "\(count) \(noun)"
    }

    // MARK: - Init

    init(repository: RunRepository) {
        self.repository = repository
        recompute()
    }

    // MARK: - Actions

    func deleteRun(id: UUID) {
        repository.delete(id: id)
        recompute()
    }

    func applyFilters() {
        recompute()
    }

    func resetFilters() {
        filters = Filters()
    }

    // MARK: - Private

    private func recompute() {
        let allRuns = repository.allRuns

        // 1. Scope by date for anchor calculation (before row-level metric filters).
        let scoped = applyDateAndBikeFilters(allRuns)

        // 2. Compute anchors from the full date scope.
        fieldAnchors = computeAnchors(scoped)

        // 3. Apply row-level metric filters.
        let filtered = applyMetricFilters(scoped)

        // 4. Sort.
        filteredRuns = sorted(filtered)
    }

    private func applyDateAndBikeFilters(_ runs: [WheelieRun]) -> [WheelieRun] {
        var result = runs
        if let from = filters.dateFrom {
            result = result.filter { $0.startedAt >= from }
        }
        if let to = filters.dateTo {
            result = result.filter { $0.startedAt <= to }
        }
        if let bike = filters.bikeProfileID {
            result = result.filter { $0.configuration.calibrationID == bike }
        }
        return result
    }

    private func applyMetricFilters(_ runs: [WheelieRun]) -> [WheelieRun] {
        var result = runs
        if let minDur = filters.minDuration {
            result = result.filter { $0.duration >= minDur }
        }
        if let minAngle = filters.minAngle {
            result = result.filter { $0.maxAngle >= minAngle }
        }
        return result
    }

    /// §8.4: Anchors from the full date scope BEFORE row-level metric filters.
    private func computeAnchors(_ runs: [WheelieRun]) -> FieldAnchors {
        guard !runs.isEmpty else { return FieldAnchors() }
        let durations = runs.map(\.duration)
        let angles = runs.map(\.maxAngle)
        let speeds = runs.map(\.maxSpeed)
        return FieldAnchors(
            durationMin: durations.min() ?? 0,
            durationMax: durations.max() ?? 0,
            angleMin: angles.min() ?? 0,
            angleMax: angles.max() ?? 0,
            speedMin: speeds.min() ?? 0,
            speedMax: speeds.max() ?? 0
        )
    }

    private func sorted(_ runs: [WheelieRun]) -> [WheelieRun] {
        let comparator: (WheelieRun, WheelieRun) -> Bool
        switch sortKey {
        case .time:
            comparator = sortDescending
                ? { $0.startedAt > $1.startedAt }
                : { $0.startedAt < $1.startedAt }
        case .angle:
            comparator = sortDescending
                ? { $0.maxAngle > $1.maxAngle }
                : { $0.maxAngle < $1.maxAngle }
        case .speed:
            comparator = sortDescending
                ? { $0.maxSpeed > $1.maxSpeed }
                : { $0.maxSpeed < $1.maxSpeed }
        }
        return runs.sorted(by: comparator)
    }
}
