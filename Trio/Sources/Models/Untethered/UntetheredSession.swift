import Foundation

/// The untethered watch mode handshake as a pure state machine, one per device, persisted by each.
/// Neither side doses with the pump unless its own state says so; every transition that hands the
/// pump over waits for the other side's answer, except the two emergency stops.
struct UntetheredSession: Codable, Equatable {
    enum Phase: String, Codable {
        case idle
        /// Phone: grant sent. Watch: grant accepted, waiting for the commit.
        case preparing
        /// Phone: pump released, waiting for the takeover. Watch: taking the pump.
        case starting
        case active
        case ending
    }

    enum Effect: Equatable {
        case send(UntetheredMessage)
        /// Phone: release the pump, then send the commit with it as released.
        case commit
        case releasePump
        /// Phone: take the pump back, read it and audit. Watch: retake it after a refused handback.
        case takePump
        /// Watch: take control and read the pump until it answers or the lease runs out.
        case takeover
        /// Watch: finish the cycle, read the pump, release it, then report `handbackReady`.
        case handback
        /// Phone: ask the watch for the records it hasn't got.
        case reconcile
        case failed(String)
    }

    enum PhoneEvent: Equatable {
        case start(UntetheredGrant)
        case received(UntetheredMessage, epoch: Int)
        case end
        case forceTakeBack
        case tick
        /// The watch reports the pump for a newer session the phone never granted: it started without the phone.
        case watchHoldsPump(epoch: Int, status: UntetheredPodStatus?)
        /// The pod reported a foreign controller before the watch's message arrived.
        case foreignSessionDetected(UntetheredPodStatus?)
        /// Records of a newer session the phone never granted reached it: whether the watch holds the pump is asked,
        /// not assumed (Ponytail's review, 15 November).
        case watchRecordsSeen(epoch: Int)
        /// The watch says a newer session the phone never granted is over (released, or a failed takeover).
        case watchSessionEnded(epoch: Int)
    }

    enum WatchEvent: Equatable {
        case received(UntetheredMessage, epoch: Int)
        case takeoverSucceeded(UntetheredPodStatus)
        case takeoverFailed(String)
        /// On the wrist, or the linked override is over. Only sent while the phone is reachable.
        case end
        /// The pump is released for the handback; offered until the phone acknowledges it.
        case handbackReady(UntetheredPodStatus?)
        case emergencyStop(UntetheredPodStatus?)
        case tick
        /// From the standing grant, with the phone out of reach.
        case startWithoutPhone
    }

    /// How long the phone keeps offering a start (`prepare`, sent again every few seconds) before it gives up. 15 s
    /// with a single send failed whenever WatchConnectivity didn't get through at once (25 October: four tries); 30 s
    /// ran out while the link came and went every few seconds (9 November, second tester: the watch had the offer at
    /// 26 s, its answer didn't get back in time). The phone keeps the pump and doses meanwhile, and both sides show
    /// that the start is under way.
    static let prepareTimeout: TimeInterval = 90
    /// From the watch's answer to the offer, the watch has this long to reach the pump. Counted from the answer, not
    /// from the offer: with the offer sent again for up to 90 s (`prepareTimeout`), a lease counted from the first
    /// offer left an answer that came late less than 30 s for the takeover. The phone sets the deadline once and sends
    /// it in its commit, so both sides keep the same moment (the clocks of a paired phone and watch agree).
    static let takeoverLease: TimeInterval = 120
    /// A start without the phone has this long to reach the pump.
    static let takeoverWithoutPhoneLease: TimeInterval = 5 * 60
    /// After the lease the phone asks once whether the watch holds the pump.
    static let statusQueryGrace: TimeInterval = 10
    /// If the watch cannot answer the ownership query, read the pod and recover control after this wait.
    static let statusQueryResponseTimeout: TimeInterval = 3 * 60

