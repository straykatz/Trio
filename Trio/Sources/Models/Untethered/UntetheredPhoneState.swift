import Foundation

/// What the phone persists of untethered watch mode.
struct UntetheredPhoneState: Codable, Equatable {
    var session = UntetheredSession()
    /// The pump came back from the watch but hasn't been read and audited yet: dosing stays held.
    var pumpReturnPending = false
    /// The watch ended the pod; the phone forgets it instead of reading it back.
    var podEndedOnWatch = false
    /// Per epoch, the latest version of each record already stored.
    var applied: [Int: [String: UntetheredSyncEntry]] = [:]
    /// The newest session whose history is complete on the phone; nil in a file from before it was kept.
    var syncedEpoch: Int?
    /// Per epoch, the sync identifiers of doses the watch last reported as still running. Only the watch's pump
    /// manager can finalize them, so the phone's own pending reports must not purge them.
    var watchPendingDoses: [Int: Set<String>] = [:]
    /// The return's audit, judged again once the watch's last records are in.
    var audit: UntetheredAuditPoint?
    /// What the complete history still couldn't explain; on the home screen until acknowledged.
    var auditFinding: String?
    /// The pod as the watch last reported it, for the home screen while the watch has the pump.
    var watchPump: UntetheredPumpStatus?
    /// When the watch had the pump, the last three days: the chart's band and Nightscout's note.
    var spans: [UntetheredSpan] = []
    /// The pod's total at the phone's last loop, checked at the next one after a gap.
    var podReading: UntetheredPodReading?
    var lastError: String?

    var watchPendingDoseIdentifiers: Set<String> { watchPendingDoses.values.reduce(into: []) { $0.formUnion($1) } }

    /// Whether the watch's records of a session are stored: true for one whose history is open, or for an ended one
    /// the phone never synced; false (confirmed unstored) for one already complete; nil (not confirmed, sent again)
    /// for a session newer than the phone's. A start the phone gave up on ends with its history never opened: the
    /// watch may still have dosed in it, and its records were confirmed unstored, so the watch deleted them.
    func storesRecords(epoch: Int) -> Bool? {
        if applied[epoch] != nil || (epoch == session.epoch && !session.isIdle) { return true }
        guard epoch <= session.epoch else { return nil }
        // a file from before syncedEpoch was kept: as before, a late copy of a finished session
        guard let syncedEpoch else { return false }
        return epoch > syncedEpoch
    }
}

/// A time the watch had the pump: from its takeover until it let go, open while it still has it.
struct UntetheredSpan: Codable, Equatable {
    let start: Date
    var end: Date?
    /// The note with its duration is on Nightscout.
    var uploaded: Bool
}

/// A field added since the file was written decodes to its default instead of failing the whole file, which would
/// start over and forget a session the watch is still running.
extension UntetheredPhoneState {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = UntetheredPhoneState()
        session = try container.decodeIfPresent(UntetheredSession.self, forKey: .session) ?? defaults.session
        pumpReturnPending = try container.decodeIfPresent(Bool.self, forKey: .pumpReturnPending) ?? defaults.pumpReturnPending
        podEndedOnWatch = try container.decodeIfPresent(Bool.self, forKey: .podEndedOnWatch) ?? defaults.podEndedOnWatch
        applied = try container.decodeIfPresent([Int: [String: UntetheredSyncEntry]].self, forKey: .applied) ?? defaults.applied
        syncedEpoch = try container.decodeIfPresent(Int.self, forKey: .syncedEpoch)
        watchPendingDoses = try container.decodeIfPresent([Int: Set<String>].self, forKey: .watchPendingDoses)
            ?? defaults.watchPendingDoses
        audit = try container.decodeIfPresent(UntetheredAuditPoint.self, forKey: .audit)
        auditFinding = try container.decodeIfPresent(String.self, forKey: .auditFinding)
        watchPump = try container.decodeIfPresent(UntetheredPumpStatus.self, forKey: .watchPump)
        spans = try container.decodeIfPresent([UntetheredSpan].self, forKey: .spans) ?? defaults.spans
        podReading = try container.decodeIfPresent(UntetheredPodReading.self, forKey: .podReading)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }
}

struct UntetheredPodReading: Codable, Equatable {
    /// Which pod: its activation.
    let pod: Date?
    let at: Date
    let units: Double
}
