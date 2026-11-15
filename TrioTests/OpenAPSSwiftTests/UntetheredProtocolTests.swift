import Foundation
import Testing
@testable import Trio

/// Edges of the hand-over protocol, the audit, the history sync and the sensor window that `UntetheredTests` leaves
/// out. Its grant and pod status are reused, so both suites start sessions the same way.
@Suite("Untethered watch mode: protocol edges") struct UntetheredProtocolTests {
    let base = UntetheredTests()
    var t0: Date { base.t0 }
    var podStatus: UntetheredPodStatus { base.podStatus }
    var handover: UntetheredHandover { base.handover }

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func near(_ value: Decimal, _ expected: Double, _ tolerance: Double = 0.0001) -> Bool {
        abs(NSDecimalNumber(decimal: value).doubleValue - expected) < tolerance
    }

    // MARK: - Who may dose

    /// The phone queues every status query (`transferUserInfo`), so one from a start that failed can reach the watch
    /// during a later start. The watch answers any query, mid-takeover with "not holding", stamped with the current
    /// epoch. The phone must not read that as the answer to a question it never asked in this session: it would take
    /// the pump back while the watch goes on to take it and loop, with neither side noticing.
    @Test("start: a reply to an earlier session's status query doesn't take the pump mid-takeover")
    func staleStatusReport() {
        var phone = UntetheredSession()
        var watch = UntetheredSession()

        // the first start: the phone asks after the lease (from the watch's answer), then hears the takeover failed
        _ = phone.phone(.start(base.grant(lease: 60)), now: t0)
        let firstEpoch = phone.epoch
        _ = phone.phone(.received(.prepared, epoch: firstEpoch), now: t0)
        let asked = t0 + UntetheredSession.takeoverLease + UntetheredSession.statusQueryGrace + 1
        #expect(phone.phone(.tick, now: asked) == [.send(.statusQuery)])
        _ = phone.phone(.received(.takeoverFailed(reason: "pod"), epoch: firstEpoch), now: asked + 1)
        #expect(phone.isIdle)

        // a second start, five minutes later
        let later = t0 + 300
        let grant = base.grant(lease: 420)
        #expect(phone.phone(.start(grant), now: later) == [.send(.prepare(grant))])
        let epoch = phone.epoch
        #expect(epoch > firstEpoch)
        #expect(watch.watch(.received(.prepare(grant), epoch: epoch), now: later) == [.send(.prepared)])
        #expect(phone.phone(.received(.prepared, epoch: epoch), now: later) == [.commit])
        #expect(watch.watch(.received(.commit(handover), epoch: epoch), now: later + 1) == [.takeover])

        // the first session's queued query arrives now
        #expect(
            watch.watch(.received(.statusQuery, epoch: firstEpoch), now: later + 2) ==
                [.send(.statusReport(holding: nil))]
        )
        #expect(watch.epoch == epoch)
        // the phone hasn't asked in this session: it keeps waiting for the takeover
        #expect(phone.phone(.received(.statusReport(holding: nil), epoch: watch.epoch), now: later + 3) == [])
        #expect(phone.phase == .starting)