    private(set) var phase = Phase.idle
    private(set) var epoch = 0
    private(set) var leaseExpiresAt: Date?
    private(set) var prepareDeadline: Date?
    private(set) var statusQueried = false
    /// The pump as the watch found it at takeover; the insulin audit counts from here.
    private(set) var startStatus: UntetheredPodStatus?
    /// Phone: the temp basal the watch cancelled at its hand-back, set again once the pump is read.
    private(set) var returnedTempBasal: UntetheredTempBasal?
    /// Phone: a high temp the watch left running at its hand-back, cancelled once the pump is read.
    private(set) var returnedHighTemp: UntetheredTempBasal?
    private(set) var linkedOverrideID: String?
    /// The last session ended by an emergency stop or a take-back.
    private(set) var forced = false
    /// The watch started it from the standing grant, without the phone.
    private(set) var startedWithoutPhone = false
    /// Phone: took the pod back after the watch left the foreign-session query unanswered; its epoch is unknown.
    private(set) var unknownWatchSince: Date?
    /// Watch: the pump as offered to the phone, resent until acknowledged.
    private(set) var handbackStatus: UntetheredPodStatus??
    /// Watch: when the hand-back was offered; the pod is held until the phone acknowledges, or this long at most.
    private(set) var handbackOfferedAt: Date?
    /// Watch: let go of the pod although no acknowledgement came, offered still.
    private(set) var handbackLetGo = false

    /// Without an acknowledgement the pod is let go anyway, and runs its schedule until the phone takes it.
    static let handbackAckWait: TimeInterval = 60

    var isIdle: Bool { phase == .idle }

    /// Phone: set when a refused pod command, not a start, made it ask the watch. Optional so older saved states load.
    private(set) var checkingForeignSession: Bool?
    /// Phone: this session ended with the watch's hand-back. Optional so older saved states load.
    private(set) var handedBack: Bool?
    /// The phone is only asking whether the watch has the pump after another controller used the pod. It shows as
    /// that, not as untethered: on 3 November the second tester's phone said "Untethered on Apple Watch" for 5 minutes
    /// while the watch had nothing, and again after a refused bolus.
    var isCheckingForeignSession: Bool { phase == .starting && checkingForeignSession == true }

    // MARK: - Phone

