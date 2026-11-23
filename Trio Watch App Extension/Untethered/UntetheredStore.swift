import Foundation

/// Everything untethered mode needs on the watch, written to disk on every change so a relaunch
/// (the app closed, the watch restarted) continues exactly where it left off.
struct UntetheredWatchData: Codable {
    var session = UntetheredSession()
    var grant: UntetheredGrant?
    /// The pump as the phone released it, from the commit.
    var handover: UntetheredHandover?

    /// The device managers as LoopKit saves them (`managerIdentifier` + `state`), binary property lists.
    var pumpRawValue: Data?
    /// Kept across sessions: the watch's own sensor link and its pairing outlive a hand-back.
    var cgmRawValue: Data?
    /// The configuration's `state` the CGM manager was built from; a different one (new sensor or code) rebuilds it.
    var cgmBuiltFrom: Data?
    /// This watch's own knowledge of each device (e.g. its Bluetooth handle), by plugin identifier.
    var localStates: [String: Data] = [:]

    // What the algorithm reads, trimmed to the last 24 h.
    var pumpHistory: [PumpHistoryEvent] = []
    /// Raw readings, as the phone stores them.
    var glucose: [BloodGlucose] = []
    /// Smoothed value per reading id while smoothing is on; the algorithm reads these, the screens the raw ones.
    var smoothedGlucose: [String: Decimal] = [:]
    var carbs: [CarbsEntry] = []
    var tempTargets: [TempTarget] = []
    var activeOverride: Override?
    /// The pod's total at the last check (`podTotalExplained`), kept across relaunches: without it the next check
    /// would count from the session's start.
    var podTotalCheck: PodTotalCount?
    /// Overrides that ended on the watch, with the minutes they ran, for the watch's own Nightscout upload.
    var endedOverrides: [UntetheredNightscout.OverrideRun] = []
    /// The record keys that started the running override and temp target; their end is a new version.
    var activeOverrideKey: String?
    var activeTempTargetKey: String?
    var autosens: Autosens?
    var reservoir: Decimal?
    /// Pump history in the shape TDD is calculated from, the last day.
    var tddPumpHistory: [PumpHistoryEvent] = []
    /// Pump events still in progress; a complete pending report drops the ones it no longer contains.
    var mutablePumpEventIDs: Set<String> = []
    /// TDD rows of the last two hours (the phone's, then the watch's own) and the running ten-day sum and count.
    var tddRows: [UntetheredTDD] = []
    var tddHours: [UntetheredTDDHour] = []

    // What the screens show.
    var lastDetermination: Determination?
    var lastLoopDate: Date?
    /// The newest reading a dosing loop has seen, the phone's last one included: each reading loops once.
    var lastLoopGlucose: Date?
    var lastLoopError: String?
    var lastError: String?
    /// The pod was deactivated or discarded here: no loop until the phone, which pairs the next one, takes over.
    var podEnded = false
    /// The phone's standing grant, the newest, for a start without it.
    var standingGrant: UntetheredGrant?
    var standingGrantIssuedAt: Date?
    /// In a session started without the phone: its return was announced once.
    var phoneReturnNoted = false
    var pendingPumpAlerts: [PendingPumpAlert] = []

    // History on its way to the phone, per session.
    /// Versions the phone hasn't confirmed yet: dropped as soon as it has stored them.
    var pending: [Int: [String: UntetheredRecord]] = [:]
    /// The latest version of every key, payload-free, for the bucket checksums.
    var entries: [Int: [String: UntetheredSyncEntry]] = [:]
    /// Versions not handed to WatchConnectivity yet.
    var unsent: Set<UUID> = []

    /// A pod's delivered total and the time the pod gave it.
    struct PodTotalCount: Codable, Equatable {
        let units: Double
        let at: Date
    }

    struct PendingPumpAlert: Codable, Equatable, Identifiable {
        let managerIdentifier: String
        let alertIdentifier: String
        let title: String
        let body: String
        /// When a scheduled alert becomes due; nil shows it at once.
        var due: Date?
        var id: String { managerIdentifier + "." + alertIdentifier }
    }
}

