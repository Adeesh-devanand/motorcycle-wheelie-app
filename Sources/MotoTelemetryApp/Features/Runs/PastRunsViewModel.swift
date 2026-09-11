import Foundation
import MotoTelemetryCore
import Observation

/// §8 view model — filtered+sorted run list with relative colour anchors.
@Observable
final class PastRunsViewModel {

    /// Four independent sort fields. `recency` sorts on when the run happened;
    /// `time` sorts on the run's *duration*, which is what the TIME column shows
    /// — previously `time` meant recency, so the TIME column was unsortable and
    /// there was no way to find your longest wheelie.
    enum SortKey: String, CaseIterable {
        case recency, time, angle, speed
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

    /// Default sort is most recent first, per ui-spec §8.2 — the `recency` chip,
    /// descending.
    var sortKey: SortKey = .recency
    var sortDescending: Bool = true
    var filters = Filters()

    /// Derived on read rather than cached, so the list tracks the repository the
    /// instant a run is saved or deleted. The previous cached array was only
    /// refreshed by an explicit `recompute()`, so a run recorded *after* this
    /// view model was built never appeared until the app relaunched — and a
    /// delete could only be reflected by remembering to call it by hand.
    var filteredRuns: [WheelieRun] { sorted(applyMetricFilters(scopedRuns)) }

    /// §8.4: anchors come from the full date scope BEFORE row-level metric
    /// filters, so colours do not jump while filtering.
    var fieldAnchors: FieldAnchors { computeAnchors(scopedRuns.filter { $0.qualityFlags.isTrustworthy }) }

    private(set) var isLoading = false

    /// Date/bike scope only — the input to both anchors and the filtered list.
    private var scopedRuns: [WheelieRun] { applyDateAndBikeFilters(repository.allRuns) }

    let colorScale = RelativeMetricColorScale()
    let repository: RunRepository

    // MARK: - Computed

    var hasRuns: Bool { !repository.allRuns.isEmpty }

    var hasActiveFilters: Bool {
        filters != Filters()
    }

    var subtitleText: String {
        if hasActiveFilters {
            let count = filteredRuns.count
            return count == 1
                ? String(localized: "\(count) attempt (filtered)")
                : String(localized: "\(count) attempts (filtered)")
        }
        // Default scope: count only runs started today (rider's local day).
        let todayCount = repository.allRuns.filter {
            Calendar.current.isDateInToday($0.startedAt)
        }.count
        return todayCount == 1
            ? String(localized: "\(todayCount) attempt today")
            : String(localized: "\(todayCount) attempts today")
    }

    // MARK: - Init

    init(repository: RunRepository) {
        self.repository = repository
    }

    // MARK: - Actions

    /// Delete one run. The list is derived, so it updates without a refresh call.
    func deleteRun(id: UUID) {
        repository.delete(id: id)
    }

    /// Delete every stored run. Irreversible — callers must confirm first.
    func deleteAllRuns() {
        repository.deleteAll()
    }

    /// Retained for `RunFiltersSheet`'s completion callback. Filters are observed
    /// directly now, so applying them needs no work here.
    func applyFilters() {}

    func resetFilters() {
        filters = Filters()
    }

    // MARK: - Private

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
        // Ties break on recency, not on whatever order the run files happened to
        // load in — two 42° runs should still read newest-first.
        func byMetric(_ value: @escaping (WheelieRun) -> Double) -> (WheelieRun, WheelieRun) -> Bool {
            { lhs, rhs in
                if lhs.qualityFlags.isTrustworthy != rhs.qualityFlags.isTrustworthy {
                    return lhs.qualityFlags.isTrustworthy
                }
                let a = value(lhs), b = value(rhs)
                if a == b { return lhs.startedAt > rhs.startedAt }
                return self.sortDescending ? a > b : a < b
            }
        }

        switch sortKey {
        case .recency:
            return runs.sorted(by: sortDescending
                ? { $0.startedAt > $1.startedAt }
                : { $0.startedAt < $1.startedAt })
        case .time:
            return runs.sorted(by: byMetric { $0.duration })
        case .angle:
            return runs.sorted(by: byMetric { $0.maxAngle })
        case .speed:
            return runs.sorted(by: byMetric { $0.maxSpeed })
        }
    }
}