    mutating func phone(_ event: PhoneEvent, now: Date) -> [Effect] {
        switch (phase, event) {
        case let (.idle, .start(grant)):
            // seconds since 1970: unique across reinstalls without anyone remembering a counter
            self = UntetheredSession(phase: .preparing, epoch: max(epoch + 1, Int(now.timeIntervalSince1970)))
            leaseExpiresAt = grant.leaseExpiresAt
            prepareDeadline = now.addingTimeInterval(Self.prepareTimeout)
            linkedOverrideID = grant.linkedOverrideID
            return [.send(.prepare(grant))]

        // the phone dosed again after the watch stayed silent: the watch ends as after a take-back, never gets the pod
        // back, and its history comes over. Only a session the watch started by then: one it started later (a
        // fallback after the phone went quiet) had nobody else at the pod, and the mark of a silence hours ago
        // revoked it at the phone's relaunch while the phone, Bluetooth off, couldn't take the pod (1 November 15:37)
        case let (.idle, .watchHoldsPump(watchEpoch, _))
            where watchEpoch > epoch && unknownWatchSince.map { TimeInterval(watchEpoch) <= $0.timeIntervalSince1970 } == true:
            self = UntetheredSession(phase: .idle, epoch: watchEpoch)
            forced = true
            return [.send(.revoke), .reconcile]

        // the phone stands aside on the watch's word, never on evidence from the pod (LoopKit/Loop#2545)
        case let (.idle, .watchHoldsPump(watchEpoch, status)) where watchEpoch > epoch:
            self = UntetheredSession(phase: .active, epoch: watchEpoch)
            startStatus = status
            startedWithoutPhone = true
            return [.releasePump]

        case let (.starting, .watchHoldsPump(watchEpoch, status)) where watchEpoch > epoch:
            // "not holding" for a session the phone never knew: that session is over. The phone takes its number,
            // so the watch's later messages for it (its release, its last records) are that ended session's, not a
            // new one's, and its records come over (Ponytail's review, 15 November: the phone otherwise ignored
            // the release and later went back to "watch in charge" on the records, with nobody looping).
            guard status != nil else {
                phase = .idle
                epoch = watchEpoch
                forced = true
                return [.takePump, .reconcile]
            }
            self = UntetheredSession(phase: .active, epoch: watchEpoch)
            startStatus = status
            startedWithoutPhone = true
            return [.releasePump]

        // records of a session the phone never knew: asked, as after a refused pod command. Taken as "the watch holds
        // the pump" they released the pod for a session that was over (Ponytail's review, 15 November).
        case let (.idle, .watchRecordsSeen(watchEpoch)) where watchEpoch > epoch:
            phase = .starting
            leaseExpiresAt = now
            statusQueried = true
            checkingForeignSession = true
            startStatus = nil
            return [.send(.statusQuery)]

        // a session the phone never knew ended on the watch: the phone takes its number, keeps (or takes back) the
        // pump, and gets the session's records
        case let (.idle, .watchSessionEnded(watchEpoch)) where watchEpoch > epoch:
            epoch = watchEpoch
            forced = true
            // the last session's pod reading is no start for this one
            startStatus = nil
            return [.reconcile]

        case let (.starting, .watchSessionEnded(watchEpoch)) where watchEpoch > epoch:
            phase = .idle
            epoch = watchEpoch
            forced = true
            return [.takePump, .reconcile]

        case let (.idle, .foreignSessionDetected(status)):
            phase = .starting
            leaseExpiresAt = now
            statusQueried = true
            checkingForeignSession = true
            startStatus = status
            return [.send(.statusQuery)]

        case let (_, .received(_, messageEpoch)) where messageEpoch != epoch:
            return []

        // adopted from the watch's records before its takeover report: the audit counts from that report
        case let (.active, .received(.takeoverComplete(status), _)) where startStatus == nil:
            startStatus = status
            return []

        case (.preparing, .received(.prepared, _)):
            phase = .starting
            leaseExpiresAt = now.addingTimeInterval(Self.takeoverLease)
            return [.commit]

        case let (.preparing, .received(.rejected(reason), _)):
            phase = .idle
            return [.failed(reason)]

        case (.preparing, .end):
            phase = .idle
            return []

        case let (.starting, .received(.statusReport(holding: .some(status)), _)),
             let (.starting, .received(.takeoverComplete(status), _)):
            phase = .active
            startStatus = status
            return []

        case let (.starting, .received(.takeoverFailed(reason), _)):
            phase = .idle
            return [.takePump, .failed(reason)]

        // only as the answer to this session's own query: the queries are queued, and one from an earlier start can
        // reach the watch mid-takeover, which then answers "not holding" with the current epoch
        case (.starting, .received(.statusReport(holding: nil), _)) where statusQueried:
            phase = .idle
            return [.takePump, .failed(String(localized: "The watch did not take over the pump."))]

        case (.active, .end):
            phase = .ending
            return [.send(.endRequest)]

        case let (.active, .received(.handback(status), _)),
             let (.ending, .received(.handback(status), _)):
            phase = .idle
            forced = false
            handedBack = true
            returnedTempBasal = status?.tempBasal
            returnedHighTemp = status?.runningHighTemp
            return [.takePump, .send(.handbackAck), .reconcile]

        case (.idle, .received(.handback, _)):
            // our acknowledgement got lost; the pump is ours already
            return [.send(.handbackAck)]

        // a takeover reported after the phone gave up on it and took the pump back: the watch stops, and its records
        // come over (Ponytail's review, 15 November). Only for this session, and not after its hand-back: the watch
        // sends the report again after a send error, and a copy arriving then is no takeover (Claude Fable's review).
        // A newer session is the watch starting without the phone.
        case (.idle, .received(.takeoverComplete, _)) where handedBack != true:
            return [.send(.revoke), .reconcile]

        case (.active, .received(.released, _)),
             (.ending, .received(.released, _)),
             (.starting, .received(.released, _)):
            phase = .idle
            forced = true
            return [.takePump, .reconcile]

        case (.active, .forceTakeBack),
             (.ending, .forceTakeBack),
             (.starting, .forceTakeBack):
            phase = .idle
            forced = true
            return [.send(.revoke), .takePump, .reconcile]

        case (.preparing, .tick):
            guard let prepareDeadline, now > prepareDeadline else { return [] }
            phase = .idle
            return [.failed(String(localized: "The watch did not answer. Open Trio on the watch and try again."))]

        case (.starting, .tick):
            guard let leaseExpiresAt else { return [] }
            if !statusQueried, now > leaseExpiresAt.addingTimeInterval(Self.statusQueryGrace) {
                statusQueried = true
                return [.send(.statusQuery)]
            }
            let responseDeadline = leaseExpiresAt
                .addingTimeInterval(Self.statusQueryGrace + Self.statusQueryResponseTimeout)
            guard statusQueried, now > responseDeadline else { return [] }
            phase = .idle
            forced = true
            unknownWatchSince = now
            return [.takePump]

        default:
            return []
        }
    }