        #expect(watch.watch(.takeoverSucceeded(podStatus), now: later + 20) == [.send(.takeoverComplete(podStatus))])
        _ = phone.phone(.received(.takeoverComplete(podStatus), epoch: epoch), now: later + 21)
        #expect(phone.phase == .active)
        #expect(watch.phase == .active)
    }

    @Test("start: an answer to the phone's own query still ends a start the watch didn't take")
    func solicitedStatusReport() {
        var phone = UntetheredSession()
        _ = phone.phone(.start(base.grant(lease: 60)), now: t0)
        _ = phone.phone(.received(.prepared, epoch: phone.epoch), now: t0)
        // the lease runs from the watch's answer, not from the grant
        let asked = t0 + UntetheredSession.takeoverLease + UntetheredSession.statusQueryGrace + 1
        #expect(phone.phone(.tick, now: asked) == [.send(.statusQuery)])
        let effects = phone.phone(.received(.statusReport(holding: nil), epoch: phone.epoch), now: asked + 1)
        #expect(effects.first == .takePump)
        #expect(phone.isIdle)
    }

    @Test("start: the phone's epochs only grow, also when its clock goes back")
    func epochAfterClockChange() {
        var phone = UntetheredSession()
        _ = phone.phone(.start(base.grant()), now: t0)
        let first = phone.epoch
        #expect(first == Int(t0.timeIntervalSince1970))
        _ = phone.phone(.received(.rejected(reason: "no G7"), epoch: first), now: t0)
        _ = phone.phone(.start(base.grant()), now: t0 - 3600)
        #expect(phone.epoch == first + 1)
    }

    @Test("start: an end while the phone still offers the start keeps the pump on the phone")
    func endWhilePreparing() {
        var phone = UntetheredSession()
        _ = phone.phone(.start(base.grant()), now: t0)
        #expect(phone.phone(.end, now: t0 + 5) == [])
        #expect(phone.isIdle)
        // a late answer doesn't hand the pump over any more
        #expect(phone.phone(.received(.prepared, epoch: phone.epoch), now: t0 + 6) == [])
        #expect(phone.isIdle)
    }

    @Test("start: the watch accepts the phone's repeated offer and stays on its epoch")
    func repeatedPrepare() {
        var watch = UntetheredSession()
        let grant = base.grant()
        #expect(watch.watch(.received(.prepare(grant), epoch: 7), now: t0) == [.send(.prepared)])
        #expect(watch.watch(.received(.prepare(grant), epoch: 7), now: t0 + 4) == [.send(.prepared)])
        #expect(watch.phase == .preparing)
        #expect(watch.epoch == 7)
        // but not once it is taking the pump
        _ = watch.watch(.received(.commit(handover), epoch: 7), now: t0 + 5)
        guard case .send(.rejected) = watch.watch(.received(.prepare(grant), epoch: 7), now: t0 + 6).first else {
            Issue.record("a repeated offer mid-takeover was not refused")
            return
        }
        #expect(watch.phase == .starting)
    }

    @Test("start: the watch's takeover past its lease lets go and says so")
    func lateTakeoverSuccess() {
        var watch = UntetheredSession()
        _ = watch.watch(.received(.prepare(base.grant(lease: 60)), epoch: 7), now: t0)
        _ = watch.watch(.received(.commit(handover), epoch: 7), now: t0 + 1)
        let effects = watch.watch(.takeoverSucceeded(podStatus), now: t0 + 60)
        #expect(effects.first == .releasePump)
        guard case .send(.takeoverFailed) = effects.last else {
            Issue.record("no failure sent")
            return
        }
        #expect(watch.isIdle)
    }

    @Test("start: a failed pod read on the watch gives the pump back to the phone")
    func takeoverFailedOnWatch() {
        var phone = UntetheredSession()
        var watch = UntetheredSession()
        let grant = base.grant()
        _ = phone.phone(.start(grant), now: t0)
        _ = watch.watch(.received(.prepare(grant), epoch: phone.epoch), now: t0)
        _ = phone.phone(.received(.prepared, epoch: phone.epoch), now: t0)
        _ = watch.watch(.received(.commit(handover), epoch: phone.epoch), now: t0)
        #expect(
            watch.watch(.takeoverFailed("no answer"), now: t0 + 20) ==
                [.releasePump, .send(.takeoverFailed(reason: "no answer"))]
        )
        #expect(
            phone.phone(.received(.takeoverFailed(reason: "no answer"), epoch: phone.epoch), now: t0 + 21) ==
                [.takePump, .failed("no answer")]
        )
        #expect(phone.isIdle)
        #expect(watch.isIdle)
    }

    @Test("start: the watch's word for its own session decides, an older or the same epoch doesn't")
    func watchHoldsPumpWhileStarting() {
        var phone = UntetheredSession()
        _ = phone.phone(.start(base.grant(lease: 60)), now: t0)
        _ = phone.phone(.received(.prepared, epoch: phone.epoch), now: t0)
        let epoch = phone.epoch

        var same = phone
        #expect(same.phone(.watchHoldsPump(epoch: epoch, status: podStatus), now: t0 + 5) == [])
        #expect(same.phase == .starting)

        var newerHolding = phone
        #expect(newerHolding.phone(.watchHoldsPump(epoch: epoch + 1, status: podStatus), now: t0 + 5) == [.releasePump])
        #expect(newerHolding.phase == .active)
        #expect(newerHolding.epoch == epoch + 1)
        #expect(newerHolding.startedWithoutPhone)

        // "not holding" for a session the phone never knew: that session is over, the phone takes its number
        var newerNotHolding = phone
        #expect(newerNotHolding.phone(.watchHoldsPump(epoch: epoch + 1, status: nil), now: t0 + 5) == [.takePump, .reconcile])
        #expect(newerNotHolding.isIdle)
        #expect(newerNotHolding.epoch == epoch + 1)
    }

    @Test("revoke: a watch that never took the pump has nothing to release")
    func revokeByPhase() {
        var preparing = UntetheredSession()
        _ = preparing.watch(.received(.prepare(base.grant()), epoch: 7), now: t0)
        #expect(preparing.watch(.received(.revoke, epoch: 7), now: t0 + 1) == [])
        #expect(preparing.isIdle)
        #expect(!preparing.forced)

        var starting = UntetheredSession()
        _ = starting.watch(.received(.prepare(base.grant()), epoch: 7), now: t0)
        _ = starting.watch(.received(.commit(handover), epoch: 7), now: t0 + 1)
        #expect(starting.watch(.received(.revoke, epoch: 7), now: t0 + 2) == [.releasePump])
        #expect(starting.isIdle)
        #expect(starting.forced)
    }

    @Test("emergency: a stop on an idle watch sends nothing") func emergencyStopWhileIdle() {
        var watch = UntetheredSession()
        #expect(watch.watch(.emergencyStop(nil), now: t0) == [])
        #expect(watch.isIdle)
        #expect(!watch.forced)
    }

    @Test("emergency: a take-back with nothing handed over changes nothing") func forceTakeBackWhileIdle() {
        var phone = UntetheredSession()
        #expect(phone.phone(.forceTakeBack, now: t0) == [])
        #expect(phone.isIdle)
    }

    @Test("without phone: no second start while the watch has a session") func startWithoutPhoneWhileActive() {
        var (_, watch) = base.started()
        let epoch = watch.epoch
        #expect(watch.watch(.startWithoutPhone, now: t0 + 100) == [])
        #expect(watch.phase == .active)
        #expect(watch.epoch == epoch)
    }

    @Test("end: a second end while handing back sends nothing more") func repeatedEnd() {
        var (phone, watch) = base.started()
        #expect(phone.phone(.end, now: t0 + 100) == [.send(.endRequest)])
        #expect(phone.phone(.end, now: t0 + 101) == [])
        #expect(phone.phase == .ending)
        #expect(watch.watch(.received(.endRequest, epoch: watch.epoch), now: t0 + 101) == [.handback])
        #expect(watch.watch(.received(.endRequest, epoch: watch.epoch), now: t0 + 102) == [])
        // before the pod is read the watch offers nothing yet
        #expect(watch.watch(.tick, now: t0 + 103) == [])
    }

    @Test("end: a status query while handing back reports the pump as still held") func statusQueryWhileEnding() {
        var (_, watch) = base.started()
        _ = watch.watch(.end, now: t0 + 100)
        #expect(watch.watch(.received(.statusQuery, epoch: 0), now: t0 + 101) == [.send(.statusReport(holding: podStatus))])
    }

    @Test("persistence: a phone state with a running session survives a relaunch") func phoneStatePersistence() throws {
        var state = UntetheredPhoneState()
        state.session = base.started().phone
        state.spans = [UntetheredSpan(start: t0, end: nil, uploaded: false)]
        state.watchPendingDoses = [1: ["a"], 2: ["b", "a"]]
        let decoded = try JSONDecoder().decode(UntetheredPhoneState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        #expect(decoded.session.phase == .active)
        #expect(decoded.watchPendingDoseIdentifiers == ["a", "b"])
    }

    // MARK: - Audit

    @Test("audit: the scheduled basal follows the profile across midnight") func auditAcrossMidnight() {
        let midnight = utc.startOfDay(for: t0)
        let profile = [
            BasalProfileEntry(start: "23:00", minutes: 1380, rate: 2),
            BasalProfileEntry(start: "00:00", minutes: 0, rate: 1)
        ]
        let expected = UntetheredAudit.expectedDelivery(
            from: midnight - 30 * 60,
            to: midnight + 30 * 60,
            history: [],
            basalProfile: profile,
            bolusDeliveryRate: base.bolusDeliveryRate,
            calendar: utc
        )
        // 23:30–0:00 at 2 U/h, 0:00–0:30 at 1 U/h
        #expect(near(expected, 1.5))
    }

    @Test("audit: a temp that is the scheduled basal is counted by the profile") func auditScheduledBasalTemp() {
        let midnight = utc.startOfDay(for: t0)
        let history = [
            PumpHistoryEvent(id: "s", type: .tempBasal, timestamp: midnight, amount: 5, duration: 30, isScheduledBasal: true)
        ]
        let expected = UntetheredAudit.expectedDelivery(
            from: midnight,
            to: midnight + 3600,
            history: history,
            basalProfile: [BasalProfileEntry(start: "00:00", minutes: 0, rate: 1)],
            bolusDeliveryRate: base.bolusDeliveryRate,
            calendar: utc
        )
        #expect(near(expected, 1))
    }

    @Test("audit: a temp without a successor runs its own length, then the schedule") func auditTempOwnLength() {
        let midnight = utc.startOfDay(for: t0)
        let history = [PumpHistoryEvent(id: "t", type: .tempBasal, timestamp: midnight, amount: 3, duration: 30)]
        let expected = UntetheredAudit.expectedDelivery(
            from: midnight,
            to: midnight + 3600,
            history: history,
            basalProfile: [BasalProfileEntry(start: "00:00", minutes: 0, rate: 1)],
            bolusDeliveryRate: base.bolusDeliveryRate,
            calendar: utc
        )
        // 30 min at 3 U/h, 30 min at 1 U/h
        #expect(near(expected, 2))
    }

    @Test("audit: a suspension from before the span holds until its resume") func auditSuspendedAtStart() {
        let midnight = utc.startOfDay(for: t0)
        let history = [
            PumpHistoryEvent(id: "p", type: .pumpSuspend, timestamp: midnight - 600),
            PumpHistoryEvent(id: "r", type: .pumpResume, timestamp: midnight + 600)
        ]
        let expected = UntetheredAudit.expectedDelivery(
            from: midnight,
            to: midnight + 1800,
            history: history,
            basalProfile: [BasalProfileEntry(start: "00:00", minutes: 0, rate: 1)],
            bolusDeliveryRate: base.bolusDeliveryRate,
            calendar: utc
        )
        // 20 of the 30 minutes at 1 U/h
        #expect(near(expected, 1.0 / 3))
    }

    @Test("audit: a bolus still running at the span's end counts only its part inside") func auditBolusAtEnd() {
        // 3 U at 0.025 U/s take 120 s; the span ends 60 s in
        let history = [PumpHistoryEvent(id: "b", type: .bolus, timestamp: t0 + 3540, amount: 3)]
        let expected = UntetheredAudit.expectedDelivery(
            from: t0, to: t0 + 3600, history: history, basalProfile: [], bolusDeliveryRate: base.bolusDeliveryRate
        )
        #expect(near(expected, 1.5))
    }

    @Test("audit: without a delivery rate a bolus counts whole at its start") func auditBolusWithoutRate() {
        func expected(at offset: TimeInterval) -> Decimal {
            UntetheredAudit.expectedDelivery(
                from: t0,
                to: t0 + 3600,
                history: [PumpHistoryEvent(id: "b", type: .bolus, timestamp: t0 + offset, amount: 3)],
                basalProfile: [],
                bolusDeliveryRate: 0
            )
        }
        #expect(near(expected(at: 3599), 3))
        #expect(near(expected(at: 3600), 0), "the span's end is outside it")
        #expect(near(expected(at: 0), 3), "the span's start is inside it")
    }

    @Test("audit: a pod whose counter went back is not judged") func unexplainedCounterBack() {
        let unexplained = UntetheredAudit.unexplainedSinceCopy(
            copyUnits: 50,
            copyAt: t0,
            podUnits: 2,
            podAt: t0 + 3600,
            history: [],
            basalProfile: [BasalProfileEntry(start: "00:00", minutes: 0, rate: 1)],
            bolusDeliveryRate: base.bolusDeliveryRate,
            calendar: utc
        )
        #expect(unexplained == nil)
        #expect(UntetheredAudit.unexplainedSinceCopy(
            copyUnits: nil, copyAt: t0, podUnits: 12, podAt: t0 + 3600, history: [], basalProfile: [],
            bolusDeliveryRate: base.bolusDeliveryRate
        ) == nil)
    }

    @Test("audit: the tolerance itself is still explained") func auditVerdictAtTolerance() {
        let tolerance = UntetheredAudit.tolerance
        #expect(UntetheredAudit.verdict(delivered: 10 + tolerance, expected: 10) == .explained)
        #expect(UntetheredAudit.verdict(delivered: 10, expected: 10 + tolerance) == .explained)
        #expect(UntetheredAudit.verdict(delivered: 10, expected: 10) == .explained)
    }

    // MARK: - History sync

    @Test("sync: a reading on a bucket's first second belongs to that bucket") func bucketBoundary() {
        // 1 800 000 000 s is exactly bucket 1 000 000
        #expect(UntetheredChecksum.bucket(of: t0.timeIntervalSince1970) == 1_000_000)
        #expect(UntetheredChecksum.bucket(of: t0.timeIntervalSince1970 - 1) == 999_999)
        #expect(UntetheredChecksum.bucket(of: t0.timeIntervalSince1970 + UntetheredChecksum.bucketLength - 1) == 1_000_000)
    }

    @Test("sync: the checksum list is contiguous, empty buckets as zero") func checksumListGaps() {
        let entries = [
            UntetheredSyncEntry(key: "bg:1", id: UUID(), date: t0),
            UntetheredSyncEntry(key: "bg:2", id: UUID(), date: t0 + 3 * UntetheredChecksum.bucketLength)
        ]
        let list = UntetheredSyncEntry.bucketChecksumList(of: entries)
        #expect(list.start == 1_000_000)
        #expect(list.checksums.count == 4)
        #expect(list.checksums[1] == 0 && list.checksums[2] == 0)
        #expect(list.checksums[0] != 0 && list.checksums[3] != 0)
        #expect(UntetheredSyncEntry.bucketChecksumList(of: []).checksums.isEmpty)
    }

    @Test("sync: the order of the entries doesn't change a bucket's checksum") func checksumOrder() {
        let entries = (0 ..< 6).map { UntetheredSyncEntry(key: "bg:\($0)", id: UUID(), date: t0 + Double($0) * 60) }
        #expect(
            UntetheredSyncEntry.bucketChecksums(of: entries) ==
                UntetheredSyncEntry.bucketChecksums(of: Array(entries.reversed()))
        )
    }

    @Test("sync: a bucket only one side has differs, both ways round") func oneSidedBucket() {
        let entry = UntetheredSyncEntry(key: "bg:1", id: UUID(), date: t0)
        let list = UntetheredSyncEntry.bucketChecksumList(of: [entry])
        let phoneOnly = UntetheredSyncEntry.differingBuckets(local: [], remoteStart: list.start, remoteChecksums: list.checksums)
        #expect(phoneOnly == [1_000_000])
        let watchOnly = UntetheredSyncEntry.differingBuckets(local: [entry], remoteStart: 0, remoteChecksums: [])
        #expect(watchOnly == [1_000_000])
        #expect(UntetheredSyncEntry.differingBuckets(local: [], remoteStart: 0, remoteChecksums: []).isEmpty)
    }

    @Test("sync: hashing matches the published FNV-1a vectors") func fnvVectors() {
        #expect(UntetheredSyncEntry.fnv1a("foobar") == 0x8594_4171_F739_67E8)
    }

    @Test("wire: records without algorithm payloads survive the transport") func recordsTransport() throws {
        let records = [
            UntetheredRecord(key: UntetheredRecord.glucoseKey(t0), date: t0, kind: .glucoseDeleted(date: t0)),
            UntetheredRecord(key: UntetheredRecord.carbsKey("c1"), date: t0, kind: .carbsDeleted(id: "c1")),
            UntetheredRecord(key: UntetheredRecord.pumpEventKey("p1"), date: t0, kind: .pumpEventDropped("p1")),
            UntetheredRecord(key: UntetheredRecord.loopCompletedKey, date: t0, kind: .loopCompleted(t0)),
            UntetheredRecord(key: UntetheredRecord.podEndedKey, date: t0, kind: .podEnded(t0)),
            UntetheredRecord(key: UntetheredRecord.overrideKey(t0), date: t0 + 60, kind: .overrideEnded(start: t0)),
            UntetheredRecord(
                key: UntetheredRecord.pumpStatusKey,
                date: t0,
                kind: .pumpStatus(UntetheredPumpStatus(date: t0, reservoir: 42.5, expiresAt: t0 + 3600, isSuspended: false))
            )
        ]
        let envelope = UntetheredEnvelope(epoch: 9, message: .records(records))
        #expect(try UntetheredEnvelope.decode(envelope.payload()) == envelope)
    }

    // MARK: - Sensor window and temp basal hand-over

    @Test("sensor window: after a long gap the window still falls on the sensor's beat") func sensorWindowAfterGap() {
        let reading = t0
        #expect(UntetheredSensorWindow.end(now: reading + 3550, lastReading: reading) == nil)
        #expect(UntetheredSensorWindow.end(now: reading + 3580, lastReading: reading) == reading + 3640)
        #expect(UntetheredSensorWindow.end(now: reading + 3630, lastReading: reading) == reading + 3640)
    }

    @Test("sensor window: a reading dated after now holds nothing back") func sensorWindowFutureReading() {
        #expect(UntetheredSensorWindow.end(now: t0, lastReading: t0 + 10) == nil)
        #expect(UntetheredSensorWindow.end(now: t0, lastReading: t0) == nil)
    }

    @Test("handover: a pump without temp durations sets no temp again") func remainingWithoutDurations() {
        let temp = UntetheredTempBasal(unitsPerHour: 1, endsAt: t0 + 600)
        #expect(temp.remainingDuration(at: t0, supportedDurations: []) == nil)
    }
}