/// The pump history is kept in two shapes, the algorithm's and the TDD's: both change together.
extension UntetheredWatchData {
    mutating func upsertPumpEvent(id: String, history: [PumpHistoryEvent], tdd: PumpHistoryEvent?) {
        removePumpEvents([id])
        pumpHistory += history
        if let tdd { tddPumpHistory.append(tdd) }
    }

    mutating func removePumpEvents(_ ids: Set<String>) {
        let rows = ids.union(ids.map(UntetheredAlgorithm.rateID))
        pumpHistory.removeAll { rows.contains($0.id) }
        tddPumpHistory.removeAll { ids.contains($0.id) }
    }
}

/// A field added since the file was written decodes to its default instead of failing the whole file: a failed
/// decode would start over and lose the sensor's pairing and the history not yet on the phone.
extension UntetheredWatchData {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = UntetheredWatchData()
        session = try container.decodeIfPresent(UntetheredSession.self, forKey: .session) ?? defaults.session
        grant = try container.decodeIfPresent(UntetheredGrant.self, forKey: .grant)
        handover = try container.decodeIfPresent(UntetheredHandover.self, forKey: .handover)
        pumpRawValue = try container.decodeIfPresent(Data.self, forKey: .pumpRawValue)
        cgmRawValue = try container.decodeIfPresent(Data.self, forKey: .cgmRawValue)
        cgmBuiltFrom = try container.decodeIfPresent(Data.self, forKey: .cgmBuiltFrom)
        localStates = try container.decodeIfPresent([String: Data].self, forKey: .localStates) ?? defaults.localStates
        pumpHistory = try container.decodeIfPresent([PumpHistoryEvent].self, forKey: .pumpHistory) ?? defaults.pumpHistory
        glucose = try container.decodeIfPresent([BloodGlucose].self, forKey: .glucose) ?? defaults.glucose
        smoothedGlucose = try container.decodeIfPresent([String: Decimal].self, forKey: .smoothedGlucose) ?? defaults
            .smoothedGlucose
        carbs = try container.decodeIfPresent([CarbsEntry].self, forKey: .carbs) ?? defaults.carbs
        tempTargets = try container.decodeIfPresent([TempTarget].self, forKey: .tempTargets) ?? defaults.tempTargets
        activeOverride = try container.decodeIfPresent(Override.self, forKey: .activeOverride)
        podTotalCheck = try container.decodeIfPresent(PodTotalCount.self, forKey: .podTotalCheck)
        endedOverrides = try container.decodeIfPresent([UntetheredNightscout.OverrideRun].self, forKey: .endedOverrides) ??
            defaults.endedOverrides
        activeOverrideKey = try container.decodeIfPresent(String.self, forKey: .activeOverrideKey)
        activeTempTargetKey = try container.decodeIfPresent(String.self, forKey: .activeTempTargetKey)
        autosens = try container.decodeIfPresent(Autosens.self, forKey: .autosens)
        reservoir = try container.decodeIfPresent(Decimal.self, forKey: .reservoir)
        tddPumpHistory = try container.decodeIfPresent([PumpHistoryEvent].self, forKey: .tddPumpHistory) ?? defaults
            .tddPumpHistory
        mutablePumpEventIDs = try container.decodeIfPresent(Set<String>.self, forKey: .mutablePumpEventIDs) ?? defaults
            .mutablePumpEventIDs
        tddRows = try container.decodeIfPresent([UntetheredTDD].self, forKey: .tddRows) ?? defaults.tddRows
        tddHours = try container.decodeIfPresent([UntetheredTDDHour].self, forKey: .tddHours) ?? defaults.tddHours
        lastDetermination = try container.decodeIfPresent(Determination.self, forKey: .lastDetermination)
        lastLoopDate = try container.decodeIfPresent(Date.self, forKey: .lastLoopDate)
        lastLoopGlucose = try container.decodeIfPresent(Date.self, forKey: .lastLoopGlucose)
        lastLoopError = try container.decodeIfPresent(String.self, forKey: .lastLoopError)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        podEnded = try container.decodeIfPresent(Bool.self, forKey: .podEnded) ?? defaults.podEnded
        standingGrant = try container.decodeIfPresent(UntetheredGrant.self, forKey: .standingGrant)
        standingGrantIssuedAt = try container.decodeIfPresent(Date.self, forKey: .standingGrantIssuedAt)
        phoneReturnNoted = try container.decodeIfPresent(Bool.self, forKey: .phoneReturnNoted) ?? defaults.phoneReturnNoted
        pendingPumpAlerts = try container.decodeIfPresent([PendingPumpAlert].self, forKey: .pendingPumpAlerts) ?? defaults
            .pendingPumpAlerts
        pending = try container.decodeIfPresent([Int: [String: UntetheredRecord]].self, forKey: .pending) ?? defaults.pending
        entries = try container.decodeIfPresent([Int: [String: UntetheredSyncEntry]].self, forKey: .entries) ?? defaults.entries
        unsent = try container.decodeIfPresent(Set<UUID>.self, forKey: .unsent) ?? defaults.unsent
    }
}