    // MARK: - Watch

    mutating func watch(_ event: WatchEvent, now: Date) -> [Effect] {
        switch (phase, event) {
        case let (.idle, .received(.prepare(grant), messageEpoch)),
             let (.preparing, .received(.prepare(grant), messageEpoch)):
            guard now < grant.leaseExpiresAt else { return [] }
            self = UntetheredSession(phase: .preparing, epoch: messageEpoch)
            leaseExpiresAt = grant.leaseExpiresAt
            linkedOverrideID = grant.linkedOverrideID
            return [.send(.prepared)]

        case (_, .received(.prepare, _)):
            return [.send(.rejected(reason: String(localized: "The watch is still running an earlier watch mode session.")))]

        case (.idle, .startWithoutPhone):
            // seconds since 1970, as the phone's: newer than any session it granted
            self = UntetheredSession(phase: .starting, epoch: max(epoch + 1, Int(now.timeIntervalSince1970)))
            leaseExpiresAt = now.addingTimeInterval(Self.takeoverWithoutPhoneLease)
            startedWithoutPhone = true
            return [.takeover]

        // The phone may have an older epoch after a restart. A status query is deliberately
        // epoch independent; its reply carries the watch's current epoch.
        case (_, .received(.statusQuery, _)):
            return [.send(.statusReport(holding: phase == .active || phase == .ending ? startStatus : nil))]

        case let (_, .received(_, messageEpoch)) where messageEpoch != epoch:
            return []

        case let (.preparing, .received(.commit(handover), _)):
            // the phone's deadline, which it keeps too (a commit from an older phone build has none: the grant's)
            if let lease = handover.leaseExpiresAt { leaseExpiresAt = lease }
            guard let leaseExpiresAt, now < leaseExpiresAt else {
                phase = .idle
                return [.send(.takeoverFailed(reason: String(localized: "The start took too long.")))]
            }
            phase = .starting
            return [.takeover]

        case let (.starting, .takeoverSucceeded(status)):
            guard let leaseExpiresAt, now < leaseExpiresAt else {
                phase = .idle
                return [.releasePump, .send(.takeoverFailed(reason: String(localized: "The watch reached the pump too late.")))]
            }
            phase = .active
            startStatus = status
            return [.send(.takeoverComplete(status))]

        case let (.starting, .takeoverFailed(reason)):
            phase = .idle
            return [.releasePump, .send(.takeoverFailed(reason: reason))]

        case (.active, .end),
             (.active, .received(.endRequest, _)):
            phase = .ending
            handbackStatus = nil
            handbackOfferedAt = nil
            handbackLetGo = false
            return [.handback]

        // The pod is held until the phone acknowledges, so its standing connect lands as the watch lets go
        // (LoopKit/Loop#2545). Once let go the watch never takes the pump back on its own: a lost
        // acknowledgement must not leave both devices dosing. A free pump runs its scheduled basal.
        case let (.ending, .handbackReady(status)):
            handbackStatus = .some(status)
            handbackOfferedAt = now
            return [.send(.handback(status))]

        case (.ending, .tick):
            // offeredAt, not the status: a hand-back offered without a pod reading persists as no status at all
            guard handbackOfferedAt != nil else { return [] }
            let status = handbackStatus ?? nil
            if !handbackLetGo, let offered = handbackOfferedAt, now > offered.addingTimeInterval(Self.handbackAckWait) {
                handbackLetGo = true
                return [.releasePump, .send(.handback(status))]
            }
            return [.send(.handback(status))]

        case (.ending, .received(.handbackAck, _)):
            phase = .idle
            forced = false
            return handbackLetGo ? [] : [.releasePump]

        case (.preparing, .received(.revoke, _)):
            phase = .idle
            return []

        case (.active, .received(.revoke, _)),
             (.ending, .received(.revoke, _)),
             (.starting, .received(.revoke, _)):
            phase = .idle
            forced = true
            return [.releasePump]

        case let (.active, .emergencyStop(status)),
             let (.ending, .emergencyStop(status)),
             let (.starting, .emergencyStop(status)):
            phase = .idle
            forced = true
            return [.releasePump, .send(.released(status))]

        case (.preparing, .tick):
            guard let leaseExpiresAt, now >= leaseExpiresAt else { return [] }
            phase = .idle
            return []

        // The offer ran out here before the commit came: the watch never reached for the pod, and says so, so the
        // phone takes it back at once instead of waiting out its lease and the ownership question.
        case (.idle, .received(.commit, _)):
            return [.send(.takeoverFailed(reason: String(localized: "The start took too long.")))]

        case (.starting, .tick):
            guard let leaseExpiresAt, now >= leaseExpiresAt else { return [] }
            phase = .idle
            return [.releasePump, .send(.takeoverFailed(reason: String(localized: "The watch could not reach the pump.")))]

        default:
            return []
        }
    }