/// Which side waits for an update when the two builds differ.
@Suite("Untethered build check") struct UntetheredBuildCheckTests {
    @Test("The build number comes from the parentheses") func buildNumber() {
        #expect(UntetheredVersion.build(of: "1.0.2.69 (760)") == 760)
        #expect(UntetheredVersion.build(of: "1.0.2.69") == nil)
        #expect(UntetheredVersion.build(of: nil) == nil)
    }

    @Test("A newer iPhone build means the watch app waits for its update") func phoneNewer() {
        #expect(UntetheredVersion.phoneIsNewer(phone: "1.0.2.69 (760)", watch: "1.0.2.67 (741)"))
        #expect(!UntetheredVersion.phoneIsNewer(phone: "1.0.2.67 (741)", watch: "1.0.2.69 (760)"))
        #expect(!UntetheredVersion.phoneIsNewer(phone: "1.0.2.69 (760)", watch: "1.0.2.69 (760)"))
        #expect(!UntetheredVersion.phoneIsNewer(phone: "1.0.2.69 (760)", watch: nil))
    }

    @Test("Only a watch app behind the iPhone is told to close Trio on the watch") func mismatchText() {
        let watchBehind = UntetheredVersion.mismatch(phone: "1.0.2.69 (760)", watch: "1.0.2.67 (741)")
        let phoneBehind = UntetheredVersion.mismatch(phone: "1.0.2.67 (741)", watch: "1.0.2.69 (760)")
        #expect(watchBehind?.contains(UntetheredVersion.closeOnWatch) == true)
        #expect(phoneBehind != nil)
        #expect(phoneBehind?.contains(UntetheredVersion.closeOnWatch) == false)
        #expect(UntetheredVersion.mismatch(phone: "1.0.2.69 (760)", watch: "1.0.2.69 (760)") == nil)
    }
}