final class UntetheredStore {
    private let url: URL
    private(set) var data: UntetheredWatchData
    /// The saved state is there but can't be read yet, as before the first unlock after a restart (its file is
    /// protected until then). Nothing is saved over it meanwhile: an idle state written then would wipe out a running
    /// session (Ponytail's review, 15 November).
    private(set) var isLocked = false

    init(fileName: String = "untethered-watch.json") {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(fileName)
        data = UntetheredWatchData()
        _ = load()
    }

    /// Reads the saved state: true when there is one now, or none at all; false while it is locked.
    private func load() -> Bool {
        let saved: Data
        do {
            saved = try Data(contentsOf: url)
        } catch {
            if (error as? CocoaError)?.code == .fileReadNoSuchFile || !FileManager.default.fileExists(atPath: url.path) {
                isLocked = false
                return true
            }
            if !isLocked {
                Task { await WatchLogger.shared.log("⌚️ Untethered: saved state locked, nothing saved until it opens: \(error)", force: true) }
            }
            isLocked = true
            return false
        }
        isLocked = false
        do {
            data = try JSONDecoder().decode(UntetheredWatchData.self, from: saved)
        } catch {
            // kept aside rather than overwritten by the next save, so nothing is lost silently
            try? FileManager.default.removeItem(at: url.appendingPathExtension("unreadable"))
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable"))
            data = UntetheredWatchData()
            Task { await WatchLogger.shared.log("⌚️ Untethered: saved state unreadable, kept aside: \(error)", force: true) }
        }
        return true
    }

    /// While the saved state is locked, tries it again: true once it was read now (the caller takes it on).
    func openIfLocked() -> Bool {
        guard isLocked else { return false }
        return load()
    }

    @discardableResult func update<T>(_ change: (inout UntetheredWatchData) -> T) -> T {
        let result = change(&data)
        // locked: the change stays in memory only; the saved state, once read, is what counts
        guard !isLocked else { return result }
        do {
            try JSONEncoder().encode(data).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Task { await WatchLogger.shared.log("⌚️ Untethered: saving failed: \(error)", force: true) }
        }
        return result
    }

    /// Keeps a new version for the phone and in the checksums.
    func record(_ record: UntetheredRecord, epoch: Int) {
        update {
            $0.pending[epoch, default: [:]][record.key] = record
            $0.entries[epoch, default: [:]][record.key] = record.syncEntry
            $0.unsent.insert(record.id)
        }
    }

    /// Drops what is older than a day from the algorithm's inputs.
    func trim(now: Date) {
        let dayAgo = now.addingTimeInterval(-24 * 60 * 60)
        update {
            $0.pumpHistory.removeAll { $0.timestamp < dayAgo }
            $0.tddPumpHistory.removeAll { $0.timestamp < dayAgo }
            $0.tddRows.removeAll { $0.date < now.addingTimeInterval(-2 * 60 * 60) }
            $0.glucose.removeAll { $0.dateString < dayAgo }
            let kept = Set($0.glucose.map(\.id))
            $0.smoothedGlucose = $0.smoothedGlucose.filter { kept.contains($0.key) }
            $0.carbs.removeAll { ($0.actualDate ?? $0.createdAt) < dayAgo }
            $0.tempTargets.removeAll { $0.createdAt < dayAgo }
            $0.endedOverrides.removeAll { $0.start < dayAgo }
        }
    }
}