    private init(phase: Phase, epoch: Int) {
        self.phase = phase
        self.epoch = epoch
    }

    init() {}
}

extension UntetheredSession {
    /// Field by field, so a field added in a later version can't make a saved session unreadable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        phase = try container.decodeIfPresent(Phase.self, forKey: .phase) ?? phase
        epoch = try container.decodeIfPresent(Int.self, forKey: .epoch) ?? epoch
        leaseExpiresAt = try container.decodeIfPresent(Date.self, forKey: .leaseExpiresAt)
        prepareDeadline = try container.decodeIfPresent(Date.self, forKey: .prepareDeadline)
        statusQueried = try container.decodeIfPresent(Bool.self, forKey: .statusQueried) ?? statusQueried
        startStatus = try container.decodeIfPresent(UntetheredPodStatus.self, forKey: .startStatus)
        returnedTempBasal = try container.decodeIfPresent(UntetheredTempBasal.self, forKey: .returnedTempBasal)
        returnedHighTemp = try container.decodeIfPresent(UntetheredTempBasal.self, forKey: .returnedHighTemp)
        linkedOverrideID = try container.decodeIfPresent(String.self, forKey: .linkedOverrideID)
        forced = try container.decodeIfPresent(Bool.self, forKey: .forced) ?? forced
        startedWithoutPhone = try container.decodeIfPresent(Bool.self, forKey: .startedWithoutPhone) ?? startedWithoutPhone
        unknownWatchSince = try container.decodeIfPresent(Date.self, forKey: .unknownWatchSince)
        handbackStatus = try container.decodeIfPresent(UntetheredPodStatus?.self, forKey: .handbackStatus)
        handbackOfferedAt = try container.decodeIfPresent(Date.self, forKey: .handbackOfferedAt)
        handbackLetGo = try container.decodeIfPresent(Bool.self, forKey: .handbackLetGo) ?? handbackLetGo
        handedBack = try container.decodeIfPresent(Bool.self, forKey: .handedBack)
    }
}
