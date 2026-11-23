import Foundation
#if canImport(LoopKit)
    import LoopKit
#endif
import Testing
@testable import Trio

@Suite("Untethered watch mode") struct UntetheredTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func grant(lease: TimeInterval = 120, linked: String? = nil) -> UntetheredGrant {
        UntetheredGrant(
            leaseExpiresAt: t0.addingTimeInterval(lease),
            pumpConfiguration: Data([1]),
            cgmConfiguration: Data([2]),
            pumpSettings: PumpSettings(insulinActionCurve: 10, maxBolus: 10, maxBasal: 3),
            bgTargets: BGTargets(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                targets: [BGTargetEntry(low: 100, high: 100, start: "00:00", offset: 0)]
            ),
            basalProfile: [BasalProfileEntry(start: "00:00", minutes: 0, rate: 1)],
            insulinSensitivities: InsulinSensitivities(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                sensitivities: [InsulinSensitivityEntry(sensitivity: 50, offset: 0, start: "00:00")]
            ),
            carbRatios: CarbRatios(units: .grams, schedule: [CarbRatioEntry(start: "00:00", offset: 0, ratio: 10)]),
            preferences: Preferences(),
            dosingMode: .closed,
            smoothGlucose: false,
            units: .mgdL,
            tdd: OrefPipeline.TDDSummary(currentTDD: 40, averageLastTenDays: 38, averageLastTwoHours: 2),
            hasSufficientTDD: true,
            tddRecentRows: [],
            tddHours: [UntetheredTDDHour(start: t0, total: 380, positive: 10, count: 10)],
            tddPumpHistory: [],
            autosens: Autosens(ratio: 1.1, newisf: nil),
            reservoir: 120,
            maxBolus: 10,
            maxCarbs: 100,
            bolusCalculator: UntetheredBolusCalculatorSettings(
                fraction: 0.8,
                fattyMeals: true,
                fattyMealFactor: 0.7,
                sweetMeals: false,
                sweetMealFactor: 1
            ),
            glucoseColorScheme: "staticColor",
            lastDetermination: nil,
            lastLoopDate: nil,
            lowGlucose: 70,
            highGlucose: 180,
            pumpHistory: [],
            glucose: [BloodGlucose(sgv: 120, date: 1_800_000_000_000, dateString: t0, glucose: 120)],
            smoothedGlucose: [:],
            carbs: [],
            activeOverride: nil,
            tempTargets: [],
            overridePresets: [],
            tempTargetPresets: [],
            linkedOverrideID: linked
        )
    }

    /// Omnipod DASH as `OmniPumpManager` reports it: 0.05 U every 2 s, temps of 30 min to 12 h in half hours.
    let bolusDeliveryRate = 0.025
    let tempBasalDurations = (1 ... 24).map { TimeInterval($0) * 30 * 60 }

    let podStatus = UntetheredPodStatus(date: Date(timeIntervalSince1970: 1_800_000_010), deliveredUnits: 42.5, reservoir: 80)
    let handover = UntetheredHandover(pumpConfiguration: Data([3]), tempBasal: nil)

    /// Phone and watch both active on the same epoch.
    func started() -> (phone: UntetheredSession, watch: UntetheredSession) {
        var phone = UntetheredSession()
        var watch = UntetheredSession()
        let grant = grant()
        #expect(phone.phone(.start(grant), now: t0) == [.send(.prepare(grant))])
        let epoch = phone.epoch
        #expect(watch.watch(.received(.prepare(grant), epoch: epoch), now: t0) == [.send(.prepared)])
        #expect(phone.phone(.received(.prepared, epoch: epoch), now: t0) == [.commit])
        #expect(watch.watch(.received(.commit(handover), epoch: epoch), now: t0) == [.takeover])
        #expect(watch.watch(.takeoverSucceeded(podStatus), now: t0 + 30) == [.send(.takeoverComplete(podStatus))])
        #expect(phone.phone(.received(.takeoverComplete(podStatus), epoch: epoch), now: t0 + 31) == [])
        return (phone, watch)
    }

    @Test("minimal screen: wide elements fit their row, and saved slots are made valid") func glanceLayout() {
        var layout = WatchGlanceLayout.standard
        layout.place(.basalIobCob, at: 4)
        #expect(Array(layout.slots[3...]) == [.basalIobCob, .continuation, .continuation])
        layout.place(.heartRate, at: 5)
        #expect(Array(layout.slots[3...]) == [nil, nil, .heartRate])
        layout.place(.iobCob, at: 4)
        #expect(Array(layout.slots[3...]) == [nil, .iobCob, .continuation])
        layout.place(.iobCob, at: 1)
        #expect(Array(layout.slots[1...]) == [.iobCob, .continuation, nil, nil, nil])
        // mutating calls outside #expect: the macro hands its subject over as an immutable value
        let placedChart = layout.place(.chart, at: 2)
        let placedLoop = layout.place(.loop, at: 0)
        #expect(!placedChart)
        #expect(!placedLoop)
        layout.remove(.iobCob)
        #expect(layout.slots[1] == nil && layout.slots[2] == nil)
        let placedFree = layout.placeInFirstFreeSlot(.basalIobCob)
        #expect(placedFree && layout.slots[3] == .basalIobCob)

        let saved = WatchGlanceLayout(strings: ["loop", "continuation", "iob", "iob", "chart", "nonsense"])
        #expect(saved.slots == [nil, nil, .iob, nil, nil, nil])
    }

    @Test("start: both sides active only after the full handshake") func handshake() {
        let (phone, watch) = started()
        #expect(phone.phase == .active)
        #expect(watch.phase == .active)
        #expect(phone.epoch == watch.epoch)
        #expect(phone.startStatus == podStatus)
    }

    @Test("start: a silent watch never gets the pump") func prepareTimeout() {
        var phone = UntetheredSession()
        _ = phone.phone(.start(grant()), now: t0)
        #expect(phone.phone(.tick, now: t0 + 10) == [])
        let effects = phone.phone(.tick, now: t0 + UntetheredSession.prepareTimeout + 1)
        #expect(effects.count == 1)
        #expect(phone.phase == .idle)
        #expect(!effects.contains(.releasePump))
    }

    @Test("start: a rejected grant leaves the phone in charge") func rejected() {
        var phone = UntetheredSession()
        _ = phone.phone(.start(grant()), now: t0)
        #expect(phone.phone(.received(.rejected(reason: "no G7"), epoch: phone.epoch), now: t0) == [.failed("no G7")])
        #expect(phone.phase == .idle)
    }

    @Test("start: the watch lets go when the lease runs out mid-takeover") func leaseExpiry() {
        var phone = UntetheredSession()
        var watch = UntetheredSession()
        let grant = grant(lease: 60)
        _ = phone.phone(.start(grant), now: t0)
        _ = watch.watch(.received(.prepare(grant), epoch: phone.epoch), now: t0)
        _ = phone.phone(.received(.prepared, epoch: phone.epoch), now: t0)
        _ = watch.watch(.received(.commit(handover), epoch: phone.epoch), now: t0)

        let effects = watch.watch(.tick, now: t0 + 61)
        #expect(effects.first == .releasePump)
        #expect(watch.phase == .idle)
        guard case let .send(failure) = effects.last else { Issue.record("no failure sent")
            return }
        #expect(phone.phone(.received(failure, epoch: phone.epoch), now: t0 + 61).first == .takePump)
        #expect(phone.phase == .idle)

        // a late success from the pump read changes nothing
        #expect(watch.watch(.takeoverSucceeded(podStatus), now: t0 + 62) == [])
    }

    @Test("start: a commit after the lease is refused") func lateCommit() {
        var watch = UntetheredSession()
        _ = watch.watch(.received(.prepare(grant(lease: 60)), epoch: 7), now: t0)
        let effects = watch.watch(.received(.commit(handover), epoch: 7), now: t0 + 61)
        #expect(watch.phase == .idle)
        #expect(!effects.contains(.takeover))
    }

    @Test("start: an expired grant is ignored") func expiredGrant() {
        var watch = UntetheredSession()
        #expect(watch.watch(.received(.prepare(grant(lease: 60)), epoch: 7), now: t0 + 61) == [])
        #expect(watch.phase == .idle)
    }

    @Test("start: the phone asks once after the lease and follows the answer") func statusQuery() {
        var phone = UntetheredSession()
        _ = phone.phone(.start(grant(lease: 60)), now: t0)
        _ = phone.phone(.received(.prepared, epoch: phone.epoch), now: t0)
        // the lease runs from the watch's answer, not from the grant
        #expect(phone.leaseExpiresAt == t0 + UntetheredSession.takeoverLease)
        #expect(phone.phone(.tick, now: t0 + 125) == [])
        #expect(phone.phone(.tick, now: t0 + 131) == [.send(.statusQuery)])
        #expect(phone.phone(.tick, now: t0 + 150) == [])
        #expect(phone.phase == .starting)

        var holding = phone
        _ = holding.phone(.received(.statusReport(holding: podStatus), epoch: phone.epoch), now: t0 + 151)
        #expect(holding.phase == .active)

        var notHolding = phone
        #expect(notHolding.phone(.received(.statusReport(holding: nil), epoch: phone.epoch), now: t0 + 151).first == .takePump)
        #expect(notHolding.phase == .idle)
    }

    @Test("start: a takeover reported after the phone gave up is answered with a revoke") func lateTakeoverComplete() {
        var phone = UntetheredSession()
        _ = phone.phone(.start(grant()), now: t0)
        _ = phone.phone(.received(.prepared, epoch: phone.epoch), now: t0)
        _ = phone.phone(.tick, now: t0 + 131)
        // no answer to the query: the phone takes the pump back
        #expect(phone.phone(.tick, now: t0 + 400) == [.takePump])
        #expect(phone.phase == .idle)
        #expect(phone.phone(.received(.takeoverComplete(podStatus), epoch: phone.epoch), now: t0 + 401) == [.send(.revoke), .reconcile])
        #expect(phone.phase == .idle)
        // another session's report is not this one's to revoke
        #expect(phone.phone(.received(.takeoverComplete(podStatus), epoch: phone.epoch - 1), now: t0 + 402) == [])
    }

    @Test("end: a takeover report sent again after the hand-back is no takeover") func takeoverReportAfterHandback() {
        var (phone, _) = started()
        _ = phone.phone(.received(.handback(podStatus), epoch: phone.epoch), now: t0 + 200)
        #expect(phone.phase == .idle)
        #expect(phone.phone(.received(.takeoverComplete(podStatus), epoch: phone.epoch), now: t0 + 201) == [])
    }

    @Test("start: an answer late in the offer gets the full lease, the same on both sides") func lateAnswerLease() {
        var phone = UntetheredSession()
        var watch = UntetheredSession()
        let grant = grant()
        _ = phone.phone(.start(grant), now: t0)
        let epoch = phone.epoch
        // the offer got through only at 85 s
        #expect(watch.watch(.received(.prepare(grant), epoch: epoch), now: t0 + 85) == [.send(.prepared)])
        #expect(phone.phone(.received(.prepared, epoch: epoch), now: t0 + 86) == [.commit])
        let lease = t0 + 86 + UntetheredSession.takeoverLease
        #expect(phone.leaseExpiresAt == lease)
        var commit = handover
        commit.leaseExpiresAt = phone.leaseExpiresAt
        #expect(watch.watch(.received(.commit(commit), epoch: epoch), now: t0 + 88) == [.takeover])
        #expect(watch.leaseExpiresAt == lease)
        // past the grant's 120 s, within the commit's lease: the takeover counts
        #expect(watch.watch(.takeoverSucceeded(podStatus), now: t0 + 150) == [.send(.takeoverComplete(podStatus))])
        // the phone takes nothing back before the lease, whatever its ticks
        for second in stride(from: 87.0, to: 86 + UntetheredSession.takeoverLease, by: 10) {
            #expect(!phone.phone(.tick, now: t0 + second).contains(.takePump))
        }
        #expect(phone.phone(.received(.takeoverComplete(podStatus), epoch: epoch), now: t0 + 151) == [])
        #expect(phone.phase == .active)
    }

    @Test("start: a commit after the watch gave up the offer is answered, and the phone takes the pump back at once") func commitAfterOfferRanOut() {
        var phone = UntetheredSession()
        var watch = UntetheredSession()
        let grant = grant(lease: 60)
        _ = phone.phone(.start(grant), now: t0)
        let epoch = phone.epoch
        _ = watch.watch(.received(.prepare(grant), epoch: epoch), now: t0 + 50)
        #expect(watch.watch(.tick, now: t0 + 61) == [])
        #expect(watch.phase == .idle)
        _ = phone.phone(.received(.prepared, epoch: epoch), now: t0 + 55)
        let effects = watch.watch(.received(.commit(handover), epoch: epoch), now: t0 + 62)
        #expect(!effects.contains(.takeover))
        guard case let .send(failure) = effects.first else { Issue.record("no answer")
            return }
        #expect(phone.phone(.received(failure, epoch: epoch), now: t0 + 62).first == .takePump)
        #expect(phone.phase == .idle)
    }

    @Test("messages for another epoch are ignored") func wrongEpoch() {
        var (phone, watch) = started()
        #expect(phone.phone(.received(.handback(nil), epoch: phone.epoch - 1), now: t0) == [])
        #expect(watch.watch(.received(.revoke, epoch: watch.epoch + 1), now: t0) == [])
        #expect(phone.phase == .active)
        #expect(watch.phase == .active)
    }

    @Test("the watch refuses a new grant while it holds the pump") func busyWatch() {
        var (_, watch) = started()
        let effects = watch.watch(.received(.prepare(grant(lease: 500)), epoch: watch.epoch + 1), now: t0 + 40)
        guard case .send(.rejected) = effects.first else { Issue.record("not rejected")
            return }
        #expect(watch.phase == .active)
    }

    @Test("end: the watch hands back and the phone takes over") func normalEnd() {
        var (phone, watch) = started()
        #expect(phone.phone(.end, now: t0 + 100) == [.send(.endRequest)])
        #expect(watch.watch(.received(.endRequest, epoch: watch.epoch), now: t0 + 100) == [.handback])
        #expect(watch.watch(.handbackReady(podStatus), now: t0 + 100) == [.send(.handback(podStatus))])
        #expect(
            phone.phone(.received(.handback(podStatus), epoch: phone.epoch), now: t0 + 101) ==
                [.takePump, .send(.handbackAck), .reconcile]
        )
        // the pod is held until the phone acknowledges
        #expect(watch.watch(.received(.handbackAck, epoch: watch.epoch), now: t0 + 101) == [.releasePump])
        #expect(phone.phase == .idle)
        #expect(watch.phase == .idle)
        #expect(!phone.forced)
    }

    @Test("end: without an acknowledgement the pod is let go after a minute, and offered still") func unacknowledgedHandback() {
        var (_, watch) = started()
        _ = watch.watch(.end, now: t0 + 100)
        _ = watch.watch(.handbackReady(podStatus), now: t0 + 100)
        #expect(watch.watch(.tick, now: t0 + 130) == [.send(.handback(podStatus))])
        #expect(watch.watch(.tick, now: t0 + 161) == [.releasePump, .send(.handback(podStatus))])
        #expect(watch.watch(.tick, now: t0 + 191) == [.send(.handback(podStatus))])
        #expect(watch.phase == .ending)
        // let go already: the late acknowledgement only ends the session
        #expect(watch.watch(.received(.handbackAck, epoch: watch.epoch), now: t0 + 200) == [])
        #expect(watch.phase == .idle)
    }

    @Test("end: a hand-back offered without a pod reading is still offered after a relaunch") func handbackWithoutStatusSurvivesRelaunch() throws {
        var (_, watch) = started()
        _ = watch.watch(.end, now: t0 + 100)
        _ = watch.watch(.handbackReady(nil), now: t0 + 100)
        var relaunched = try JSONDecoder().decode(UntetheredSession.self, from: JSONEncoder().encode(watch))
        #expect(relaunched.handbackOfferedAt != nil)
        #expect(relaunched.watch(.tick, now: t0 + 130) == [.send(.handback(nil))])
    }

    @Test("end: the temp basal the watch cancelled at its handback is kept for the phone") func handbackTempBasal() {
        var (phone, watch) = started()
        let tempBasal = UntetheredTempBasal(unitsPerHour: 2.5, endsAt: t0 + 110)
        var status = podStatus
        status.tempBasal = tempBasal
        _ = watch.watch(.received(.endRequest, epoch: watch.epoch), now: t0 + 100)
        #expect(watch.watch(.handbackReady(status), now: t0 + 100) == [.send(.handback(status))])
        _ = phone.phone(.received(.handback(status), epoch: phone.epoch), now: t0 + 101)
        #expect(phone.returnedTempBasal == tempBasal)
    }

    @Test("end: a high temp the watch left running is kept for the phone to cancel") func handbackHighTemp() {
        var (phone, watch) = started()
        let high = UntetheredTempBasal(unitsPerHour: 3.4, endsAt: t0 + 1200, syncIdentifier: "74656d70")
        var status = podStatus
        status.runningHighTemp = high
        _ = watch.watch(.received(.endRequest, epoch: watch.epoch), now: t0 + 100)
        _ = watch.watch(.handbackReady(status), now: t0 + 100)
        _ = phone.phone(.received(.handback(status), epoch: phone.epoch), now: t0 + 101)
        #expect(phone.returnedHighTemp == high)
        #expect(phone.returnedTempBasal == nil)
    }

    @Test("handover: only a rate above the schedule is a high temp") func highTemp() {
        func temp(_ rate: Double) -> UntetheredTempBasal { UntetheredTempBasal(unitsPerHour: rate, endsAt: t0) }
        #expect(temp(3.4).isHigh(scheduledRate: 1.4))
        #expect(!temp(1.4).isHigh(scheduledRate: 1.4))
        #expect(!temp(0).isHigh(scheduledRate: 1.4))
    }

    @Test("handover: a temp basal goes on for what was left, in Omnipod's half hours") func remainingTempBasal() {
        let tempBasal = UntetheredTempBasal(unitsPerHour: 1, endsAt: t0 + 12 * 60)
        func left(_ temp: UntetheredTempBasal, at now: Date) -> TimeInterval? {
            temp.remainingDuration(at: now, supportedDurations: tempBasalDurations)
        }
        #expect(left(tempBasal, at: t0) == TimeInterval(30 * 60))
        #expect(left(tempBasal, at: t0 + 12 * 60) == nil)
        #expect(left(UntetheredTempBasal(unitsPerHour: 1, endsAt: t0 + 31 * 60), at: t0) == TimeInterval(60 * 60))
        #expect(left(UntetheredTempBasal(unitsPerHour: 1, endsAt: t0 + 24 * 3600), at: t0) == TimeInterval(12 * 3600))
    }

    @Test("end: an unacknowledged handback is offered again, never taken back") func lostAck() {
        var (phone, watch) = started()
        _ = watch.watch(.end, now: t0 + 100)
        _ = watch.watch(.handbackReady(podStatus), now: t0 + 100)
        _ = phone.phone(.received(.handback(podStatus), epoch: phone.epoch), now: t0 + 101)
        // the acknowledgement is lost; the watch keeps offering and the phone acknowledges again
        #expect(watch.watch(.tick, now: t0 + 130) == [.send(.handback(podStatus))])
        #expect(watch.phase == .ending)
        #expect(phone.phone(.received(.handback(podStatus), epoch: phone.epoch), now: t0 + 131) == [.send(.handbackAck)])
        _ = watch.watch(.received(.handbackAck, epoch: watch.epoch), now: t0 + 131)
        #expect(watch.phase == .idle)
    }

    @Test("emergency: force take back from the phone") func forceTakeBack() {
        var (phone, watch) = started()
        #expect(phone.phone(.forceTakeBack, now: t0 + 100) == [.send(.revoke), .takePump, .reconcile])
        #expect(phone.forced)
        #expect(watch.watch(.received(.revoke, epoch: watch.epoch), now: t0 + 200) == [.releasePump])
        #expect(watch.phase == .idle)
        #expect(watch.forced)
    }

    @Test("emergency: stop on the watch") func watchEmergencyStop() {
        var (phone, watch) = started()
        #expect(watch.watch(.emergencyStop(podStatus), now: t0 + 100) == [.releasePump, .send(.released(podStatus))])
        #expect(phone.phone(.received(.released(podStatus), epoch: phone.epoch), now: t0 + 101) == [.takePump, .reconcile])
        #expect(phone.phase == .idle)
        #expect(phone.forced)
    }

    @Test("without phone: the watch starts on an epoch of its own, the phone stands aside on its word") func startWithoutPhone() {
        var watch = UntetheredSession()
        #expect(watch.watch(.startWithoutPhone, now: t0) == [.takeover])
        #expect(watch.phase == .starting)
        #expect(watch.startedWithoutPhone)
        #expect(watch.epoch >= Int(t0.timeIntervalSince1970))
        #expect(watch.watch(.takeoverSucceeded(podStatus), now: t0 + 30) == [.send(.takeoverComplete(podStatus))])

        // its records may come first: the phone stands aside, and the start status follows
        var phone = UntetheredSession()
        #expect(phone.phone(.watchHoldsPump(epoch: watch.epoch, status: nil), now: t0 + 600) == [.releasePump])
        #expect(phone.phase == .active)
        #expect(phone.epoch == watch.epoch)
        #expect(phone.startedWithoutPhone)
        #expect(phone.phone(.watchHoldsPump(epoch: watch.epoch, status: podStatus), now: t0 + 601) == [])
        #expect(phone.phone(.received(.takeoverComplete(podStatus), epoch: watch.epoch), now: t0 + 602) == [])
        #expect(phone.startStatus == podStatus)

        // an older session's word changes nothing
        var newer = UntetheredSession()
        _ = newer.phone(.watchHoldsPump(epoch: watch.epoch, status: podStatus), now: t0)
        var stale = newer
        _ = stale.phone(.forceTakeBack, now: t0 + 1)
        #expect(stale.phone(.watchHoldsPump(epoch: watch.epoch - 1, status: podStatus), now: t0 + 2) == [])
    }

    @Test("foreign session: a silent watch loses the pod, and ends once it speaks") func foreignSessionSilentWatch() {
        var phone = UntetheredSession()
        #expect(phone.phone(.foreignSessionDetected(podStatus), now: t0) == [.send(.statusQuery)])
        #expect(!phone.isIdle)
        let deadline = UntetheredSession.statusQueryGrace + UntetheredSession.statusQueryResponseTimeout
        #expect(phone.phone(.tick, now: t0 + deadline - 1) == [])
        #expect(phone.phone(.tick, now: t0 + deadline + 1) == [.takePump])
        #expect(phone.isIdle)
        #expect(phone.unknownWatchSince != nil)

        // the watch, started without the phone, reports later: it is told to stop and its history comes over
        var watch = UntetheredSession()
        _ = watch.watch(.startWithoutPhone, now: t0)
        _ = watch.watch(.takeoverSucceeded(podStatus), now: t0 + 30)
        #expect(phone.phone(.watchHoldsPump(epoch: watch.epoch, status: podStatus), now: t0 + 600) == [
            .send(.revoke),
            .reconcile
        ])
        #expect(phone.isIdle)
        #expect(phone.epoch == watch.epoch)
        #expect(phone.forced)
        #expect(phone.unknownWatchSince == nil)
        #expect(watch.watch(.received(.revoke, epoch: phone.epoch), now: t0 + 601) == [.releasePump])
        #expect(watch.isIdle)
    }

    @Test("foreign session: a watch session started after the phone's forced take is adopted, not revoked")
    func foreignSessionLaterWatchStart() {
        var phone = UntetheredSession()
        _ = phone.phone(.foreignSessionDetected(podStatus), now: t0)
        let deadline = UntetheredSession.statusQueryGrace + UntetheredSession.statusQueryResponseTimeout
        #expect(phone.phone(.tick, now: t0 + deadline + 1) == [.takePump])
        #expect(phone.unknownWatchSince != nil)

        // hours later the phone went quiet and the watch's fallback started: nobody else was at the pod
        var watch = UntetheredSession()
        _ = watch.watch(.startWithoutPhone, now: t0 + 3 * 3600)
        _ = watch.watch(.takeoverSucceeded(podStatus), now: t0 + 3 * 3600 + 30)
        #expect(phone.phone(.watchHoldsPump(epoch: watch.epoch, status: podStatus), now: t0 + 3 * 3600 + 600) == [.releasePump])
        #expect(phone.phase == .active)
        #expect(phone.epoch == watch.epoch)
        #expect(phone.unknownWatchSince == nil)
    }

    @Test("ended watch session: its release and its last records never make the phone stand aside again")
    func endedWatchSessionStaysEnded() {
        // the phone came back while the watch's fallback session ran: its pod command was refused, it asks
        var watch = UntetheredSession()
        _ = watch.watch(.startWithoutPhone, now: t0)
        _ = watch.watch(.takeoverSucceeded(podStatus), now: t0 + 30)
        var phone = UntetheredSession()
        #expect(phone.phone(.foreignSessionDetected(podStatus), now: t0 + 600) == [.send(.statusQuery)])
        // the watch let go meanwhile and answers "not holding" for its session
        #expect(phone.phone(.watchHoldsPump(epoch: watch.epoch, status: nil), now: t0 + 601) == [.takePump, .reconcile])
        #expect(phone.isIdle)
        #expect(phone.epoch == watch.epoch)
        // its release and its records are that ended session's
        #expect(phone.phone(.watchSessionEnded(epoch: watch.epoch), now: t0 + 602) == [])
        #expect(phone.phone(.watchRecordsSeen(epoch: watch.epoch), now: t0 + 603) == [])
        #expect(phone.phone(.received(.released(podStatus), epoch: watch.epoch), now: t0 + 604) == [])
        #expect(phone.isIdle)
    }

    @Test("ended watch session: a release for a session the phone never knew ends it") func unknownSessionReleased() {
        var idle = UntetheredSession()
        #expect(idle.phone(.watchSessionEnded(epoch: 5000), now: t0) == [.reconcile])
        #expect(idle.isIdle)
        #expect(idle.epoch == 5000)
        #expect(idle.forced)
        #expect(idle.phone(.watchRecordsSeen(epoch: 5000), now: t0 + 1) == [])

        var checking = UntetheredSession()
        _ = checking.phone(.foreignSessionDetected(podStatus), now: t0)
        #expect(checking.phone(.watchSessionEnded(epoch: 5000), now: t0 + 1) == [.takePump, .reconcile])
        #expect(checking.isIdle)
        #expect(checking.epoch == 5000)
    }

    @Test("records of a session the phone never knew: the watch is asked, not taken at its records")
    func unknownSessionRecordsAsk() {
        var watch = UntetheredSession()
        _ = watch.watch(.startWithoutPhone, now: t0)
        _ = watch.watch(.takeoverSucceeded(podStatus), now: t0 + 30)
        var phone = UntetheredSession()
        #expect(phone.phone(.watchRecordsSeen(epoch: watch.epoch), now: t0 + 60) == [.send(.statusQuery)])
        #expect(!phone.isIdle)
        #expect(phone.isCheckingForeignSession)
        // the watch holds the pump: the phone stands aside
        var holding = phone
        #expect(holding.phone(.watchHoldsPump(epoch: watch.epoch, status: podStatus), now: t0 + 61) == [.releasePump])
        #expect(holding.phase == .active)
        // it doesn't: the session is over
        var notHolding = phone
        #expect(notHolding.phone(.watchHoldsPump(epoch: watch.epoch, status: nil), now: t0 + 61) == [.takePump, .reconcile])
        #expect(notHolding.isIdle)
        #expect(notHolding.epoch == watch.epoch)
    }

    @Test("without phone: a pod out of reach for five minutes ends the start") func startWithoutPhoneTimeout() {
        var watch = UntetheredSession()
        _ = watch.watch(.startWithoutPhone, now: t0)
        #expect(watch.watch(.tick, now: t0 + 60) == [])
        let effects = watch.watch(.tick, now: t0 + UntetheredSession.takeoverWithoutPhoneLease + 1)
        #expect(effects.first == .releasePump)
        #expect(watch.phase == .idle)
    }

    @Test("without phone: what the pod delivered past the copy's history is booked") func unexplainedSinceCopy() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let midnight = utc.startOfDay(for: t0)
        let profile = [BasalProfileEntry(start: "00:00", minutes: 0, rate: 0.4)]
        func unexplained(_ podUnits: Double, at hours: Double = 1) -> Decimal? {
            UntetheredAudit.unexplainedSinceCopy(
                copyUnits: 10,
                copyAt: midnight,
                podUnits: podUnits,
                podAt: midnight.addingTimeInterval(hours * 60 * 60),
                history: [],
                basalProfile: profile,
                bolusDeliveryRate: bolusDeliveryRate,
                calendar: utc
            )
        }
        // 1.0 U delivered, 0.4 U of it the scheduled basal
        #expect(unexplained(11).map { abs(NSDecimalNumber(decimal: $0 - 0.6).doubleValue) < 0.0001 } == true)
        #expect(unexplained(10.45) == nil)
        #expect(unexplained(11, at: -1) == nil)
    }

    @Test("a relaunch restores the session") func persistence() throws {
        let (phone, _) = started()
        let data = try JSONEncoder().encode(phone)
        #expect(try JSONDecoder().decode(UntetheredSession.self, from: data) == phone)
    }

    @Test("a session saved before a field was added still restores") func persistenceOlderSave() throws {
        let (phone, _) = started()
        var saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(phone)) as? [String: Any])
        saved["startedWithoutPhone"] = nil
        saved["handbackLetGo"] = nil
        let restored = try JSONDecoder().decode(UntetheredSession.self, from: JSONSerialization.data(withJSONObject: saved))
        #expect(restored == phone)
    }

    @Test("wire: an envelope survives the transport") func transport() throws {
        let envelope = UntetheredEnvelope(epoch: 42, message: .prepare(grant(linked: "override-1")))
        let payload = try envelope.payload()
        #expect(try UntetheredEnvelope.decode(payload) == envelope)
        #expect(try UntetheredEnvelope.decode(["watchState": 1]) == nil)
    }

    @Test("sync: bucket repair converges, versions included") func reconcile() {
        func entry(_ key: String, _ minutes: Double) -> UntetheredSyncEntry {
            UntetheredSyncEntry(key: key, id: UUID(), date: t0.addingTimeInterval(minutes * 60))
        }
        let watch = [entry("bg:1", 0), entry("bg:2", 5), entry("pump:a", 7), entry("carbs:x", 40), entry("bg:9", 95)]
        // the phone missed one, holds an old version of another and knows nothing of the last bucket
        var phone = [watch[0], watch[1], UntetheredSyncEntry(key: "pump:a", id: UUID(), date: watch[2].date), watch[3]]

        for _ in 0 ..< 3 {
            let request = UntetheredSyncEntry.bucketChecksumList(of: phone)
            let differing = UntetheredSyncEntry.differingBuckets(
                local: watch,
                remoteStart: request.start,
                remoteChecksums: request.checksums
            )
            if differing.isEmpty { break }
            // the watch resends those buckets whole; the phone replaces them
            phone.removeAll { differing.contains($0.bucket) }
            phone += watch.filter { differing.contains($0.bucket) }
        }

        let request = UntetheredSyncEntry.bucketChecksumList(of: phone)
        #expect(
            UntetheredSyncEntry.differingBuckets(local: watch, remoteStart: request.start, remoteChecksums: request.checksums)
                .isEmpty
        )
        #expect(Set(phone.map(\.id)) == Set(watch.map(\.id)))
    }

    @Test("sync: hashing is stable across processes") func fnv() {
        #expect(UntetheredSyncEntry.fnv1a("") == 0xCBF2_9CE4_8422_2325)
        #expect(UntetheredSyncEntry.fnv1a("a") == 0xAF63_DC4C_8601_EC8C)
    }

    @Test("audit: boluses, temps, suspension and scheduled basal") func audit() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let midnight = utc.startOfDay(for: t0)
        let profile = [
            BasalProfileEntry(start: "00:00", minutes: 0, rate: 1),
            BasalProfileEntry(start: "01:00", minutes: 60, rate: 2)
        ]
        func at(_ minutes: Double) -> Date { midnight.addingTimeInterval(minutes * 60) }
        let history = [
            PumpHistoryEvent(id: "b", type: .bolus, timestamp: at(10), amount: 1.5),
            PumpHistoryEvent(id: "s", type: .smb, timestamp: at(20), amount: 0.3, deliveredUnits: 0.25),
            // 3 U/h for 30 min from 0:30, cut short by a suspend at 0:45 that resumes at 0:50
            PumpHistoryEvent(id: "t", type: .tempBasal, timestamp: at(30), amount: 3, duration: 30),
            PumpHistoryEvent(id: "p", type: .pumpSuspend, timestamp: at(45)),
            PumpHistoryEvent(id: "r", type: .pumpResume, timestamp: at(50)),
            // 9 U take 6 minutes: over before the span starts
            PumpHistoryEvent(id: "old", type: .bolus, timestamp: at(-7), amount: 9),
            // entered by hand: not the pump's
            PumpHistoryEvent(id: "pen", type: .bolus, timestamp: at(40), amount: 1, isExternal: true)
        ]
        let expected = UntetheredAudit.expectedDelivery(
            from: at(0),
            to: at(90),
            history: history,
            basalProfile: profile,
            bolusDeliveryRate: bolusDeliveryRate,
            calendar: utc
        )
        // boluses 1.75; basal 0:00–0:30 at 1 = 0.5; temp 0:30–0:45 at 3 = 0.75; suspended 5 min;
        // temp 0:50–1:00 at 3 = 0.5; scheduled 1:00–1:30 at 2 = 1
        #expect(abs(NSDecimalNumber(decimal: expected - 4.5).doubleValue) < 0.0001)
    }

    @Test("audit: a bolus running at an edge counts for its part inside the span") func auditBolusAtEdge() {
        // a 6.65 U bolus that started 160 s before the watch took over: 2.65 U of it falls after
        let start = t0
        let history = [PumpHistoryEvent(id: "b", type: .bolus, timestamp: t0 - 160, amount: 6.65)]
        func expected(from: Date, to: Date) -> Decimal {
            UntetheredAudit.expectedDelivery(
                from: from, to: to, history: history, basalProfile: [], bolusDeliveryRate: bolusDeliveryRate
            )
        }
        let inside = expected(from: start, to: start + 3600)
        #expect(abs(NSDecimalNumber(decimal: inside - 2.65).doubleValue) < 0.0001)
        // and the 4 U before it, of a span ending as the watch took over
        let before = expected(from: start - 3600, to: start)
        #expect(abs(NSDecimalNumber(decimal: before - 4).doubleValue) < 0.0001)
    }

    @Test("audit: a finalized temp counts what the pump reported, in proportion where the span cuts it") func auditReportedTemps() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let midnight = utc.startOfDay(for: t0)
        func at(_ minutes: Double) -> Date { midnight.addingTimeInterval(minutes * 60) }
        // 2.1 U/h replaced after 5 min: 0.175 U by its rate, the pod reported 0.15
        let history = [
            PumpHistoryEvent(id: "a", type: .tempBasal, timestamp: at(0), amount: 2.1, duration: 30, deliveredUnits: 0.15),
            PumpHistoryEvent(id: "b", type: .tempBasal, timestamp: at(5), amount: 0, duration: 30)
        ]
        let profile = [BasalProfileEntry(start: "00:00", minutes: 0, rate: 1)]
        func expected(from start: Double) -> Double {
            NSDecimalNumber(decimal: UntetheredAudit.expectedDelivery(
                from: at(start), to: at(10), history: history, basalProfile: profile,
                bolusDeliveryRate: bolusDeliveryRate, calendar: utc
            )).doubleValue
        }
        #expect(abs(expected(from: 0) - 0.15) < 0.0001)
        #expect(abs(expected(from: 2.5) - 0.075) < 0.0001)
    }

    @Test("audit: the verdict leaves the tolerance alone and names the difference") func auditVerdict() {
        // in hundredths: a float literal would not be exact as a Decimal
        func units(_ hundredths: Int) -> Decimal { Decimal(hundredths) / 100 }
        #expect(UntetheredAudit.verdict(delivered: units(345), expected: units(357)) == .explained)
        #expect(UntetheredAudit.verdict(delivered: units(300), expected: units(250)) == .unrecorded(units(50)))
        // 16.45 U delivered, records 17.32 U: a return that lost the watch's zero temps
        #expect(UntetheredAudit.verdict(delivered: units(1645), expected: units(1732)) == .overstated(units(87)))
    }

    @Test("sensor window: history waits around each due reading, never after one arrived") func sensorWindow() {
        // 19:59:09 the reading's own time (linked 19:59:15, age 6); 20:04:09 is due
        let reading = t0
        func end(after seconds: TimeInterval) -> Date? {
            UntetheredSensorWindow.end(now: reading.addingTimeInterval(seconds), lastReading: reading)
        }
        #expect(end(after: 15) == nil, "right after the loop: clear")
        #expect(end(after: 269) == nil, "until shortly before the next one")
        #expect(end(after: 270) == reading.addingTimeInterval(340))
        #expect(end(after: 310) == reading.addingTimeInterval(340), "the link comes up a few seconds after the reading's time")
        #expect(end(after: 341) == nil, "a reading that didn't come doesn't hold history back")
        #expect(end(after: 575) == reading.addingTimeInterval(640), "the one after that is due on the same beat")
        #expect(UntetheredSensorWindow.end(now: reading, lastReading: nil) == nil)
    }

    @Test("records: a session the phone gave up on keeps its history; a complete one isn't stored twice") func recordsOfEndedSessions() throws {
        // a start the phone gave up on: idle, its history never opened
        var state = UntetheredPhoneState()
        _ = state.session.phone(.start(grant()), now: t0)
        _ = state.session.phone(.tick, now: t0 + UntetheredSession.prepareTimeout + 1)
        let epoch = state.session.epoch
        #expect(state.session.isIdle)
        #expect(state.storesRecords(epoch: epoch) == false, "a file from before syncedEpoch: as before")
        state.syncedEpoch = epoch - 1
        #expect(state.storesRecords(epoch: epoch) == true, "the watch may have dosed in it: stored")
        #expect(state.storesRecords(epoch: epoch - 1) == false, "complete already: a late copy isn't stored twice")
        #expect(state.storesRecords(epoch: epoch + 1) == nil, "newer than the phone's: sent again later")
        state.applied[epoch - 2] = [:]
        #expect(state.storesRecords(epoch: epoch - 2) == true, "history still open")
        let decoded = try JSONDecoder().decode(UntetheredPhoneState.self, from: JSONEncoder().encode(state))
        #expect(decoded.syncedEpoch == epoch - 1)
    }

    @Test("audit: a return's point survives a relaunch until the complete history judges it") func auditPointPersistence() throws {
        var state = UntetheredPhoneState()
        state.audit = UntetheredAuditPoint(epoch: 7, start: t0, startUnits: 10, end: t0.addingTimeInterval(3600), endUnits: 11.5)
        state.watchPendingDoses = [7: ["74656d70"]]
        state.auditFinding = "The records show 0.87 U more insulin than the pump delivered."
        let decoded = try JSONDecoder().decode(UntetheredPhoneState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        #expect(decoded.audit?.delivered == 1.5)
        #expect(decoded.watchPendingDoseIdentifiers == ["74656d70"])
        // a file written before these fields existed still reads
        let old = try JSONDecoder().decode(UntetheredPhoneState.self, from: Data(#"{"pumpReturnPending":true}"#.utf8))
        #expect(old.audit == nil && old.auditFinding == nil && old.watchPendingDoses.isEmpty && old.pumpReturnPending)
    }

    @Test("smoothing: steady glucose stays put, a gap falls back to raw, 38 ends the window") func smoothing() {
        func series(_ values: [Int], every minutes: Double = 5) -> [(date: Date?, glucose: Int)] {
            values.enumerated().map { (date: t0.addingTimeInterval(Double($0.offset) * minutes * 60), glucose: $0.element) }
        }
        let steady = GlucoseSmoothing.smoothed(series(Array(repeating: 120, count: 10)))
        #expect(steady.dropFirst().allSatisfy { $0 == 120 })
        #expect(steady.first! == nil)

        // a 20-minute gap leaves only two recent readings: too few to smooth, so they take their raw values
        var gapped = series([100, 110, 120, 130, 140])
        gapped += [(date: t0.addingTimeInterval(45 * 60), glucose: 150), (date: t0.addingTimeInterval(50 * 60), glucose: 160)]
        let afterGap = GlucoseSmoothing.smoothed(gapped)
        #expect(afterGap.suffix(2) == [150, 160])
        #expect(afterGap.prefix(5).allSatisfy { $0 == nil })

        let rising = GlucoseSmoothing.smoothed(series([100, 104, 108, 112, 116, 120]))
        #expect(rising.last!! <= 120 && rising.last!! >= 110)
    }

    @Test("wire: a full day's grant fits an interactive message") func grantSize() throws {
        let base = grant()
        let readings = (0 ..< 288).map { index -> BloodGlucose in
            let date = t0.addingTimeInterval(Double(-index) * 300)
            return BloodGlucose(
                sgv: 100 + index % 80, direction: .flat, date: Decimal(Int(date.timeIntervalSince1970 * 1000)),
                dateString: date, unfiltered: Decimal(100 + index % 80), glucose: 100 + index % 80, type: "sgv"
            )
        }
        // an SMB and a temp basal every five minutes: a busy day
        let events = (0 ..< 288).flatMap { index -> [PumpHistoryEvent] in
            let date = t0.addingTimeInterval(Double(-index) * 300)
            return [
                PumpHistoryEvent(
                    id: UUID().uuidString,
                    type: .bolus,
                    timestamp: date,
                    amount: 0.35,
                    duration: 0,
                    isSMB: true,
                    isExternal: false
                ),
                PumpHistoryEvent(id: UUID().uuidString, type: .tempBasalDuration, timestamp: date, durationMin: 30),
                PumpHistoryEvent(id: UUID().uuidString, type: .tempBasal, timestamp: date, rate: 1.35, temp: .absolute)
            ]
        }
        let tddEvents = (0 ..< 288).flatMap { index -> [PumpHistoryEvent] in
            let date = t0.addingTimeInterval(Double(-index) * 300)
            return [
                PumpHistoryEvent(id: UUID().uuidString, type: .bolus, timestamp: date, amount: 0.35),
                PumpHistoryEvent(
                    id: UUID().uuidString,
                    type: .tempBasal,
                    timestamp: date,
                    amount: 1.35,
                    duration: 30,
                    isScheduledBasal: false,
                    deliveredUnits: 0.1
                )
            ]
        }
        let full = UntetheredGrant(
            leaseExpiresAt: base.leaseExpiresAt, pumpConfiguration: Data(count: 3000), cgmConfiguration: Data(count: 1500),
            pumpSettings: base.pumpSettings, bgTargets: base.bgTargets, basalProfile: base.basalProfile,
            insulinSensitivities: base.insulinSensitivities, carbRatios: base.carbRatios, preferences: base.preferences,
            dosingMode: base.dosingMode, smoothGlucose: true, units: base.units, tdd: base.tdd, hasSufficientTDD: true,
            tddRecentRows: (0 ..< 24).map { UntetheredTDD(
                date: t0.addingTimeInterval(Double(-$0) * 300),
                total: 42.5,
                bolus: 20,
                tempBasal: 12,
                scheduledBasal: 10.5,
                weightedAverage: 41.2
            ) },
            tddHours: (0 ..< 240).map { UntetheredTDDHour(
                start: t0.addingTimeInterval(Double(-$0) * 3600),
                total: 500,
                positive: 12,
                count: 12
            ) },
            tddPumpHistory: tddEvents,
            autosens: base.autosens, reservoir: base.reservoir, maxBolus: base.maxBolus, maxCarbs: base.maxCarbs,
            bolusCalculator: base.bolusCalculator, glucoseColorScheme: "dynamicColor", lastDetermination: nil,
            lastLoopDate: t0, lowGlucose: 70, highGlucose: 180,
            pumpHistory: events, glucose: readings,
            smoothedGlucose: Dictionary(uniqueKeysWithValues: readings.map { ($0.id, Decimal($0.glucose ?? 0)) }),
            carbs: (0 ..< 6).map { _ in CarbsEntry(
                id: UUID().uuidString,
                createdAt: t0,
                actualDate: t0,
                carbs: 40,
                fat: nil,
                protein: nil,
                note: nil,
                enteredBy: "Trio",
                isFPU: false,
                fpuID: nil
            ) },
            activeOverride: nil, tempTargets: [], overridePresets: [], tempTargetPresets: [], linkedOverrideID: nil
        )
        let size = (try UntetheredEnvelope(epoch: 1, message: .prepare(full)).payload()[UntetheredEnvelope.key] as! Data).count
        print("grant size: \(size) bytes")

        // too close to WatchConnectivity's limit to rely on one message: it travels in parts, in any order
        let payload = try UntetheredEnvelope(epoch: 1, message: .prepare(full)).payload()
        let parts = try #require(UntetheredChunks.split(payload))
        #expect(parts.count >= 2)
        let assembler = UntetheredChunks.Assembler()
        var assembled: [String: Any]?
        for part in parts.reversed() { assembled = assembler.add(part) ?? assembled }
        #expect(try UntetheredEnvelope.decode(try #require(assembled)) == UntetheredEnvelope(epoch: 1, message: .prepare(full)))
        #expect(UntetheredChunks.split(try UntetheredEnvelope(epoch: 1, message: .commit(handover)).payload()) == nil)
    }

    @Test("TDD: the ten days slide by the hour, zeros count only where the phone counts them") func tddHours() {
        func row(_ hoursAgo: Double, _ total: Decimal) -> UntetheredTDD {
            UntetheredTDD(
                date: t0.addingTimeInterval(-hoursAgo * 3600),
                total: total,
                bolus: 0,
                tempBasal: 0,
                scheduledBasal: 0,
                weightedAverage: nil
            )
        }
        let hours = UntetheredTDDHour.hours([row(0.1, 40), row(0.2, 0), row(5, 30), row(10 * 24 - 2, 90)])
        #expect(hours.count == 3)
        let now = UntetheredTDDHour.inWindow(hours, now: t0)
        #expect(now.reduce(0) { $0 + $1.total } == 160)
        #expect(now.reduce(0) { $0 + $1.positive } == 3)
        #expect(now.reduce(0) { $0 + $1.count } == 4)
        // three hours on, the oldest has left the window
        let later = UntetheredTDDHour.inWindow(hours, now: t0.addingTimeInterval(3 * 3600))
        #expect(later.reduce(0) { $0 + $1.total } == 70)
    }

    @Test("TDD summary matches the phone's averaging") func tdd() {
        let now = t0
        let entries: [(date: Date, total: Decimal)] = [
            (now.addingTimeInterval(-3 * 86400), 30),
            (now.addingTimeInterval(-3600), 40),
            (now.addingTimeInterval(-60), 50)
        ]
        let summary = OrefPipeline.tddSummary(entries, now: now)
        #expect(summary.currentTDD == 50)
        #expect(summary.averageLastTenDays == 40)
        #expect(summary.averageLastTwoHours == 45)

        let empty = OrefPipeline.customOrefVariables(
            override: nil,
            tdd: OrefPipeline.tddSummary([], now: now),
            preferences: nil,
            now: now
        )
        #expect(empty.weightedAverage == 1)
        #expect(empty.smbMinutes == 30)
        #expect(!empty.useOverride)
    }

    @Test("algorithm: a resume without its suspend in the last day is dropped") func orphanedResumes() {
        let resume = PumpHistoryEvent(id: "r0", type: .pumpResume, timestamp: t0)
        let oldSuspend = PumpHistoryEvent(id: "s1", type: .pumpSuspend, timestamp: t0 + 3600)
        let lateResume = PumpHistoryEvent(id: "r1", type: .pumpResume, timestamp: t0 + 3600 + 25 * 3600)
        let suspend = PumpHistoryEvent(id: "s2", type: .pumpSuspend, timestamp: t0 + 30 * 3600)
        let pairedResume = PumpHistoryEvent(id: "r2", type: .pumpResume, timestamp: t0 + 31 * 3600)
        let kept = UntetheredAlgorithm.withoutOrphanedResumes([resume, oldSuspend, lateResume, suspend, pairedResume])
        #expect(kept.map(\.id) == ["s1", "s2", "r2"])
    }

    @Test("algorithm: the newest temp basal runs for what is left of it") func historyTempBasal() {
        let history = [
            PumpHistoryEvent(id: "t", type: .tempBasalDuration, timestamp: t0, durationMin: 30),
            PumpHistoryEvent(id: "_t", type: .tempBasal, timestamp: t0, rate: 1.5, temp: .absolute)
        ]
        let running = UntetheredAlgorithm.historyTempBasal(history, now: t0 + 10 * 60)
        #expect(running.rate == 1.5)
        #expect(running.duration == 20)
        #expect(UntetheredAlgorithm.historyTempBasal([], now: t0).duration == 0)
    }

    #if canImport(LoopKit)
    @Test("algorithm: pump events in the algorithm's shape and the TDD's") func pumpEventShapes() {
        // in the past: events from the future are booked at the current time
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let temp = NewPumpEvent(
            date: start,
            dose: DoseEntry(
                type: .tempBasal, startDate: start, endDate: start + 30 * 60, value: 2, unit: .unitsPerHour,
                deliveredUnits: 0.6, syncIdentifier: "t"
            ),
            raw: Data([1]),
            title: "temp",
            type: .tempBasal
        )
        let rows = UntetheredAlgorithm.historyEvents(temp, id: "t", bolusIncrement: 0.05)
        #expect(rows.map(\.id) == ["t", UntetheredAlgorithm.rateID("t")])
        #expect(rows.map(\.type) == [.tempBasalDuration, .tempBasal])
        #expect(rows.first?.durationMin == 30)
        #expect(rows.last?.rate == 2)
        let tdd = UntetheredAlgorithm.tddEvent(temp, id: "t", bolusIncrement: 0.05)
        #expect(tdd?.type == .tempBasal && tdd?.amount == 2 && tdd?.duration == 30)
        #expect(tdd?.deliveredUnits == Decimal(0.6 as Double))

        let bolus = NewPumpEvent(
            date: start,
            dose: DoseEntry(type: .bolus, startDate: start, value: 1.27, unit: .units, deliveredUnits: 1.27, automatic: false),
            raw: Data([2]),
            title: "bolus",
            type: .bolus
        )
        let booked = UntetheredAlgorithm.historyEvents(bolus, id: "b", bolusIncrement: 0.05)
        #expect(booked.first?.amount == 1.25)
        #expect(booked.first?.isSMB == false)
        #expect(UntetheredAlgorithm.tddEvent(bolus, id: "b", bolusIncrement: 0.05) == booked.first)
    }
    #endif

    @Test("TDD: the watch's weighted average is the phone's formula, zeros counted") func weightedAverage() {
        func row(_ minutesAgo: Double, _ total: Decimal) -> UntetheredTDD {
            UntetheredTDD(
                date: t0.addingTimeInterval(-minutesAgo * 60),
                total: total, bolus: 0, tempBasal: 0, scheduledBasal: 0, weightedAverage: nil
            )
        }
        let rows = [row(30, 40), row(10, 0)]
        let hours = UntetheredTDDHour.hours(rows + [row(3 * 24 * 60, 50)])
        let watch = UntetheredAlgorithm.weightedAverage(rows: rows, hours: hours, weight: 0.65, now: t0)
        let phone = TDDCalculator.weightedAverage(recentTotal: 40, recentCount: 2, tenDayTotal: 90, tenDayCount: 3, weight: 0.65)
        #expect(watch == phone)
        #expect(phone == 23.5)
        #expect(UntetheredAlgorithm.weightedAverage(rows: [], hours: [], weight: 0.65, now: t0) == 0)
    }

    @Test("TDD: enough rows for the dynamic formula, at the phone's threshold") func sufficientTDD() {
        let threshold = TDDCalculator.sufficientRowCount
        func hours(_ positive: Int) -> [UntetheredTDDHour] {
            [UntetheredTDDHour(start: t0 - 3600, total: 400, positive: positive, count: positive)]
        }
        #expect(UntetheredAlgorithm.hasSufficientTDD(hours: hours(threshold), now: t0) == true)
        #expect(UntetheredAlgorithm.hasSufficientTDD(hours: hours(threshold - 1), now: t0) == false)
        // only the last seven days count
        #expect(UntetheredAlgorithm.hasSufficientTDD(hours: hours(threshold), now: t0 + 8 * 24 * 3600) == false)
        #expect(UntetheredAlgorithm.hasSufficientTDD(hours: [], now: t0) == nil)
    }

    @Test("algorithm: no dynamic formula without enough TDD, clamped for the dosing mode") func determinationPreferences() {
        var preferences = Preferences()
        preferences.useNewFormula = true
        preferences.sigmoid = true
        preferences.maxIOB = 5
        let without = OrefPipeline.determinationPreferences(preferences, dosingMode: .closed, hasSufficientTDD: false)
        #expect(!without.useNewFormula && !without.sigmoid && without.maxIOB == 5)
        let with = OrefPipeline.determinationPreferences(preferences, dosingMode: .closed, hasSufficientTDD: true)
        #expect(with.useNewFormula && with.sigmoid)
        let suspendOnly = OrefPipeline.determinationPreferences(preferences, dosingMode: .lowGlucoseSuspend, hasSufficientTDD: true)
        #expect(suspendOnly.maxIOB == 0)
    }

    @Test("algorithm: the watch determines from its own readings") func determine() throws {
        let grant = grant()
        let now = t0
        let glucose = (0 ..< 288).map { index -> BloodGlucose in
            let date = now.addingTimeInterval(Double(-index) * 300)
            return BloodGlucose(
                sgv: 120, direction: .flat, date: Decimal(Int(date.timeIntervalSince1970 * 1000)),
                dateString: date, unfiltered: 120, glucose: 120, type: "sgv"
            )
        }
        var autosens = Autosens(ratio: 1, newisf: nil)
        autosens.timestamp = now
        let inputs = UntetheredAlgorithm.Inputs(
            grant: grant,
            pumpHistory: [],
            glucose: glucose,
            carbs: [],
            tempTargets: [],
            activeTempTarget: nil,
            override: nil,
            autosens: autosens,
            tdd: grant.tdd,
            hasSufficientTDD: true,
            currentTemp: TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: now),
            supportedBasalRates: (0 ... 60).map { Decimal($0) * 0.05 },
            now: now
        )
        let (determination, used) = try #require(try UntetheredAlgorithm.determine(inputs))
        #expect(determination.deliverAt != nil)
        #expect(determination.timestamp == determination.deliverAt)
        #expect(used?.timestamp == now)
    }

    @Test("Build check: a hand-over only between the same builds, an older sender counts as another build")
    func buildCheck() throws {
        #expect(UntetheredVersion.mismatch(phone: "1.0.2.15 (579)", watch: "1.0.2.15 (579)") == nil)
        #expect(UntetheredVersion.mismatch(phone: "1.0.2.15 (579)", watch: "1.0.2.13 (578)") != nil)
        // nothing known on one side: not a mismatch by itself
        #expect(UntetheredVersion.mismatch(phone: nil, watch: "1.0.2.15 (579)") == nil)

        // the sender's build travels with the envelope; one from before the check decodes without it
        let envelope = UntetheredEnvelope(epoch: 3, message: .startRequest, appVersion: "1.0.2.15 (579)")
        #expect(try UntetheredEnvelope.decode(try envelope.payload())?.appVersion == "1.0.2.15 (579)")
        let old = try JSONSerialization.data(withJSONObject: ["epoch": 3, "message": ["startRequest": [:] as [String: Any]]])
        let oldPayload: [String: Any] = [UntetheredEnvelope.key: try (old as NSData).compressed(using: .lzfse) as Data]
        let decoded = try UntetheredEnvelope.decode(oldPayload)
        #expect(decoded?.message == .startRequest)
        #expect(decoded?.appVersion == nil)

        // the watch's request to take the pump back travels like any other message
        let request = UntetheredEnvelope(epoch: 4, message: .handbackRequested(minutesWithoutLoop: 15))
        #expect(try UntetheredEnvelope.decode(try request.payload()) == request)
    }
}
