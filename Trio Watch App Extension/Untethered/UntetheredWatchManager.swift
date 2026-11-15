import Foundation
import LoopKit
import UserNotifications
import WatchConnectivity
import WatchKit

/// The watch's side of untethered mode: takes the pump from the phone, loops with its own pump and
/// CGM connections, and gives the pump and its history back. Everything runs on the main queue,
/// device delegates included; every change is persisted before it is acted on.
@Observable final class UntetheredWatchManager {
    static let shared = UntetheredWatchManager()

    @ObservationIgnored let store = UntetheredStore()
    /// What the screens read, refreshed after every change.
    private(set) var data: UntetheredWatchData
    /// Taking over or handing back.
    private(set) var isBusy = false
    /// Trio is in front and the watch is looking for a pod it doesn't know yet (`meetNewPodIfNeeded`).
    private(set) var isMeetingPod = false
    /// When the session's phase last changed: the status page says what a start or a hand-back is waiting for once
    /// it takes longer than it should.
    private(set) var phaseSince = Date()
    /// The last message to the phone that didn't get through; cleared by the next that did.
    private(set) var phoneTroubleAt: Date?
    /// The phone is reaching for the pod after the watch asked it to take it back: the watch's loops leave the pod
    /// alone until then, so the two don't race for its one link.
    @ObservationIgnored var podQuietUntil: Date?

    @ObservationIgnored var pumpManager: (PumpManager & ExclusiveDeviceControl)?
    @ObservationIgnored var cgmManager: CGMManager?
    @ObservationIgnored var isLooping = false
    /// The phone's standing grant as a fallback try started from it: a start seeds from it and drops it, and a try that
    /// never reached the pod dosed nothing, so the next try starts from it again.
    @ObservationIgnored var fallbackGrantCopy: (grant: UntetheredGrant, issuedAt: Date)?
    /// The fallback's witness: a pump manager that only looked at the pod, and when. Kept between two looks, so the
    /// second one sees whether another controller (the phone) made a session on the pod in between.
    @ObservationIgnored var fallbackWitness: (pump: PumpManager & ExclusiveDeviceControl, at: Date, issuedAt: Date?)?
    /// The witness, once its looks found nobody at the pod: the start's takeover goes on with it instead of making a
    /// second manager, so the watch never has two bidding for the pod.
    @ObservationIgnored var fallbackTakeoverPump: (pump: PumpManager & ExclusiveDeviceControl, issuedAt: Date?)?
    @ObservationIgnored var isWitnessingPod = false
    /// The manager a pod meeting reads the pod with, until it lets go (`meetNewPodIfNeeded`).
    @ObservationIgnored var meetingPump: (PumpManager & ExclusiveDeviceControl)?
    @ObservationIgnored var podMeetingTriedAt: Date?
    /// No looks at the pod until then, while the phone's newest reading stays this one: a look the phone sees as
    /// another controller's session holds its dosing up to 3 minutes if the watch can't answer it.
    @ObservationIgnored var fallbackLooksPaused: (phoneNewest: Date, until: Date)?
    /// The phone's own newest reading, held until the watch's own reading of that cycle had its chance.
    @ObservationIgnored var pendingPhoneReading: SessionReading?
    /// A loop that couldn't reach the pod: its reading and when it failed, to loop again once the pod link is back.
    @ObservationIgnored var podRetryPending: (glucose: Date, failedAt: Date)?
    /// The meal-time reminder set with the bolus being delivered, until its estimated end: a cancel counts it from then.
    @ObservationIgnored var pendingMealReminder: (minutes: Int, deliveredBy: Date)?
    /// When the watch's own meal-time reminder rings, for the countdown on the first page.
    var mealReminderFireDate: Date?
    /// The session loops on the phone's readings: when the first was taken since the watch's own last one. Shown on
    /// the first page and the status page, and warned about after 20 minutes.
    var readingsFromPhoneSince: Date?
    /// What the log last said about Start by Itself, so it says it again when it changes.
    @ObservationIgnored var loggedFallbackSetting: Bool?
    /// The phone's newest reading when the looks found nobody at the pod: while it stays the newest, the outage's next
    /// tries count with it. Each try needs its own chain of looks; cleared once the phone was seen at the pod.
    @ObservationIgnored var fallbackDecidedFor: Date?
    /// The first look of the unbroken chain of looks that found nobody at the pod, and how many there were; nil once
    /// the phone was seen at the pod or a start began.
    @ObservationIgnored var fallbackNobodySince: Date?
    @ObservationIgnored var fallbackNobodyLooks = 0
    /// When the deciding look let go of the pod: a try going on with that look's manager stops if the pod saw another
    /// controller since (`takeover(continuing:)`).
    @ObservationIgnored var fallbackDecidedAt: Date?
    /// The running try goes on with the deciding look's manager, whose message count is the pod's as of that look.
    @ObservationIgnored var fallbackTakeoverFromLook = false
    /// The try was stopped at its first read: the phone had used the pod after the deciding look.
    @ObservationIgnored var fallbackAbortedForPhone = false
    /// The manager a look reads the pod with, so the end of its background time can let go of the pod.
    @ObservationIgnored var lookingPump: (PumpManager & ExclusiveDeviceControl)?
    /// watchOS ended the look's background time: it stops reading and has let go of the pod.
    @ObservationIgnored var lookAbandoned = false
    /// The copy the fallback last called too old, once its request went out: it says so once per copy.
    @ObservationIgnored var loggedOldCopyFor: Date?
    /// When the copy a start without the phone runs on was issued: a newer one from the phone replaces it until the
    /// start has the pod.
    @ObservationIgnored var startCopyIssuedAt: Date?
    /// watchOS ended the running loop's background time: it starts no further pod command.
    @ObservationIgnored var loopHoldExpired = false
    /// A treatment came in while a loop ran; its determination follows.
    @ObservationIgnored var isDeterminationPending = false
    /// A mode changed while a loop ran; its constrained determination and enactment follow.
    @ObservationIgnored var isModeChangePending = false
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private let assembler = UntetheredChunks.Assembler()
    @ObservationIgnored var loopTimer: Timer?
    /// Keeps the loop's age and the stale-data checks on screen current between loops.
    @ObservationIgnored private var displayTimer: Timer?
    /// The pump is delivering a bolus: no hand-back, and the treatment button stops it.
    private(set) var isBolusing = false
    /// The running bolus from start to end, for its progress; nil while it is being started.
    private(set) var bolusWindow: DateInterval?
    @ObservationIgnored private var bolusEndTimer: Timer?
    /// When the pod link was last torn down and searched for afresh.
    @ObservationIgnored var lastPodLinkReset: Date?
    /// When the user was last told the pod can't be reached; repeated while the stall lasts.
    @ObservationIgnored var lastPodLinkNotice: Date?
    /// When the phone was last heard from: any untethered message, or the phone reachable.
    @ObservationIgnored var lastPhoneContact: Date?
    /// Since when the answer to the phone's ownership question waits for a reply that shows the phone has it.
    @ObservationIgnored var ownershipAnswerUnconfirmedSince: Date?
    /// The fallback's hand-back is waiting out its minute.
    @ObservationIgnored var fallbackHandbackPending = false
    /// When the watch last logged that it keeps the pump from a phone without readings.
    @ObservationIgnored var fallbackHandbackHeldLoggedAt: Date?
    /// This stall's request to the phone to take the pump back.
    @ObservationIgnored var handbackRequestedAt: Date?
    /// How many Pod Not Reachable notices this stall has brought; from the second on the watch vibrates harder.
    @ObservationIgnored var podLinkNoticeCount = 0
    /// When loops failed at the pod's link (the pod dropped it, or wasn't reached): two since the last loop shorten
    /// the wait before the pump goes back to the phone (`podLinkDropLimit`).
    @ObservationIgnored var podLinkFailures: [Date] = []
    /// When readings arrived during the session, one entry per batch: the pod stall check counts batches that had
    /// their loop, not reading times, as a backfill brings several old readings at once.
    @ObservationIgnored var readingArrivals: [Date] = []
    /// A sensor pairing is due: Trio has to be in front for its Bluetooth pairing request.
    var isPairingSensor = false
    @ObservationIgnored var pairingKeepAlive: SensorPairingKeepAlive?
    /// Extended Untethered Mode's workout runs: watchOS keeps Trio running between readings.
    var isKeptAwake = false
    /// The workout's newest heart rate, beats per minute, for the minimal screen.
    var heartRate: Double?
    @ObservationIgnored var workoutKeepAlive: UntetheredWorkoutKeepAlive?
    /// The last start had no permission or failed: tried again only with Trio in front, where watchOS can ask.
    @ObservationIgnored var workoutStartFailed = false
    /// The hand-back offer the warning was set for (`updateHandbackWarning`).
    @ObservationIgnored var scheduledHandbackWarning: Date?
    @ObservationIgnored var phoneSilentScheduledAt: Date?
    /// The workout was ended in watchOS during the session: it stays off until the next one.
    @ObservationIgnored var workoutEndedByUser = false
    @ObservationIgnored var workoutStartRequestedAt: Date?

    /// Records travel in batches small enough for an interactive message.
    private static let recordsPerMessage = 40
    /// Keep a small pipeline in flight: one-at-a-time made a large history take many phone round trips, while
    /// sending the whole backlog at once could clog WatchConnectivity's durable queue.
    private static let batchesInFlightLimit = 4
    private static let recordAckTimeout: TimeInterval = 30
    /// After a batch failed with the phone in reach: no tight loop of sends that keep failing.
    private static let retryDelay: TimeInterval = 15
    @ObservationIgnored private var streamTimer: Timer?
    /// The hand-back's last stage: no loop or bolus between the pod's last read and the phone taking it.
    @ObservationIgnored var isFinalizing = false
    /// How long the hand-back's backlog may take before the rest goes with the last records.
    private static let drainLimit: TimeInterval = 3 * 60
    /// How long the last records may take to be confirmed before the pump is offered anyway.
    private static let finalConfirmLimit: TimeInterval = 30
    /// The hand-back's own pod commands and its wait for a loop in flight end after this: in a stall they wait on a
    /// pod the watch can't reach (2026-10-20: one loop waited 41 minutes), and the phone reads the pod itself anyway.
    private static let handbackPodLimit: TimeInterval = 60
    /// Batches the phone has not confirmed storing yet. This also bounds durable transfers while the phone is away.
    @ObservationIgnored private var recordFlights: [UUID: (ids: Set<UUID>, sentAt: Date)] = [:]
    private static let takeoverReadInterval: UInt64 = 8_000_000_000
    /// A missing standing grant is asked for at most this often.
    private static let standingGrantRequestInterval: TimeInterval = 5 * 60
    @ObservationIgnored private var standingGrantRequestedAt: Date?

    var isActive: Bool { data.session.phase == .active || data.session.phase == .ending }

    private init() {
        adoptSavedState()
    }

    /// Takes on the saved state: at launch, and when a state locked at launch opens later.
    private func adoptSavedState() {
        data = store.data
        // before the watch's own G7 reader starts at launch: a running session keeps the sensor
        updateReaderStandAside()
        DispatchQueue.main.async {
            self.restoreDevices()
            self.requestStandingGrantIfMissing()
            self.updateTimers()
            // a hand-back the last process left: the pump offered stays without loops; one still draining goes on
            if self.data.session.phase == .ending {
                if self.data.session.handbackOfferedAt == nil { self.handback() } else { self.isFinalizing = true }
            }
            // what the last process handed over it can no longer follow; it goes once the phone link is up
            self.requeueUnconfirmed(stream: false)
            // the saved state, background loops included, is on screen at once, not after the phone link is up
            if self.isActive { self.publishToWatchState() }
            self.updateWorkoutKeepAlive()
        }
    }

    /// Every change reaches the screens at once, with the phone or without it.
    func refresh() {
        if store.openIfLocked() {
            Task { await WatchLogger.shared.log("⌚️ Untethered: saved state open again, taken on", force: true) }
            adoptSavedState()
            return
        }
        data = store.data
        updateHandbackWarning()
        // a new session counts from its own start
        if data.session.phase == .idle, data.podTotalCheck != nil {
            store.update { $0.podTotalCheck = nil }
            data = store.data
        }
        updateReaderStandAside()
        // the first page marks the reading as the watch's own while this mode reads the sensor
        // the phone's reading shows with the iPhone symbol
        let watchOwn = isActive && readingsFromPhoneSince == nil
        if WatchState.shared.currentGlucoseIsWatchOwn != watchOwn { WatchState.shared.currentGlucoseIsWatchOwn = watchOwn }
        // the face's watch symbol: before the readings go to the complication, so their redraw carries the last loop
        ComplicationStore.setUntethered(isActive, lastLoop: data.lastLoopDate)
        if isActive {
            publishToWatchState()
        } else if !WatchState.shared.treatmentMarkers.isEmpty {
            WatchState.shared.treatmentMarkers = []
        }
    }

    /// The watch's display-only G7 reader uses the same display slot on the sensor: from the grant to the
    /// hand-back the sensor belongs to this mode.
    private func updateReaderStandAside() {
        // A start without the phone leaves the sensor to the reader until the pod is reached: until then nothing else
        // reads it, and the reader's readings wake the app for the next try. On 24 October (tester, 16:35 to 16:54) the
        // reader paused as the fallback began, the pod didn't answer in the first seconds, and for 19 minutes nothing
        // read the sensor or woke the app, until the start ran out silently.
        let aside = !data.session.isIdle && !(data.session.phase == .starting && data.session.startedWithoutPhone)
        if Thread.isMainThread {
            WatchG7Reader.shared.standAside(aside)
        } else {
            DispatchQueue.main.async { WatchG7Reader.shared.standAside(aside) }
        }
    }

    /// Encryption timeouts on the sensor's link since its last reading (see `deviceManager(_:logEventForDeviceIdentifier:)`).
    @ObservationIgnored var sensorEncryptTimeouts = 0

    static var sensorRefusalMessage: String {
        String(
            localized: "The sensor refuses this watch's Bluetooth pairing. On the watch, open Settings › Bluetooth and forget the DXCM device, then tap Pair Again here and keep Trio open until a glucose value shows; accept the pairing request."
        )
    }

    /// The untethered page offers Pair Again: the sensor refuses the watch's pairing, or a pairing is under way and its
    /// request may not have come.
    var offersSensorPairAgain: Bool { data.lastError == Self.sensorRefusalMessage || isPairingSensor }

    /// The watch forgets its own pairing with the sensor, as the sensor page's Pair Again does; the next connection
    /// pairs again.
    func pairSensorAgain() {
        Task { await WatchLogger.shared.log("⌚️ Untethered: Pair Again tapped", force: true) }
        WatchG7Reader.shared.resetWatchPairing()
        sensorEncryptTimeouts = 0
        if data.lastError == Self.sensorRefusalMessage { setError(nil) }
    }

    func setError(_ message: String?) {
        if let message { Task { await WatchLogger.shared.log("⌚️ Untethered: \(message)", force: true) } }
        store.update { $0.lastError = message }
        refresh()
    }

    /// Changes the algorithm and its pump permissions for the watch-owned session.
    func setDosingMode(_ mode: DosingMode, notifyPhone: Bool = true) {
        guard data.session.phase == .active, let currentMode = data.grant?.dosingMode, currentMode != mode else { return }
        store.update { $0.grant?.dosingMode = mode }
        refresh()
        if notifyPhone {
            send(.dosingModeChanged(mode), epoch: data.session.epoch, queueing: true)
        }
        let shouldClearTempForBasalTesting = mode == .basalTesting && (pumpManager.map { pump in
            if case let .tempBasal(dose) = pump.status.basalDeliveryState { return dose.automatic ?? true }
            return false
        } ?? false)
        if shouldClearTempForBasalTesting, let pump = pumpManager {
            Task { @MainActor in
                do {
                    try await pump.enactTempBasal(unitsPerHour: 0, for: 0)
                    self.recordPumpStatus()
                } catch {
                    self.setError(String(
                        localized: "Couldn't cancel the automatic temp basal for basal testing: \(error.localizedDescription)"
                    ))
                }
                self.runLoop(.modeChanged)
            }
        } else {
            runLoop(.modeChanged)
        }
    }

    // MARK: - Messages from the phone

    /// One part of a large envelope; the completing part is handled with its own reply handler.
    func receiveChunk(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?) {
        DispatchQueue.main.async {
            if let payload = self.assembler.add(message) {
                self.receive(payload, replyHandler: replyHandler)
            } else {
                replyHandler?([:])
            }
        }
    }

    /// Called by `WatchState` for any payload carrying an `UntetheredEnvelope`.
    func receive(_ payload: [String: Any], replyHandler: (([String: Any]) -> Void)?) {
        guard let envelope = try? UntetheredEnvelope.decode(payload) else {
            replyHandler?([:])
            return
        }
        DispatchQueue.main.async { self.handle(envelope, replyHandler: replyHandler) }
    }

    private func handle(_ envelope: UntetheredEnvelope, replyHandler: (([String: Any]) -> Void)?) {
        lastPhoneContact = Date()
        notePhoneHeardForWarning()
        pauseLooksIfPhoneAtPod(envelope.message)
        if let version = envelope.appVersion, WatchState.shared.phoneAppVersion != version {
            WatchState.shared.phoneAppVersion = version
        }
        // also after a session: the notice waits while the watch has the pump
        notePhoneVersion()
        switch envelope.message {
        case let .prepare(grant):
            if let reason = UntetheredVersion.mismatch(phone: envelope.appVersion) ?? rejection(of: grant) {
                isBusy = false
                if let replyHandler {
                    reply(.rejected(reason: reason), epoch: envelope.epoch, via: replyHandler)
                } else {
                    send(.rejected(reason: reason), epoch: envelope.epoch)
                }
                return
            }
            let wasIdle = data.session.phase == .idle || data.session.phase == .preparing
            apply(.received(envelope.message, epoch: envelope.epoch), reply: replyHandler) {
                if wasIdle, $0.session.phase == .preparing, $0.session.epoch == envelope.epoch {
                    Self.seed(&$0, with: grant)
                }
            }

        case let .recordsStored(ids):
            replyHandler?([:])
            let stored = Set(ids)
            store.update { data in
                for epoch in data.pending.keys {
                    data.pending[epoch] = data.pending[epoch]?.filter { !stored.contains($0.value.id) }
                }
                data.unsent.subtract(stored)
            }
            for flightID in Array(recordFlights.keys) {
                guard var flight = recordFlights[flightID] else { continue }
                flight.ids.subtract(stored)
                if flight.ids.isEmpty {
                    recordFlights[flightID] = nil
                } else {
                    recordFlights[flightID] = flight
                }
            }
            debug(
                .watch,
                "Untethered: phone stored \(stored.count) history record(s); \(recordFlights.count)/\(Self.batchesInFlightLimit) batches remain in flight"
            )
            finishSyncIfDone(epoch: envelope.epoch)
            refresh()
            // A confirmation frees a slot in the bounded send window; immediately push the next batch.
            streamRecords()

        case let .syncRequest(bucketStart, checksums):
            replyHandler?([:])
            answerSync(epoch: envelope.epoch, bucketStart: bucketStart, checksums: checksums)

        case let .commit(handover):
            // the deadline by the watch's clock, and how long ago the phone sent it by its own: both clocks normally
            // agree within a second, so a delay well off the delivery time points at the clocks
            if let lease = handover.leaseExpiresAt {
                let now = Date()
                let sent = handover.committedAt.map { String(format: "%.1f s", now.timeIntervalSince($0)) } ?? "unknown"
                Task {
                    await WatchLogger.shared.log(
                        "⌚️ Untethered: commit in, deadline in \(String(format: "%.1f", lease.timeIntervalSince(now))) s " +
                            "by the watch's clock; first sent \(sent) ago by the phone's",
                        force: true
                    )
                }
            }
            apply(.received(envelope.message, epoch: envelope.epoch), reply: replyHandler) {
                if $0.session.phase == .starting, $0.session.epoch == envelope.epoch { $0.handover = handover }
            }

        case let .standingGrant(grant, issuedAt):
            replyHandler?([:])
            // from another build: not for a session this watch app runs, and any older copy goes with it
            if UntetheredVersion.mismatch(phone: envelope.appVersion) != nil {
                dropStandingGrant()
                return
            }
            // A start without the phone that hasn't reached the pod yet takes the phone's newer copy: the phone may
            // have dosed after the copy the start began from (28 October, 05:39:40: the phone's temp basal and SMB,
            // the watch's takeover 34 s later from a copy of 05:13). Its first loop and the booking of what the pod
            // delivered since the copy then count the phone's last doses.
            if data.session.phase == .starting, data.session.startedWithoutPhone,
               issuedAt > (startCopyIssuedAt ?? .distantPast)
            {
                startCopyIssuedAt = issuedAt
                if fallbackGrantCopy != nil { fallbackGrantCopy = (grant, issuedAt) }
                store.update {
                    Self.seed(&$0, with: grant)
                    $0.handover = nil
                }
                Task { await WatchLogger.shared.log("⌚️ Untethered: the start takes the phone's newer copy", force: true) }
                refresh()
                return
            }
            // a late copy from before a session would miss what the session dosed. Kept even before the watch has
            // heard the setting is on (the two travel separately); starting stays gated on the setting.
            guard data.session.phase == .idle else { return }
            store.update {
                $0.standingGrant = grant
                $0.standingGrantIssuedAt = issuedAt
            }
            refresh()
            standingGrantArrived()

        case .revoke:
            // the answer to this stall's hand-back request: the same note, now saying it's done
            let asked = handbackRequestedAt != nil && data.session.phase == .active
            let held = data.session.phase != .idle && envelope.epoch == data.session.epoch
            apply(.received(envelope.message, epoch: envelope.epoch), reply: replyHandler)
            guard held, data.session.phase == .idle else { break }
            Task {
                await WatchLogger.shared.log(
                    "⌚️ Untethered: the iPhone took the pump back (revoke for session \(envelope.epoch)), the watch lets go",
                    force: true
                )
            }
            if asked {
                notify(
                    id: Self.notificationPrefix + "handbackRequest",
                    title: String(localized: "Pump Back on iPhone"),
                    body: String(localized: "The iPhone has the pump again and loops. Start untethered mode again when you want.")
                )
            } else {
                notify(
                    id: Self.notificationPrefix + "phoneTookPod",
                    title: String(localized: "iPhone Took the Pump"),
                    body: String(localized: "The iPhone ended untethered mode and doses again. Check that Trio on the iPhone loops.")
                )
            }

        case let .startRefused(reason):
            replyHandler?([:])
            isBusy = false
            setError(reason)

        case let .adjustmentCancelled(kind, start, date):
            replyHandler?([:])
            // sent both ways, interactive and queued: the second finds it ended already
            guard isActive else { return }
            switch kind {
            case .override:
                if let running = activeOverride(at: Date()), abs(running.date.timeIntervalSince(start)) < 1 {
                    endOverride(at: date)
                }
            case .tempTarget:
                if let running = activeTempTarget(at: Date()), abs(running.createdAt.timeIntervalSince(start)) < 1 {
                    endTempTarget(at: date)
                }
            }

        case let .dosingModeChanged(mode):
            replyHandler?([:])
            guard data.session.phase == .active, envelope.epoch == data.session.epoch else { return }
            setDosingMode(mode, notifyPhone: false)

        case let .remoteTreatment(treatment):
            replyHandler?([:])
            handleRemoteTreatment(treatment, epoch: envelope.epoch)

        case let .remoteAdjustment(adjustment):
            replyHandler?([:])
            handleRemoteAdjustment(adjustment, epoch: envelope.epoch)

        default:
            apply(.received(envelope.message, epoch: envelope.epoch), reply: replyHandler)
        }
    }

    func reachabilityChanged() {
        DispatchQueue.main.async {
            guard WCSession.default.isReachable else { return }
            self.lastPhoneContact = Date()
            self.requestStandingGrantIfMissing()
            self.streamRecords()
            if self.data.session.phase == .ending { self.apply(.tick) }
            // the phone pairs the next pod
            if self.data.podEnded, self.data.session.phase == .active { self.end() }
            self.notePhoneReturn()
            self.checkLinkedOverride()
            self.resendOwnershipAnswerIfUnconfirmed()
        }
    }

    /// The phone holds its dosing until the answer to its ownership question comes, and a queued answer reaches it only
    /// when Trio runs on the phone: a queued transfer doesn't wake it, a message does. On 9 November (second tester)
    /// the question came at 10:40:03, the answer went queued, Trio on the phone went back to sleep, its next reading
    /// didn't come, and it held its dosing until it was opened at 10:48. So the answer goes again as a message at the
    /// watch's next wakes while the phone is in reach, for up to 15 minutes, until the phone replies to one.
    static let ownershipAnswerRetryWindow: TimeInterval = 15 * 60

    private func sendOwnershipAnswer(_ message: UntetheredMessage, epoch: Int) {
        ownershipAnswerUnconfirmedSince = Date()
        send(message, epoch: epoch, onDelivered: { [weak self] in self?.ownershipAnswerUnconfirmedSince = nil })
    }

    /// At a wake of the watch's (a reading, the phone coming in reach): the answer as it stands now, never the one
    /// first given, so a takeover since then is reported as holding.
    func resendOwnershipAnswerIfUnconfirmed() {
        guard let since = ownershipAnswerUnconfirmedSince else { return }
        guard Date().timeIntervalSince(since) < Self.ownershipAnswerRetryWindow else {
            ownershipAnswerUnconfirmedSince = nil
            return
        }
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        let session = data.session
        let holding = session.phase == .active || session.phase == .ending ? session.startStatus : nil
        Task {
            await WatchLogger.shared.log("⌚️ Untethered: the phone hasn't confirmed the ownership answer; sent again", force: true)
        }
        send(
            .statusReport(holding: holding),
            epoch: session.epoch,
            queueing: false,
            onDelivered: { [weak self] in self?.ownershipAnswerUnconfirmedSince = nil }
        )
    }

    /// Why this grant can't run here, or nil.
    private func rejection(of grant: UntetheredGrant) -> String? {
        guard let pump = Self.configuration(grant.pumpConfiguration) else {
            return String(localized: "The pump's configuration could not be read.")
        }
        guard watchPumpManagers[pump.managerIdentifier] != nil else {
            return String(localized: "This pump can't be run by the watch yet.")
        }
        guard let cgm = Self.configuration(grant.cgmConfiguration), watchCGMManagers[cgm.managerIdentifier] != nil else {
            return String(localized: "This CGM can't be read by the watch yet.")
        }
        guard !grant.basalProfile.isEmpty, !grant.insulinSensitivities.sensitivities.isEmpty,
              !grant.carbRatios.schedule.isEmpty, !grant.bgTargets.targets.isEmpty
        else {
            return String(localized: "The therapy settings are incomplete.")
        }
        return nil
    }

    /// The phone's history and settings become the watch's starting point.
    private static func seed(_ data: inout UntetheredWatchData, with grant: UntetheredGrant) {
        data.grant = grant
        data.pumpHistory = grant.pumpHistory
        data.glucose = grant.glucose
        data.smoothedGlucose = grant.smoothedGlucose
        data.carbs = grant.carbs
        data.tempTargets = grant.tempTargets
        data.activeOverride = grant.activeOverride
        data.podTotalCheck = nil
        data.endedOverrides = []
        data.activeOverrideKey = grant.activeOverride.map { UntetheredRecord.overrideKey($0.date) }
        // only a temp target still running has an end to report
        data.activeTempTargetKey = grant.tempTargets.max(by: { $0.createdAt < $1.createdAt })
            .flatMap {
                $0.duration > 0 && $0.createdAt
                    .addingTimeInterval(Double(truncating: $0.duration as NSNumber) * 60) > Date() ? $0 : nil }
            .map { UntetheredRecord.tempTargetKey($0.createdAt) }
        data.autosens = grant.autosens
        data.tddPumpHistory = grant.tddPumpHistory
        data.tddRows = grant.tddRecentRows
        data.tddHours = grant.tddHours ?? []
        // the phone's "50+ U" marker is no amount: above 50 U the pod doesn't measure
        data.reservoir = grant.reservoir.flatMap { $0 == Decimal(UInt32(0xDEAD_BEEF)) ? nil : $0 }
        // the phone's last loop stands until the watch's own first one
        data.lastDetermination = grant.lastDetermination
        data.lastLoopDate = grant.lastLoopDate
        // the reading the phone's last loop dosed on doesn't loop again on the watch
        data.lastLoopGlucose = grant.lastLoopDate.flatMap { loop in grant.glucose.map(\.dateString).filter { $0 <= loop }.max() }
        data.lastLoopError = nil
        data.lastError = nil
        data.pendingPumpAlerts = []
        data.podEnded = false
        // from before this session: its pod state and history miss what the session doses
        data.standingGrant = nil
        data.standingGrantIssuedAt = nil
    }

    // MARK: - State machine

    func apply(
        _ event: UntetheredSession.WatchEvent,
        reply: (([String: Any]) -> Void)? = nil,
        also change: ((inout UntetheredWatchData) -> Void)? = nil
    ) {
        // a saved state still locked (before the first unlock after a restart) may hold a running session: nothing
        // starts or changes over it, and the phone, without an answer, keeps or takes back the pump
        // The step that found it open is left too: the devices of the state taken on are restored a main-queue hop
        // later, and the step would run without them (Claude Fable's review, 15 November). The phone sends again.
        if store.isLocked {
            if store.openIfLocked() {
                adoptSavedState()
                Task { await WatchLogger.shared.log("⌚️ Untethered: saved state open again, taken on; this session step left", force: true) }
            } else {
                Task { await WatchLogger.shared.log("⌚️ Untethered: a session step left for later, the saved state is locked", force: true) }
            }
            reply?([:])
            return
        }
        let wasActive = isActive
        let wasIdle = store.data.session.phase == .idle
        let wasFallbackStart = isFallbackSession && store.data.session.phase == .starting
        let phaseBefore = store.data.session.phase
        let effects = store.update { data -> [UntetheredSession.Effect] in
            let effects = data.session.watch(event, now: Date())
            change?(&data)
            return effects
        }
        let epoch = store.data.session.epoch
        // a start that never got going, as when the phone's commit was lost and it took the pump back (2026-10-20
        // 06:22): nothing is in progress any more, so the spinner goes
        if !wasIdle, store.data.session.phase == .idle { isBusy = false }
        refresh()
        var reply = reply
        for effect in effects {
            switch effect {
            case let .send(message):
                if let replyHandler = reply {
                    self.reply(message, epoch: epoch, via: replyHandler)
                    reply = nil
                } else if case .statusReport = message {
                    // queued by `send` itself, and sent again until the phone is seen to have it
                    sendOwnershipAnswer(message, epoch: epoch)
                } else {
                    send(message, epoch: epoch)
                }
            case .takeover:
                takeover()
            case .releasePump:
                releasePump()
            case .handback:
                handback()
            case let .failed(reason):
                setError(reason)
            case .commit,
                 .reconcile,
                 .takePump:
                break
            }
        }
        reply?([:])
        // the grant's sensor, in case it changed since the phone's last update
        if !wasActive, store.data.session.phase == .active {
            // From now on a pod session another controller made counts as the phone having taken the pod back: the
            // watch's next pod command is refused and the watch lets go (`yieldIfPhoneTookPod`), even when the
            // phone's own message never arrives (28 October, 23:38 to 02:39: the phone took the pod back, its stop
            // didn't reach the sleeping watch, and both dosed it in turn until the watch app was opened).
            pumpManager?.refusesForeignSessionsSince = Date()
            startCGM()
            resumeHandedOverTempBasal()
            recordPumpStatus()
        }
        // before the alarms are booked, so No Sensor Readings counts from the reader's newest reading
        if !wasActive, isActive { seedFallbackReadings() }
        if wasActive != isActive {
            WatchG7Reader.shared.refreshSensorWarning()
            handOverAlertNotifications(toWatch: isActive)
            noteSessionBattery(started: isActive)
        }
        // the phone may have confirmed the last records while the hand-back was still open: nothing else says so
        if wasActive, !isActive {
            finishSyncIfDone(epoch: epoch)
            // the phone has the pump again: the fallback's next look waits 5 minutes from here
            WatchG7Reader.shared.notePhoneTookPump()
        }
        if store.data.session.phase != phaseBefore {
            phaseSince = Date()
            if store.data.session.phase == .idle { podQuietUntil = nil }
        }
        // the fallback says it took over only once it has the pod, and says so when a try found none
        if wasFallbackStart {
            if isActive {
                fallbackTookOver()
            } else if store.data.session.phase == .idle {
                fallbackTryFailed()
            }
        }
        // the session's start dropped the copy, and the phone sends the next only when something changed
        if store.data.session.phase == .idle { requestStandingGrantIfMissing() }
        // after the devices are in place, so the Devices page shows them too
        if isActive { publishToWatchState() }
        updateTimers()
        updateWorkoutKeepAlive()
    }

    private func updateTimers() {
        let phase = data.session.phase
        if phase == .preparing || phase == .starting || phase == .ending {
            if ticker == nil {
                ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.apply(.tick) }
            }
        } else {
            ticker?.invalidate()
            ticker = nil
        }
        if phase == .active {
            if loopTimer == nil {
                // the CGM drives the loop; this covers a missed reading while the app runs
                // no loop of its own: the sensor's acquisition and the alarms, for when no reading comes
                loopTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
                    self?.recheckCGM()
                }
            }
        } else {
            loopTimer?.invalidate()
            loopTimer = nil
        }
        if isActive {
            if displayTimer == nil {
                displayTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                    self?.publishToWatchState()
                }
            }
        } else {
            displayTimer?.invalidate()
            displayTimer = nil
        }
    }

    // MARK: - Transport

    private func reply(_ message: UntetheredMessage, epoch: Int, via replyHandler: ([String: Any]) -> Void) {
        replyHandler((try? UntetheredEnvelope(epoch: epoch, message: message).payload()) ?? [:])
    }

    /// Interactive when the phone is reachable; what must arrive in any case is also queued, unless `queueing`
    /// says otherwise. On the main queue, after the reply is handled, `onReply` runs when the phone answered with an
    /// envelope; `onFailure` runs once when the message reached neither way.
    func send(
        _ message: UntetheredMessage,
        epoch: Int,
        queueing: Bool? = nil,
        onReply: (() -> Void)? = nil,
        onDelivered: (() -> Void)? = nil,
        onFailure: (() -> Void)? = nil
    ) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let payload = try? UntetheredEnvelope(epoch: epoch, message: message).payload()
        else {
            if let onFailure { DispatchQueue.main.async(execute: onFailure) }
            return
        }
        let session = WCSession.default

        // what must reach the phone even if it is away right now; the rest is resent by its own retry
        let queued: Bool
        switch message {
        // the answer to the phone's ownership question too: the phone holds its dosing until it comes (6 November,
        // 07:36: the question woke the watch, the phone was out of reach for that second, the answer was dropped, and
        // the phone held its dosing for 7 minutes with "Checking with the Watch", a loop with it)
        case .records,
             .released,
             .statusReport,
             .syncDone,
             .takeoverComplete,
             .takeoverFailed: queued = queueing ?? true
        default: queued = queueing ?? false
        }
        guard session.isReachable else {
            DispatchQueue.main.async { self.phoneTroubleAt = Date() }
            if queued {
                session.transferUserInfo(payload)
            } else {
                if let onFailure { DispatchQueue.main.async(execute: onFailure) }
            }
            return
        }
        var queuedAfterFailure = false
        var failureReported = false
        for part in UntetheredChunks.split(payload) ?? [payload] {
            session.sendMessage(part, replyHandler: { [weak self] reply in
                DispatchQueue.main.async { self?.phoneTroubleAt = nil }
                if let onDelivered { DispatchQueue.main.async(execute: onDelivered) }
                guard reply[UntetheredEnvelope.key] != nil else { return }
                self?.receive(reply, replyHandler: nil)
                // queued behind the reply's own handling, which `receive` puts on the main queue
                if let onReply { DispatchQueue.main.async(execute: onReply) }
            }, errorHandler: { [weak self] error in
                Task { await WatchLogger.shared.log("⌚️ Untethered: sending failed: \(error.localizedDescription)") }
                // the whole envelope goes queued once, whichever part failed
                DispatchQueue.main.async {
                    self?.phoneTroubleAt = Date()
                    if queued, !queuedAfterFailure {
                        queuedAfterFailure = true
                        session.transferUserInfo(payload)
                    } else if !queued, !failureReported {
                        failureReported = true
                        onFailure?()
                    }
                }
            })
        }
    }

    // MARK: - Taking the pump

    private func takeover() {
        // The fallback's looks just read the pod with a manager made from the same copy: the takeover goes on with it.
        // A second manager beside it never connected (30 October, 14:03 and 14:18), and dropping it first left the
        // start to a fresh one's search (12:18: 6 s, but not every time).
        let witness = fallbackTakeoverPump
        fallbackTakeoverPump = nil
        // a pod meeting still bidding for the pod: never two managers of this watch at once
        if let meeting = meetingPump {
            meetingPump = nil
            if !meeting.isControlReleased { meeting.releaseControl() }
            // 3 November, 18:04:55: a takeover beside a search for the new pod didn't find it in 2 minutes
            Task { await WatchLogger.shared.log("⌚️ Untethered: the takeover let go of the new-pod search's manager and searches with its own", force: true) }
        }
        let pump: PumpManager & ExclusiveDeviceControl
        if let witness, data.session.startedWithoutPhone, data.handover == nil,
           witness.issuedAt != nil, witness.issuedAt == startCopyIssuedAt
        {
            pump = witness.pump
            fallbackTakeoverFromLook = true
            Task { await WatchLogger.shared.log("⌚️ Untethered: the takeover goes on with the look's pod manager", force: true) }
        } else {
            fallbackTakeoverFromLook = false
            if let witness, !witness.pump.isControlReleased { witness.pump.releaseControl() }
            // A look's manager is kept between two looks; a start by hand meanwhile made its own beside it, which never
            // reached the pod (3 November, 11:49 and 11:52: a minute after the 11:48 look, both starts timed out and
            // the phone took the pump back).
            dropFallbackWitness()
            guard let grant = data.grant,
                  let configuration = Self.configuration(data.handover?.pumpConfiguration ?? grant.pumpConfiguration),
                  let type = watchPumpManagers[configuration.managerIdentifier],
                  let made = type.init(adopting: configuration, localState: localState(for: configuration.managerIdentifier))
            else {
                apply(.takeoverFailed(String(localized: "The watch could not set up the pump.")))
                return
            }
            pump = made
        }
        install(pump)
        // the phone's sessions before the hand-over are expected; only one after the watch has the pod counts
        pump.refusesForeignSessionsSince = nil
        takeover(continuing: pump, showsBusy: true)
    }

    /// A bolus ends by the clock: the pump reports no change when it runs out, so the end is checked
    /// for at the time it is due rather than at the pump's next status read minutes later.
    func updateBolusState(_ status: PumpManagerStatus?) {
        bolusEndTimer?.invalidate()
        bolusEndTimer = nil
        isBolusing = (status?.bolusState ?? .noBolus) != .noBolus
        bolusWindow = nil
        guard case let .inProgress(dose) = status?.bolusState else { return }
        bolusWindow = DateInterval(start: dose.startDate, end: max(dose.endDate, dose.startDate))
        bolusEndTimer = Timer.scheduledTimer(withTimeInterval: max(1, dose.endDate.timeIntervalSinceNow + 1), repeats: false) {
            [weak self] _ in
            guard let self else { return }
            self.updateBolusState(self.pumpManager?.status)
            self.refresh()
        }
    }

    /// The meal-time reminder while the watch has the pump: the phone may be away, so the watch rings itself, the
    /// set minutes after the bolus has been delivered (a pod gives about 1.5 U a minute) or from now without one.
    func remindToEat(after minutes: Int, bolus units: Decimal) {
        let delivery = Double(truncating: units as NSNumber) / 1.5 * 60
        let deliveredAt = bolusWindow.map { max($0.end, Date()) } ?? Date().addingTimeInterval(delivery)
        let delay = deliveredAt.timeIntervalSinceNow + Double(minutes * 60)
        pendingMealReminder = units > 0 ? (minutes, deliveredAt) : nil
        mealReminderFireDate = Date().addingTimeInterval(max(1, delay))
        notify(
            id: Self.notificationPrefix + "mealTimeReminder",
            title: String(localized: "Time to Eat", comment: "Meal-time reminder on the watch"),
            body: String(localized: "Your \(minutes) min meal-time reminder is up: time to eat.", comment: "Meal-time reminder on the watch"),
            after: max(1, delay),
            asksForAction: true
        )
        Task {
            await WatchLogger.shared.log(
                "⌚️ Untethered: meal-time reminder in \(Int((delay / 60).rounded())) min (\(minutes) min after the bolus)",
                force: true
            )
        }
    }

    /// The countdown on the first page was tapped: the watch's own reminder and its reminders to open Trio go.
    func cancelMealReminder() {
        let id = Self.notificationPrefix + "mealTimeReminder"
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [id] + ActionNotice.reminderDelays.indices.map { id + ".again\($0 + 1)" }
        )
        let wasPending = mealReminderFireDate.map { $0 > Date() } ?? false
        pendingMealReminder = nil
        mealReminderFireDate = nil
        if wasPending {
            Task { await WatchLogger.shared.log("⌚️ Untethered: meal-time reminder cancelled on the watch", force: true) }
        }
    }

    func install(_ pump: PumpManager & ExclusiveDeviceControl) {
        pump.pumpManagerDelegate = self
        pump.delegateQueue = .main
        pumpManager = pump
        updateBolusState(pump.status)
        savePumpState()
    }

    /// Reads the pump; nil when it doesn't answer.
    func readPump(_ pump: PumpManager) async -> UntetheredPodStatus? {
        if let odometer = pump as? PumpDeliveryOdometer {
            let answered = await odometer.refreshDeliveredUnits()
            guard answered else { return nil }
            return UntetheredPodStatus(
                date: Date(),
                deliveredUnits: odometer.deliveredUnits?.units,
                reservoir: store.data.reservoir.map { NSDecimalNumber(decimal: $0).doubleValue }
            )
        }
        let synced = await withCheckedContinuation { (continuation: CheckedContinuation<Date?, Never>) in
            pump.ensureCurrentPumpData { continuation.resume(returning: $0) }
        }
        return synced.map { UntetheredPodStatus(date: $0, deliveredUnits: nil, reservoir: nil) }
    }

    func releasePump() {
        isFinalizing = false
        // the next session's stall asks the phone afresh
        handbackRequestedAt = nil
        lastPodLinkNotice = nil
        lastPodLinkReset = nil
        podLinkNoticeCount = 0
        // the pump is back: "Watch Took Over" isn't asked again (`ActionNotice`)
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ActionNotice.reminderDelays.indices.map { Self.tookOverID + ".again\($0 + 1)" }
        )
        if let pump = pumpManager {
            pump.releaseControl()
            savePumpState()
        }
        pumpManager = nil
        updateBolusState(nil)
        store.update { $0.pumpRawValue = nil }
        stopCGM()
        refresh()
    }

    // MARK: - The sensor link

    /// The watch reads the sensor in its own display slot only while untethered. Its saved state (key and
    /// Bluetooth handle) outlives the session, so the next takeover reconnects with the same pairing
    /// instead of pairing afresh; a different sensor or code starts over.
    private func startCGM() {
        guard let grant = data.grant, let configuration = Self.configuration(grant.cgmConfiguration) else { return }
        let sameSensor = Self.dictionary(store.data.cgmBuiltFrom)
            .map { NSDictionary(dictionary: $0).isEqual(to: configuration.state) } ?? false
        if sameSensor, let restored = restoredCGM() {
            install(restored)
        } else if let type = watchCGMManagers[configuration.managerIdentifier] {
            // 29 October, second tester: the reader bonded the new sensor at 16:33:46, the session started at 16:34
            // and paired the watch slot again, and from then on the sensor refused the watch's Bluetooth encryption
            // ("Failed to encrypt the connection") until the session ended without a reading.
            // Only ONE manager is built: each opens a Bluetooth central under the kit's restore identifier, which an
            // app may hold only once. Adopting first and then building the reader's manager left the second central
            // dead (1 November, 20:33 to 20:45: not one connection to the sensor, also not with Trio in front).
            let reused = Self.sensorPairedByReader(configuration, type: type)
            guard let cgm: CGMManager = reused
                ?? type.init(adopting: configuration, localState: localState(for: configuration.managerIdentifier))
            else {
                setError(String(localized: "The watch could not set up the CGM."))
                return
            }
            if reused != nil {
                Task {
                    await WatchLogger.shared.log("⌚️ Untethered: new sensor, already paired by the watch's reader: taking its key", force: true)
                }
            } else {
                Task { await WatchLogger.shared.log("⌚️ Untethered: new sensor, pairing the watch afresh", force: true) }
                sensorPairingDue()
            }
            store.update {
                $0.cgmBuiltFrom = Self.plist(configuration.state)
                $0.pendingPumpAlerts.removeAll { $0.managerIdentifier == cgm.pluginIdentifier }
            }
            install(cgm)
        } else {
            setError(String(localized: "The watch could not set up the CGM."))
        }
    }

    /// A manager for the passed sensor with the reader's key and handle, when the reader is paired with this very
    /// sensor and code: the sensor keeps one key per display slot, and a second pairing makes it start a new Bluetooth
    /// bond, which the watch can only complete with Trio in front. Nil when the reader has no key for it; nothing is
    /// built then, so the caller's adopt is the only manager.
    private static func sensorPairedByReader(
        _ configuration: SharedDeviceConfiguration,
        type: (CGMManager & DeviceConfigurationSharing).Type
    ) -> CGMManager? {
        let reader = WatchG7Reader.shared
        guard var state = watchCGMReaderState(configuration),
              reader.hasWatchKey, let slotKey = WatchG7SlotKey.current,
              let sensor = state["sensorID"] as? String, let readerSensor = reader.sensorName,
              sensor.suffix(2) == readerSensor.suffix(2),
              let code = state["pairingCode"] as? String, code == reader.pairingCode
        else { return nil }
        state["sharedKey"] = slotKey
        if let handle = WatchG7SlotKey.peripheral?.uuidString { state["peripheralIdentifier"] = handle }
        return type.init(rawState: state)
    }

    /// The watch stops connecting; its saved state stays for the next session.
    private func stopCGM() {
        sensorPairingDone()
        guard let cgm = cgmManager else { return }
        // in the log next to the reader's takeover, to see which of the two centrals went first
        Task { await WatchLogger.shared.log("⌚️ Untethered: letting go of the sensor", force: true) }
        saveCGMState()
        cgm.cgmManagerDelegate = nil
        // an adopted manager only lets go of the sensor: the phone owns its lifecycle and records. Async since
        // LoopKit#685; without a delegate it only stops the sensor link.
        Task { @MainActor in await cgm.delete() }
        cgmManager = nil
    }

    func install(_ cgm: CGMManager) {
        cgm.cgmManagerDelegate = self
        cgm.delegateQueue = .main
        cgmManager = cgm
        saveCGMState()
        // a CGM set up with Trio in front checks its acquisition at once, as on every wake
        DispatchQueue.main.async {
            if WKApplication.shared().applicationState == .active { watchCGMRecheckAcquisition(cgm) }
        }
    }

    /// The phone's wake after its reading: the sensor is re-checked and the history goes, the phone being in reach.
    func phoneWake(phoneReadingAt phoneReading: Date? = nil) {
        DispatchQueue.main.async {
            guard self.isActive else { return }
            self.recheckCGM()
            self.streamRecords()
            // the phone reads the sensor again: a session the fallback started goes back to it
            if let phoneReading, Date().timeIntervalSince(phoneReading) < 10 * 60, self.isFallbackSession {
                // the hand-back checks the phone's newest reading: the wake's, as its state may not have come yet
                // (9 November: the phone read again after its sensor was paired anew, and the watch kept the pump)
                WatchG7Reader.shared.notePhoneOwnReading(phoneReading)
                Task {
                    await WatchLogger.shared.log(
                        "⌚️ Untethered: fallback — the phone reads the sensor again (\(phoneReading.formatted(date: .omitted, time: .shortened)))",
                        force: true
                    )
                }
                // at once: woken in the background, the app is frozen again long before a minute's grace is up
                self.scheduleFallbackHandback(grace: 0)
            }
        }
    }

    /// Looking at the watch, the loop timer and Bluetooth wakes are the times no reading came: the sensor's
    /// acquisition puts itself right, and the loop and sensor alarms are checked.
    /// Trio leaves the screen (wrist down or another app). watchOS freezes it within seconds, and twice on
    /// 20 October that froze the sensor's next connect before it was made: nothing woke the app for over 30 minutes.
    func appLeavingScreen() {
        guard isActive else { return }
        scheduleSessionRefresh()
    }

    /// A background refresh as the backstop wake: if a connect is still missing, it is put in on that wake.
    /// One refresh is pending per app at a time; this one replaces the watch reader's while a session runs.
    /// Each reading and each leaving of the screen puts it off again, so it only comes when a reading is missing.
    /// 7 minutes: just past the point where the sensor's acquisition counts a standing request as lost (one window
    /// of 5 minutes and 90 s, `G7WatchAcquisition.recheck`), so that wake renews it. At 10 minutes a request lost at
    /// the start of a session with the Workout app in front stood until Trio was opened (9 November, 05:04 to
    /// 05:11:54: 452 s without a link, "No Sensor Readings" after 11 minutes).
    func scheduleSessionRefresh() {
        guard isActive else { return }
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(Self.sessionRefreshDelay),
            userInfo: nil
        ) { _ in }
    }

    static let sessionRefreshDelay: TimeInterval = 7 * 60

    func recheckCGM() {
        watchCGMRecheckAcquisition(cgmManager)
        takePendingPhoneReading()
        checkAlarms()
        checkPodLink()
    }

    /// After a relaunch the session continues with the devices as they were saved.
    private func restoreDevices() {
        switch data.session.phase {
        case .active,
             .ending,
             .starting:
            if let pump = restoredPump() {
                install(pump)
                if data.session.phase == .starting { takeover(continuing: pump) }
            }
            if data.session.phase != .starting, let cgm = restoredCGM() { install(cgm) }
        case .idle,
             .preparing:
            break
        }
    }

    /// Reads the pod until the session's start succeeds; a later tick past the lease releases the pump.
    private func takeover(continuing pump: PumpManager & ExclusiveDeviceControl, showsBusy: Bool = false) {
        pump.takeControl()
        let epoch = data.session.epoch
        if showsBusy { isBusy = true }
        Task { @MainActor in
            defer { if showsBusy { self.isBusy = false } }
            while self.data.session.phase == .starting, self.data.session.epoch == epoch {
                if let status = await self.readPump(pump) {
                    // a read that outlasted its try (the lease ran out, a newer try began) doesn't start the next one
                    guard self.data.session.phase == .starting, self.data.session.epoch == epoch else { return }
                    if self.phoneUsedPodSinceDecision(pump) { return }
                    // the phone's last loop stays on screen; the next CGM reading starts the watch's own
                    self.apply(.takeoverSucceeded(self.startStatus(status, pump: pump)))
                    return
                }
                try? await Task.sleep(nanoseconds: Self.takeoverReadInterval)
            }
        }
    }

    /// The temp basal the phone cancelled at its release goes on as the watch's own. A loop already running
    /// decides for itself.
    private func resumeHandedOverTempBasal() {
        guard let pump = pumpManager, let tempBasal = data.handover?.tempBasal, !isLooping else { return }
        Task { @MainActor in
            if let error = await pump.resumeTempBasal(tempBasal) {
                await WatchLogger.shared.log("⌚️ Untethered: the phone's temp basal could not be set again: \(error)", force: true)
            } else {
                // the phone shows its own cancel until this record arrives, not waiting for the first loop
                self.streamRecords()
            }
        }
    }

    // MARK: - Starting without the phone

    /// Settings › Allow Start Without iPhone turned off: the copy the phone left goes with it.
    func dropStandingGrant() {
        guard data.standingGrant != nil || data.standingGrantIssuedAt != nil else { return }
        store.update {
            $0.standingGrant = nil
            $0.standingGrantIssuedAt = nil
        }
        refresh()
    }

    /// The standing grant's age, while one is stored and young enough to start from: older than insulin's action time
    /// its history has too large a gap, and what the pod delivered meanwhile too much to book as one dose.
    var standingGrantAge: TimeInterval? {
        guard let grant = data.standingGrant, let issuedAt = data.standingGrantIssuedAt, rejection(of: grant) == nil
        else { return nil }
        let age = Date().timeIntervalSince(issuedAt)
        let actionTime = NSDecimalNumber(decimal: grant.pumpSettings.insulinActionCurve).doubleValue * 60 * 60
        return age < actionTime ? age : nil
    }

    /// No standing grant young enough to start from, as after a session, whose start dropped it: asked for, as the
    /// phone otherwise sends the next only when something changed or half an hour passed.
    /// `force`: one young enough for a start by hand is stored, but too old for the fallback (`fallbackCopyMaxAge`).
    /// True when a request went out.
    @discardableResult func requestStandingGrantIfMissing(force: Bool = false) -> Bool {
        let now = Date()
        guard data.session.phase == .idle, force || standingGrantAge == nil, WatchState.shared.untetheredMode,
              WatchState.shared.allowUntetheredStartWithoutPhone,
              (standingGrantRequestedAt ?? .distantPast).addingTimeInterval(Self.standingGrantRequestInterval) < now
        else { return false }
        standingGrantRequestedAt = now
        // queued, so a phone out of reach or asleep answers once it can; only the newest request waits. The list is
        // read off the main thread (`WCTransfers`), and the request sent once the older ones are cancelled.
        let epoch = data.session.epoch
        WCTransfers.run {
            for transfer in WCSession.default.outstandingUserInfoTransfers
                where (try? UntetheredEnvelope.decode(transfer.userInfo))?.message == .standingGrantRequest
            {
                transfer.cancel()
            }
            DispatchQueue.main.async {
                self.send(.standingGrantRequest, epoch: epoch, queueing: true)
            }
        }
        return true
    }

    /// Why there is no start without the phone, for the status page; nil when one can start.
    var startWithoutPhoneUnavailable: String? {
        if let reason = versionMismatch { return reason }
        guard let grant = data.standingGrant, let issuedAt = data.standingGrantIssuedAt else {
            return String(localized: "No copy from the phone to start from yet. It sends one while it has the pump.")
        }
        if let rejection = rejection(of: grant) { return rejection }
        guard standingGrantAge == nil else { return nil }
        let hours = Int(Date().timeIntervalSince(issuedAt) / 3600)
        return String(
            localized: "The phone's copy is \(hours) h old, older than the insulin's action time: too much is unknown to start from it."
        )
    }

    /// With the phone off or out of reach, from the phone's standing grant: the ordinary takeover, with a fresh lease
    /// and an epoch of the watch's own. The phone stands aside once it hears from the watch. As LoopKit/Loop#2545.
    /// `phoneReachableIsNoPhone`: the fallback's start, decided by the pod (nobody used it for minutes) and the phone's
    /// silent readings; a phone that flickers into reach without looping doesn't hold it up (30 October, 12:03:53: the
    /// phone in a pot showed up for 5 s at the very second of the start, which then didn't begin).
    func startWithoutPhone(phoneReachableIsNoPhone: Bool = false) {
        guard WatchState.shared.untetheredMode, WatchState.shared.allowUntetheredStartWithoutPhone,
              data.session.phase == .idle, !isBusy, phoneReachableIsNoPhone || !WCSession.default.isReachable,
              standingGrantAge != nil,
              let grant = data.standingGrant
        else { return }
        setError(nil)
        Task { await WatchLogger.shared.log("⌚️ Untethered: starting without the phone", force: true) }
        startCopyIssuedAt = data.standingGrantIssuedAt
        apply(.startWithoutPhone) {
            guard $0.session.phase == .starting else { return }
            Self.seed(&$0, with: grant)
            // the standing grant's pump, not an earlier session's hand-over
            $0.handover = nil
            $0.phoneReturnNoted = false
        }
    }

    /// The takeover's reading; started without the phone, before the first loop, with what the phone dosed after its
    /// copy booked and the copy's time for the phone.
    private func startStatus(_ status: UntetheredPodStatus, pump: PumpManager) -> UntetheredPodStatus {
        guard data.session.startedWithoutPhone, let grant = data.grant,
              let copy = Self.configuration(grant.pumpConfiguration)
        else { return status }
        bookUnexplainedSinceCopy(status, copy: copy, pump: pump as? PumpDeliveryOdometer)
        var status = status
        status.copyAsOf = copy.asOf
        return status
    }

    /// What the pod delivered since the standing grant's copy that its history can't explain, and the rest of a bolus
    /// the phone started after it (the pump manager doesn't track another controller's bolus), booked as a bolus in
    /// the watch's own history only: the phone has the real records of it.
    private func bookUnexplainedSinceCopy(
        _ status: UntetheredPodStatus,
        copy: SharedDeviceConfiguration,
        pump: PumpDeliveryOdometer?
    ) {
        guard let grant = data.grant else { return }
        let untrackedBolus = pump?.untrackedBolusRemaining ?? 0
        let unexplained = UntetheredAudit.unexplainedSinceCopy(
            copyUnits: copy.deliveredUnits,
            copyAt: copy.asOf,
            podUnits: status.deliveredUnits,
            podAt: status.date,
            history: grant.tddPumpHistory,
            basalProfile: grant.basalProfile,
            bolusDeliveryRate: pump?.bolusDeliveryRate ?? 0
        ) ?? 0
        let units = unexplained + Decimal(untrackedBolus).rounded(scale: 2)
        guard units > UntetheredAudit.tolerance else { return }
        let epoch = data.session.epoch
        let bolus = PumpHistoryEvent(
            id: "untethered-copy-gap-\(epoch)",
            type: .bolus,
            timestamp: status.date,
            amount: units,
            duration: 0,
            isSMB: false,
            isExternal: false
        )
        // the TDD counts it too, as it does every bolus
        store.update { $0.upsertPumpEvent(id: bolus.id, history: [bolus], tdd: bolus) }
        Task {
            await WatchLogger.shared
                .log(
                    "⌚️ Untethered: \(units) U the standing grant had no record of (\(untrackedBolus) U still running), a bolus",
                    force: true
                )
        }
    }

    /// The phone back during a session started without it: told at once that the watch has the pump, so it stops
    /// dosing; the wrist is asked once whether to hand back. Never handed back on its own.
    private func notePhoneReturn() {
        guard isActive, data.session.startedWithoutPhone, WCSession.default.isReachable else { return }
        send(.statusReport(holding: data.session.startStatus), epoch: data.session.epoch)
        // a session the fallback started goes back by itself
        if isFallbackSession {
            scheduleFallbackHandback()
            return
        }
        guard !data.phoneReturnNoted else { return }
        store.update { $0.phoneReturnNoted = true }
        notify(
            id: "untethered.phoneBack",
            title: String(localized: "iPhone Is Back"),
            body: String(localized: "The watch still has the pump. Hand back on its status page when you're ready.")
        )
    }

    // MARK: - Starting from the wrist

    /// Asks the phone to start, as its settings toggle does; the phone's answer is the usual prepare.
    /// The phone's build differs from this watch app's: nothing starts until watchOS has updated it (or the phone).
    var versionMismatch: String? {
        UntetheredVersion.mismatch(phone: WatchState.shared.phoneAppVersion ?? UntetheredVersion.current)
    }

    private static let updateWaitingNoticeKey = "untethered.updateWaitingFor"

    /// The phone runs a newer build than this watch app: watchOS installs the new watch app only once Trio here is
    /// closed, which it never is by itself while it reads the sensor. Said once per phone build, and not while the
    /// watch has the pump (closing Trio then would stop its loop).
    func notePhoneVersion() {
        guard let phone = WatchState.shared.phoneAppVersion,
              UntetheredVersion.phoneIsNewer(phone: phone, watch: UntetheredVersion.current),
              data.session.phase == .idle,
              UserDefaults.standard.string(forKey: Self.updateWaitingNoticeKey) != phone
        else { return }
        UserDefaults.standard.set(phone, forKey: Self.updateWaitingNoticeKey)
        let watch = UntetheredVersion.current ?? "?"
        Task { await WatchLogger.shared.log("⌚️ Untethered: the iPhone runs \(phone), this watch app \(watch): update waiting", force: true) }
        notify(
            id: Self.notificationPrefix + "updateWaiting",
            title: String(localized: "Update Waiting"),
            body: String(localized: "Trio on the iPhone has a newer build. The watch installs it only after Trio here is closed.")
                + " " + UntetheredVersion.closeOnWatch,
            asksForAction: true
        )
    }

    func requestStart() {
        guard WatchState.shared.untetheredMode, data.session.phase == .idle, !isBusy else { return }
        // a start by hand shows in the log: on 3 November at 18:04:55 one went out 6 s after Trio opened from the
        // new-pod notice, and nothing showed whether it was tapped
        Task { await WatchLogger.shared.log("⌚️ Untethered: Start Untethered tapped on the watch", force: true) }
        if let reason = versionMismatch {
            setError(reason)
            return
        }
        guard WCSession.default.isReachable else {
            setError(String(localized: "The phone must be reachable to start untethered mode."))
            return
        }
        setError(nil)
        isBusy = true
        sendStartRequest(attempt: 1)
        // the phone's prepare, or its refusal, comes once it has read the pump (up to 30 s); this only frees the button
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if self.data.session.phase == .idle { self.isBusy = false }
        }
    }

    /// Asked again when WatchConnectivity didn't get it through (25 October: four starts by hand); the phone ignores a
    /// request for a start already under way. Meanwhile the page says "iPhone Busy".
    private func sendStartRequest(attempt: Int) {
        send(.startRequest, epoch: data.session.epoch, onFailure: { [weak self] in
            guard let self, self.isBusy, self.data.session.phase == .idle else { return }
            guard attempt < Self.startRequestTries else {
                self.isBusy = false
                self.setError(String(localized: "The iPhone didn't get the start. Open Trio on the iPhone and try again."))
                return
            }
            Task {
                await WatchLogger.shared.log(
                    "⌚️ Untethered: start request \(attempt) of \(Self.startRequestTries) didn't reach the iPhone, again in 5 s",
                    force: true
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard self.isBusy, self.data.session.phase == .idle else { return }
                self.sendStartRequest(attempt: attempt + 1)
            }
        })
    }

    private static let startRequestTries = 4

    // MARK: - Handing back

    /// From the wrist, or because the linked override is over. Needs the phone close by.
    func end() {
        if isBolusing {
            Task {
                await WatchLogger.shared.log("⌚️ Untethered: End tapped during a bolus — handing back, the bolus goes on on the pod", force: true)
            }
        }
        guard WCSession.default.isReachable else {
            setError(
                String(
                    localized: "The phone must be reachable to take the pump back. Use Emergency Stop if it isn't coming back."
                )
            )
            return
        }
        apply(.end)
    }

    /// Two-phase, as LoopKit/Loop#2545: the watch doses on while its history drains, so the phone has all of it
    /// before the pod changes hands; then it stops dosing, reads the pod, sends its last records and offers the
    /// pump, which it lets go only once the phone acknowledges (`UntetheredSession`).
    private func handback() {
        isBusy = true
        let epoch = data.session.epoch
        Task { @MainActor in
            defer { self.isBusy = false }
            // a phone that doesn't confirm the backlog in time gets the rest with the last records
            let drainUntil = Date().addingTimeInterval(Self.drainLimit)
            while self.hasUnconfirmedRecords(epoch), Date() < drainUntil, self.data.session.phase == .ending {
                self.streamRecords()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard self.data.session.phase == .ending else { return }
            // from here no loop or bolus: the last read is the last command to the pod
            self.isFinalizing = true
            // A running bolus doesn't hold the hand-back up: the pod delivers it whoever has the pod, the last
            // records report it as running, and the phone keeps it as reported (`freezeWatchDoses`), as after a
            // take-back during a bolus (9 November, 13:38: 66 s into 2 U, audit 1.7 U / 1.71 U). Waiting for it made
            // End seem to do nothing for over a minute. A loop is waited for, only so long.
            let loopWaitUntil = Date().addingTimeInterval(Self.handbackPodLimit)
            if self.isBolusing {
                Task {
                    await WatchLogger.shared.log("⌚️ Untethered: hand-back during a bolus — it goes on on the pod", force: true)
                }
            }
            while self.isLooping, Date() < loopWaitUntil {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if self.isLooping {
                Task { await WatchLogger.shared.log("⌚️ Untethered: hand-back goes on past a loop waiting on the pump", force: true) }
            }
            self.expireAdjustments(now: Date())
            // a low temp ends here and goes with the last records, for the phone to set again; a high one runs on
            // until the phone, having the pod, cancels it
            let scheduled = BolusCalculator.scheduleValue(
                (self.data.grant?.basalProfile ?? []).map { ($0.start, $0.rate) },
                at: Date()
            )
            let handed = await Self.withTimeout(Self.handbackPodLimit) {
                await self.pumpManager.asyncMap {
                    await $0.handOverTempBasal(scheduledRate: scheduled, cancellingHigh: false)
                }
            }
            var status = await Self.withTimeout(Self.handbackPodLimit) {
                (await self.pumpManager.asyncMap { await self.readPump($0) }) ?? nil
            }
            if status == nil {
                Task { await WatchLogger.shared.log("⌚️ Untethered: hand-back without a last pod read; the phone reads it", force: true) }
            }
            status?.tempBasal = handed?.resume
            status?.runningHighTemp = handed?.leftRunning
            self.recordPumpStatus()
            // only these few records are left: no pacing around the sensor for them
            self.streamRecords(ignoringSensor: true)
            let confirmUntil = Date().addingTimeInterval(Self.finalConfirmLimit)
            while self.hasUnconfirmedRecords(epoch), Date() < confirmUntil {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            // the pod stays held until the phone acknowledges: its connect is standing as the watch lets go
            self.apply(.handbackReady(status))
        }
    }

    /// The value of `operation`, or nil once `seconds` have passed without one. The operation isn't stopped, only
    /// no longer waited for.
    @MainActor static func withTimeout<T>(
        _ seconds: TimeInterval,
        _ operation: @escaping @MainActor () async -> T?
    ) async -> T? {
        // both sides run on the main queue, so the flag needs no lock; a box, as a captured var can't change in a Task
        let once = TimeoutOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task { @MainActor in
                let value = await operation()
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: value)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: nil)
            }
        }
    }

    /// How recently the phone must have been heard from for the watch to ask it to take the pump back.
    static let phoneContactWindow: TimeInterval = 30 * 60
    /// A stall that outlasts this asks again, in case the first request never arrived.
    static let handbackRequestRepeat: TimeInterval = 30 * 60

    /// The watch can't reach the pod while readings come in: it asks the phone to take the pump back, as Take Back
    /// the Pump Now, rather than nobody looping. The phone reached the pod within seconds every time the watch's
    /// background links failed (2026-10-20, stalls of 41, 80 and 26 minutes; 2026-10-21 from 00:45 to 05:56).
    /// watchOS reports the phone unreachable to an app in the background almost always, so the request goes queued
    /// as well, which wakes the phone app; it is only sent with the phone heard from in the last 30 minutes. The watch
    /// keeps the pump and keeps trying until the phone's revoke arrives, so a phone that is away changes nothing.
    enum HandbackReason { case podStall, noReadings }

    func requestHandback(minutes: Int, reason: HandbackReason, now: Date = Date()) {
        let phoneNearby = WCSession.default.isReachable
            || lastPhoneContact.map { now.timeIntervalSince($0) < Self.phoneContactWindow } ?? false
        guard data.session.phase == .active, !isBolusing, phoneNearby,
              now.timeIntervalSince(handbackRequestedAt ?? .distantPast) > Self.handbackRequestRepeat
        else { return }
        handbackRequestedAt = now
        Task {
            await WatchLogger.shared.log(
                "⌚️ Untethered: no loop for \(minutes) min (\(reason == .podStall ? "pod not reached" : "no sensor readings")), asking the phone to take the pump back",
                force: true
            )
        }
        notify(
            id: Self.notificationPrefix + "handbackRequest",
            title: String(localized: "Handing Back to iPhone"),
            body: reason == .podStall
                ? String(
                    localized: "The watch hasn't reached the pod for \(minutes) minutes. The iPhone takes the pump back as soon as it gets the request; keep it nearby. Bolus on the iPhone; the watch takes boluses again in 5 minutes if the iPhone hasn't taken the pump."
                )
                : String(
                    localized: "The watch has had no sensor reading and no loop for \(minutes) minutes. The iPhone takes the pump back as soon as it gets the request; keep it nearby. Bolus on the iPhone; the watch takes boluses again in 5 minutes if the iPhone hasn't taken the pump."
                )
        )
        send(.handbackRequested(minutesWithoutLoop: minutes), epoch: data.session.epoch, queueing: true)
        holdOffPodForTakeBack(for: Self.podQuietForHandbackRequest)
        // A reconnect armed before the request keeps its search for the pod going until a loop gets through, and
        // with it the pod's one connection the phone needs (Claude Fable's review, 14 November): it ends here.
        if lastPodLinkReset != nil {
            lastPodLinkReset = nil
            pumpManager?.endTakeEscalation()
        }
        // If the phone doesn't take the pod in the quiet time (the request is late, or the pod refused it), the
        // watch is again the only one trying: it reconnects then, rather than at the next notice 5 minutes later.
        if reason == .podStall {
            let epoch = data.session.epoch
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.podQuietForHandbackRequest + 1) { [weak self] in
                guard let self, self.data.session.phase == .active, self.data.session.epoch == epoch else { return }
                self.reconnectPodIfStalled()
            }
        }
    }

    /// The phone has used the pod since the watch took it (the pod resynchronized to another controller's newer
    /// session): the phone took it back, whether or not its message arrived. The watch lets go at once and tells the
    /// phone, so only one of them doses. Returns whether it let go.
    @discardableResult func yieldIfPhoneTookPod() -> Bool {
        guard isActive, let pump = pumpManager, let since = pump.refusesForeignSessionsSince,
              let foreign = pump.lastForeignSessionAt, foreign > since
        else { return false }
        Task {
            await WatchLogger.shared.log(
                "⌚️ Untethered: the iPhone has used the pod since the watch took it, the watch lets go of the pump",
                force: true
            )
        }
        notify(
            id: Self.notificationPrefix + "phoneTookPod",
            title: String(localized: "iPhone Has the Pump"),
            body: String(localized: "The iPhone has used the pod, so the watch stopped untethered mode. The iPhone loops again.")
        )
        apply(.emergencyStop(nil))
        return true
    }

    /// The phone reaches for the pod for a few seconds after it gets the request; a loop of the watch's that takes
    /// the pod's link then makes it give up (24 October 13:55: the phone found no link in 5 s, the watch had just
    /// looped at 13:55:52). A minute without the watch's pod commands. Ended early when the session ends (the phone has
    /// the pump).
    func holdOffPodForTakeBack(for duration: TimeInterval = UntetheredWatchManager.podQuietForTakeBack) {
        podQuietUntil = Date().addingTimeInterval(duration)
        let span = duration > Self.podQuietForTakeBack ? "up to \(Int(duration / 60)) minutes" : "a minute"
        Task { await WatchLogger.shared.log("⌚️ Untethered: leaving the pod to the iPhone for \(span)", force: true) }
    }

    static let podQuietForTakeBack: TimeInterval = 60
    /// After the watch asked to hand back because it can't loop (pod not reached, or no readings): it isn't dosing
    /// anyway, so it leaves the pod alone until the phone has it, up to this long. A minute wasn't enough: on
    /// 13 November (third tester) the request reached the phone 4 min 45 s late, the watch was back at the pod by
    /// then, and the phone found it busy; the pump was back on the phone 25 minutes after the request.
    static let podQuietForHandbackRequest: TimeInterval = 5 * 60

    private func hasUnconfirmedRecords(_ epoch: Int) -> Bool {
        !(store.data.pending[epoch] ?? [:]).isEmpty
    }

    /// Lets go of the pump at once, with the phone or without it. A running temp basal is cancelled
    /// first, so the pump falls back to its schedule.
    func emergencyStop() {
        isBusy = true
        Task { @MainActor in
            defer { self.isBusy = false }
            var status: UntetheredPodStatus?
            if let pump = self.pumpManager {
                _ = try? await pump.enactTempBasal(unitsPerHour: 0, for: 0)
                status = await self.readPump(pump)
            }
            self.streamRecords(ignoringSensor: true)
            self.apply(.emergencyStop(status))
        }
    }

    // MARK: - History to the phone

    /// Hands record batches to WatchConnectivity and keeps each record locally until the phone confirms storage.
    /// A bounded window avoids serial round trips and prevents a large history from flooding the durable transfer
    /// queue. Hand-back can pipeline four batches; during normal sensor use only one goes at a time, in a clear
    /// window, to protect the sensor link. The phone's confirmation opens the next slot(s).
    func streamRecords(ignoringSensor: Bool = false) {
        streamTimer?.invalidate()
        streamTimer = nil
        // before activation nothing can go, not even queued: what left `unsent` now would never be sent
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let session = WCSession.default
        let now = Date()
        let pendingIDs = Set(store.data.pending.values.flatMap { $0.values.map(\.id) })
        for flightID in Array(recordFlights.keys) {
            guard var flight = recordFlights[flightID] else { continue }
            flight.ids.formIntersection(pendingIDs)
            if flight.ids.isEmpty {
                recordFlights[flightID] = nil
            } else {
                recordFlights[flightID] = flight
            }
        }

        // If a live interactive send stopped answering, retry its records. When the phone is away, leave durable
        // transfers alone; WatchConnectivity will deliver them on reconnection, and reachability will resume here.
        if session.isReachable {
            let expiredFlightIDs = recordFlights.compactMap { entry in
                now.timeIntervalSince(entry.value.sentAt) >= Self.recordAckTimeout ? entry.key : nil
            }
            if !expiredFlightIDs.isEmpty {
                let expiredIDs = Set(expiredFlightIDs.flatMap { recordFlights[$0]?.ids ?? [] })
                debug(.watch, "Untethered: no storage confirmation for \(expiredIDs.count) history record(s) in 30 s; retrying")
                for id in expiredFlightIDs { recordFlights[id] = nil }
                resend(Array(expiredIDs))
            }
        }

        let paced = holdsSensorLink && !ignoringSensor && !isFinalizing
        let unsent = store.data.unsent
        guard !unsent.isEmpty else {
            scheduleRecordAckTimeoutIfNeeded()
            return
        }
        let pending = store.data.pending.sorted { $0.key < $1.key }
        var batches: [(epoch: Int, records: [UntetheredRecord])] = []
        for (epoch, records) in pending {
            let batch = records.values.filter { unsent.contains($0.id) }.sorted { $0.date < $1.date }
            for start in stride(from: 0, to: batch.count, by: Self.recordsPerMessage) {
                batches.append((epoch, Array(batch[start ..< min(start + Self.recordsPerMessage, batch.count)])))
            }
        }
        guard !batches.isEmpty else { return }

        if paced {
            // The next phone reachability change or sensor reading retries; never queue history over the sensor link.
            guard session.isReachable else { return }
            if let clear = sensorWindowEnd(now: Date()) {
                scheduleStream(at: clear)
                return
            }
        }

        let batchLimit = paced ? 1 : Self.batchesInFlightLimit
        let availableSlots = max(0, batchLimit - recordFlights.count)
        guard availableSlots > 0 else {
            scheduleRecordAckTimeoutIfNeeded()
            return
        }
        let sending = Array(batches.prefix(availableSlots))
        for batch in sending {
            let ids = batch.records.map(\.id)
            let flightID = UUID()
            recordFlights[flightID] = (Set(ids), now)
            debug(
                .watch,
                "Untethered: sending \(ids.count) history record(s); \(recordFlights.count)/\(Self.batchesInFlightLimit) batches in flight"
            )
            send(
                .records(batch.records),
                epoch: batch.epoch,
                queueing: paced ? false : nil,
                onFailure: { [weak self] in self?.recordBatchFailed(flightID: flightID, ids: ids) }
            )
        }
        // what is no longer pending was confirmed meanwhile and needs no sending
        let currentPendingIDs = Set(pending.flatMap { $0.value.values.map(\.id) })
        let sent = Set(sending.flatMap { $0.records.map(\.id) })
        store.update { $0.unsent = $0.unsent.subtracting(sent).intersection(currentPendingIDs) }
        scheduleRecordAckTimeoutIfNeeded()
    }

    private func recordBatchFailed(flightID: UUID, ids: [UUID]) {
        recordFlights[flightID] = nil
        resend(ids)
        scheduleStream(at: Date().addingTimeInterval(Self.retryDelay))
    }

    /// Retry an unanswered interactive batch, or wake it when its slot is due.
    private func scheduleRecordAckTimeoutIfNeeded() {
        guard WCSession.default.isReachable,
              let oldest = recordFlights.values.map(\.sentAt).min()
        else { return }
        scheduleStream(at: oldest.addingTimeInterval(Self.recordAckTimeout))
    }

    /// The end of the window around the watch's next sensor reading, or nil while clear of it or holding no sensor.
    /// A link still up after its reading (backfill) holds it too, checked again shortly.
    func sensorWindowEnd(now: Date) -> Date? {
        guard holdsSensorLink else { return nil }
        if watchCGMIsConnected(cgmManager) { return now.addingTimeInterval(5) }
        return UntetheredSensorWindow.end(now: now, lastReading: store.data.glucose.map(\.dateString).max())
    }

    /// The watch reads the sensor itself, in an untethered session.
    var holdsSensorLink: Bool { cgmManager != nil }

    /// Bulk traffic to the phone, the watch's log included, may go now: always without a sensor link, with one
    /// only to a reachable phone and clear of the next reading.
    var mayStreamToPhone: Bool {
        guard holdsSensorLink else { return true }
        return WCSession.default.isReachable && sensorWindowEnd(now: Date()) == nil
    }

    /// Runs only while the app does; a suspended app picks up at its next loop.
    private func scheduleStream(at date: Date) {
        streamTimer?.invalidate()
        streamTimer = Timer.scheduledTimer(withTimeInterval: max(1, date.timeIntervalSinceNow), repeats: false) {
            [weak self] _ in self?.streamRecords()
        }
    }

    /// Every version the phone hasn't confirmed goes again: after a relaunch, whose process lost the replies and
    /// failures it waited for, and after a queued transfer failed. The phone stores each version once.
    func requeueUnconfirmed(stream: Bool = true) {
        recordFlights.removeAll()
        store.update { $0.unsent = Set($0.pending.values.flatMap { $0.values.map(\.id) }) }
        if stream { streamRecords() }
    }

    /// A batch that reached the phone neither way goes again with the next one, unless confirmed meanwhile.
    private func resend(_ ids: [UUID]) {
        let retrying = Set(ids)
        for flightID in Array(recordFlights.keys) {
            guard var flight = recordFlights[flightID] else { continue }
            flight.ids.subtract(retrying)
            if flight.ids.isEmpty {
                recordFlights[flightID] = nil
            } else {
                recordFlights[flightID] = flight
            }
        }
        let pendingIDs = Set(store.data.pending.values.flatMap { $0.values.map(\.id) })
        store.update { $0.unsent.formUnion(retrying.intersection(pendingIDs)) }
    }

    /// The phone's checksums against ours: what it misses is resent; a finished session whose every
    /// version the phone confirmed is done.
    private func answerSync(epoch: Int, bucketStart: Int, checksums: [Int]) {
        let entries = Array((store.data.entries[epoch] ?? [:]).values)
        let differing = UntetheredSyncEntry.differingBuckets(local: entries, remoteStart: bucketStart, remoteChecksums: checksums)
        let missing = (store.data.pending[epoch] ?? [:]).values.filter { differing.contains($0.syncEntry.bucket) }
        if !missing.isEmpty {
            resend(missing.map(\.id))
            streamRecords()
        }
        finishSyncIfDone(epoch: epoch)
    }

    private func finishSyncIfDone(epoch: Int) {
        let session = store.data.session
        let over = epoch != session.epoch || session.phase == .idle
        guard over, store.data.entries[epoch] != nil, (store.data.pending[epoch] ?? [:]).isEmpty else { return }
        send(.syncDone, epoch: epoch)
        store.update {
            $0.pending[epoch] = nil
            $0.entries[epoch] = nil
        }
        refresh()
    }

    // MARK: - Persistence of the devices

    static func configuration(_ data: Data) -> SharedDeviceConfiguration? {
        (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
            .flatMap(SharedDeviceConfiguration.init(rawValue:))
    }

    private static func plist(_ value: [String: Any]?) -> Data? {
        value.flatMap { try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
    }

    private static func dictionary(_ data: Data?) -> [String: Any]? {
        data.flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any] }
    }

    private func localState(for identifier: String) -> [String: Any]? {
        Self.dictionary(store.data.localStates[identifier])
    }

    func savePumpState() {
        guard let pump = pumpManager else { return }
        store.update {
            $0.pumpRawValue = Self.plist(["managerIdentifier": pump.pluginIdentifier, "state": pump.rawState])
            if let local = Self.plist(pump.localState) { $0.localStates[pump.pluginIdentifier] = local }
        }
    }

    func saveCGMState() {
        guard let cgm = cgmManager else { return }
        // the key it authenticated with is the slot's newest; the reader takes it over at the hand-back
        let state = cgm.rawState
        if let key = state["sharedKey"] as? Data {
            WatchG7SlotKey.record(key, peripheral: (state["peripheralIdentifier"] as? String).flatMap(UUID.init(uuidString:)))
        }
        store.update {
            $0.cgmRawValue = Self.plist(["managerIdentifier": cgm.pluginIdentifier, "state": cgm.rawState])
            if let sharing = cgm as? DeviceConfigurationSharing, let local = Self.plist(sharing.localState) {
                $0.localStates[cgm.pluginIdentifier] = local
            }
        }
    }

    private func restoredPump() -> (PumpManager & ExclusiveDeviceControl)? {
        guard let raw = Self.dictionary(store.data.pumpRawValue), let identifier = raw["managerIdentifier"] as? String,
              let state = raw["state"] as? [String: Any]
        else { return nil }
        return watchPumpManagers[identifier]?.init(rawState: state)
    }

    private func restoredCGM() -> CGMManager? {
        guard let raw = Self.dictionary(store.data.cgmRawValue), let identifier = raw["managerIdentifier"] as? String,
              var state = raw["state"] as? [String: Any]
        else { return nil }
        // the reader may have paired the watch slot again since the last session, which made the saved key
        // worthless (test 17.10.: auth failed at 19:45, first reading 19:55); start with the slot's newest key
        if let slotKey = WatchG7SlotKey.current, state["sharedKey"] != nil || state["pairingCode"] != nil,
           (state["sharedKey"] as? Data) != slotKey
        {
            state["sharedKey"] = slotKey
            Task { await WatchLogger.shared.log("⌚️ Untethered: taking the reader's newer sensor key", force: true) }
        }
        // and connect to the sensor by the handle last used, which the system keeps while the app sleeps
        if state["pairingCode"] != nil, let handle = WatchG7SlotKey.peripheral?.uuidString,
           state["peripheralIdentifier"] as? String != handle
        {
            state["peripheralIdentifier"] = handle
        }
        return watchCGMManagers[identifier]?.init(rawState: state)
    }
}

// MARK: - Battery

extension UntetheredWatchManager {
    private static let batteryAtStartKey = "untethered.batteryAtStart"
    private static let sessionStartKey = "untethered.sessionStart"

    /// The watch's battery in percent; nil while watchOS doesn't report it.
    static var batteryPercent: Int? {
        let device = WKInterfaceDevice.current()
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel
        return level < 0 ? nil : Int((level * 100).rounded())
    }

    static var batteryText: String { batteryPercent.map { "\($0) %" } ?? "–" }

    /// Logs the battery when a session starts and, when it ends, how much it used and per hour.
    /// Kept in UserDefaults, so a relaunch in between doesn't lose the start.
    func noteSessionBattery(started: Bool) {
        let defaults = UserDefaults.standard
        let now = Date()
        let battery = Self.batteryPercent
        // the own-reading warning counts from the start
        defaults.set(now, forKey: Self.ownReadingAtKey)
        readingsFromPhoneSince = nil
        if started {
            defaults.set(battery, forKey: Self.batteryAtStartKey)
            defaults.set(now, forKey: Self.sessionStartKey)
            let text = battery.map { "\($0) %" } ?? "–"
            Task { await WatchLogger.shared.log("⌚️ Untethered session started, battery \(text)", force: true) }
            return
        }
        let startBattery = defaults.object(forKey: Self.batteryAtStartKey) as? Int
        let start = defaults.object(forKey: Self.sessionStartKey) as? Date
        defaults.removeObject(forKey: Self.batteryAtStartKey)
        defaults.removeObject(forKey: Self.sessionStartKey)
        var line = "⌚️ Untethered session ended"
        if let start {
            let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
            line += " after \(minutes / 60) h \(minutes % 60) min"
            if let startBattery, let battery {
                line += ", battery \(startBattery) % → \(battery) %"
                if minutes >= 10 {
                    let perHour = Double(startBattery - battery) / (Double(minutes) / 60)
                    line += String(format: " (%.1f %% per hour)", perHour)
                }
            }
        }
        Task { await WatchLogger.shared.log(line, force: true) }
    }
}

/// The one-shot flag of `UntetheredWatchManager.withTimeout`. At file scope: a class declared inside the generic
/// function had no initializer the compiler would accept.
private final class TimeoutOnce {
    var done = false
    init() {}
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}

// MARK: - Fallback: the watch takes over when the phone is gone

/// Elias Maurer's fallback loop (EJM0/Trio feat/direct-to-watch, 84ad4da and 7943e43 to 5444214), built here on
/// this branch's own parts: the watch reader supplies the readings and Start Without Phone does the start. With
/// Settings › Apple Watch › Start by Itself When iPhone Stops on (it needs Allow Start Without iPhone), the watch starts
/// untethered mode by itself once the phone's newest reading is about 15 minutes old, the watch read three of its own, and
/// nobody used the pod across the watch's three looks at it, about 10 minutes; once per outage. When the phone is in reach
/// again for a minute, it hands back by itself.
extension UntetheredWatchManager {
    /// The start: the phone's newest reading this old, three of the watch's own newer, and the pod's witness agreeing
    /// over `fallbackWitnessSpan`. Two looks 5 minutes apart held only the phone loop already known to be missed: on
    /// 12 November at 07:31 the watch took over beside a looping phone whose 07:26 reading was missed and whose 07:31
    /// one came 22 s after the watch's (fresh eyes: Claude Fable's review of the same day).
    static let fallbackPhoneSilence: TimeInterval = 14.5 * 60
    /// The looks that found nobody must reach back this far: the window then holds a full phone cycle that isn't
    /// already known to be missed.
    /// One window; 4, not 4.5, as a slow first look and a fast second can make it 263 s (Fable, 12 November).
    static let fallbackWitnessSpan: TimeInterval = 4 * 60
    /// The watch's own readings newer than the phone's newest, for the start.
    static let fallbackOwnReadings = 3
    /// An automatic start only from a copy at most this old when the phone went silent: an older one says
    /// WatchConnectivity was failing, and a temp target or override the phone set after it isn't in it (Fable,
    /// 12 November). Measured to the phone's last sign, so the outage itself doesn't age it out. Start Without Phone by
    /// hand still takes any copy younger than insulin's action time.
    static let fallbackCopyMaxAge: TimeInterval = 60 * 60
    /// The first look at the pod: the phone's newest reading this old, one of the watch's own newer. Two looks, not
    /// three, the first at about 10 minutes; each look costs a looping phone its next pod command.
    /// The window then is 5 minutes again, so a look in the phone's pod slot weighs more (Fable, 12 November).
    static let fallbackProbeAfter: TimeInterval = 9.5 * 60
    /// The second look counts only this long after the first: a phone that loops talks to the pod in between.
    static let fallbackWitnessGap: TimeInterval = 3 * 60
    /// Each look waits this long after the reading, so the phone's loop for the same reading is already done.
    static let fallbackProbeDelay: TimeInterval = 15
    /// How long a look keeps trying to reach the pod, as a takeover does (reads 8 s apart).
    static let fallbackLookPatience: TimeInterval = 32
    /// The wait, the look and a start fit in it.
    static let fallbackWitnessHold: TimeInterval = 70
    /// After a look found the phone at the pod, no look until the second reading after: about 10 minutes, measured from
    /// the look, so the reading 10 minutes on gets one. A look the phone sees as another controller's session holds its
    /// next loop until the watch answered (seconds when it can, up to 3 minutes when not). 20 minutes made a phone
    /// left behind a few minutes after a look wait 34 minutes for the watch (31 October: looked at 08:48 with the phone
    /// still looping, airplane mode at 08:54, the pause from 08:58 kept the 09:18 reading from a look).
    static let fallbackLookPause: TimeInterval = 9 * 60
    static let fallbackHandbackGrace: TimeInterval = 60
    static let fallbackHandbackRepeat: TimeInterval = 5 * 60
    private static let fallbackEpochKey = "untethered.fallbackEpoch"
    private static let fallbackTriedForKey = "untethered.fallbackTriedFor"
    private static let fallbackTriesKey = "untethered.fallbackTries"
    /// Tries per outage, each after its own chain of looks: about an hour and a half.
    static let fallbackTries = 6
    /// How long each try (and each reading during one) holds the app awake for the pod.
    static let fallbackTakeoverHold: TimeInterval = 25

    /// The running session is one the fallback started.
    var isFallbackSession: Bool {
        data.session.phase != .idle && UserDefaults.standard.object(forKey: Self.fallbackEpochKey) as? Int == data.session.epoch
    }

    /// After each of the reader's readings: the phone gone, the watch reading, a copy to start from.
    func checkFallback(readerReadings: [Date], now: Date = Date()) {
        // a try under way: each reading of the reader holds the app awake a while, so the takeover can reach the pod
        if isFallbackSession, data.session.phase == .starting {
            holdForFallbackTakeover()
            return
        }
        let state = WatchState.shared
        let fallbackOn = state.fallbackLoop && state.untetheredMode && state.allowUntetheredStartWithoutPhone
        if fallbackOn != loggedFallbackSetting {
            loggedFallbackSetting = fallbackOn
            Task { await WatchLogger.shared.log("⌚️ Untethered: Start by Itself is \(fallbackOn ? "on" : "off")", force: true) }
        }
        guard fallbackOn, data.session.phase == .idle, !isBusy, !WCSession.default.isReachable,
              versionMismatch == nil, standingGrantAge != nil
        else { return }
        // The phone's newest reading or its last dose, not any contact: on 22 October at 17:05 the phone, Bluetooth
        // off in a metal pot, got through for 5 s with only its 16:50 reading, and counting that contact put the start
        // back by 15 minutes. A phone without new readings or doses isn't looping, whether it answers or not. Its
        // dose counts so one missed reading doesn't bring a look (8 November, 17:21: a minute after the phone's bolus).
        let phoneNewest = WatchG7Reader.shared.phoneLoopSign ?? .distantPast
        let silence = now.timeIntervalSince(phoneNewest)
        let ownNewer = readerReadings.filter { $0 > phoneNewest.addingTimeInterval(60) }.count
        if let paused = fallbackLooksPaused {
            guard paused.phoneNewest == phoneNewest, now < paused.until else {
                fallbackLooksPaused = nil
                return checkFallback(readerReadings: readerReadings, now: now)
            }
            return
        }
        guard silence > Self.fallbackProbeAfter, ownNewer >= 1 else {
            dropFallbackWitness()
            return
        }
        if let issuedAt = data.standingGrantIssuedAt, phoneNewest.timeIntervalSince(issuedAt) > Self.fallbackCopyMaxAge {
            if loggedOldCopyFor != issuedAt, requestStandingGrantIfMissing(force: true) {
                loggedOldCopyFor = issuedAt
                let minutes = Int(phoneNewest.timeIntervalSince(issuedAt) / 60)
                Task {
                    await WatchLogger.shared.log(
                        "⌚️ Untethered: fallback — the phone's copy was \(minutes) min old when it went silent, too old to start by itself (asked for a new one)",
                        force: true
                    )
                }
                notify(
                    id: Self.notificationPrefix + "oldCopy",
                    title: String(localized: "Watch Can't Take Over by Itself"),
                    body: String(
                        localized: "The iPhone's settings on the watch were over an hour old when the iPhone went silent. Bring the iPhone back, or open Trio on the watch near the pod and tap Start Without Phone."
                    ),
                    asksForAction: true
                )
            }
            dropFallbackWitness()
            return
        }
        // this outage's tries are spent, or the watch already had the pod in it: no more looks (each holds the
        // phone's dosing if it comes back) until the phone sends a newer reading
        if UserDefaults.standard.object(forKey: Self.fallbackTriedForKey) as? Date == phoneNewest,
           UserDefaults.standard.integer(forKey: Self.fallbackTriesKey) >= Self.fallbackTries
        {
            dropFallbackWitness()
            return
        }
        // A try that didn't reach the pod is tried again only after a look that found nobody since the one before:
        // starting again on a decision up to 25 minutes old missed a phone that came back meanwhile (Fable, 12 November).
        // The phone's readings reach a sleeping watch late or not at all (28 October: the watch started at 21:58
        // and 20:30 beside a phone that looped every 5 minutes). So the pod decides: a phone that loops makes a
        // session on it every 5 minutes, which the watch's next look at the pod shows. The watch starts only when
        // nobody used the pod between two looks about 5 minutes apart.
        guard !isWitnessingPod, !isMeetingPod else { return }
        isWitnessingPod = true
        let readingAt = readerReadings.max()
        lookAbandoned = false
        let releaseHold = Self.holdProcess(
            reason: "Untethered fallback: looking at the pod",
            upTo: Self.fallbackWitnessHold,
            onExpire: { [weak self] in self?.abandonLook() }
        )
        Task { @MainActor in
            defer {
                self.isWitnessingPod = false
                releaseHold()
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.fallbackProbeDelay * 1_000_000_000))
            // the phone may have been heard meanwhile, been at the pod (a pause), be in reach, or a session begun
            guard self.data.session.phase == .idle, (WatchG7Reader.shared.phoneLoopSign ?? .distantPast) == phoneNewest,
                  self.fallbackLooksPaused == nil, !WCSession.default.isReachable, !self.isBusy, !self.lookAbandoned
            else { return }
            let minutes = Int(Date().timeIntervalSince(phoneNewest) / 60)
            switch await self.lookAtPod(readingAt: readingAt) {
            case .tooSoon:
                return
            case let .notReached(reason):
                Task {
                    await WatchLogger.shared.log("⌚️ Untethered: fallback — the watch's look didn't reach the pod (\(reason))", force: true)
                }
            case .firstLook:
                // a fresh manager can't vouch for anything before its first look: the chain starts here
                self.fallbackNobodySince = Date()
                self.fallbackNobodyLooks = 0
                Task {
                    await WatchLogger.shared.log(
                        "⌚️ Untethered: fallback — no word from the phone for \(minutes) min, the watch looks at the pod first",
                        force: true
                    )
                }
            case let .phoneUsedPod(at):
                self.dropFallbackWitness()
                self.fallbackDecidedFor = nil
                self.fallbackLooksPaused = (phoneNewest, Date().addingTimeInterval(Self.fallbackLookPause))
                Task {
                    await WatchLogger.shared.log(
                        "⌚️ Untethered: fallback — the phone has used the pod since the first look (seen at \(Self.timeText(at))): " +
                            "it loops, no start; next look in about 10 min unless the phone is heard",
                        force: true
                    )
                }
            case .nobody:
                let now = Date()
                self.fallbackNobodyLooks += 1
                let since = self.fallbackNobodySince ?? now
                if self.fallbackNobodySince == nil { self.fallbackNobodySince = now }
                let span = now.timeIntervalSince(since)
                let silenceNow = now.timeIntervalSince(phoneNewest)
                let retry = self.fallbackDecidedFor == phoneNewest
                let chain = "nobody at the pod since \(Self.timeText(since)) (\(self.fallbackNobodyLooks + 1) looks, \(Int(span / 60)) min)"
                // a retry too: a try that didn't reach the pod may have found the phone holding it (Fable, 12 November)
                guard silenceNow > Self.fallbackPhoneSilence, ownNewer >= Self.fallbackOwnReadings, span >= Self.fallbackWitnessSpan
                else {
                    Task {
                        await WatchLogger.shared.log(
                            "⌚️ Untethered: fallback — \(chain), no word from the phone for \(minutes) min: one more look before starting",
                            force: true
                        )
                    }
                    return
                }
                let reader = WatchG7Reader.shared
                let grantAge = self.standingGrantAge.map { "\(Int($0 / 60)) min" } ?? "none"
                Task {
                    await WatchLogger.shared.log(
                        "⌚️ Untethered: fallback — \(chain)\(retry ? ", again after a try that didn't reach it" : ""), " +
                            "no word from the phone for \(minutes) min (its reading \(reader.phoneGlucoseDate.map(Self.timeText) ?? "none"), " +
                            "dose \(reader.phoneDoseDate.map(Self.timeText) ?? "none"), in reach \(WCSession.default.isReachable), " +
                            "copy \(grantAge) old, \(ownNewer) own readings): the phone is gone",
                        force: true
                    )
                }
                // Never two managers bidding for the pod: with the look's beside the takeover's, the takeover never
                // connected (30 October, 14:03:59 and 14:18:54). The look's manager, connected a moment ago, becomes
                // the takeover's (`takeover`).
                if let witness = self.fallbackWitness { self.fallbackTakeoverPump = (witness.pump, witness.issuedAt) }
                self.fallbackWitness = nil
                self.fallbackNobodySince = nil
                self.fallbackNobodyLooks = 0
                self.fallbackDecidedFor = phoneNewest
                self.fallbackDecidedAt = Date()
                self.startFallback(phoneNewest: phoneNewest, minutes: minutes)
            }
        }
    }

    enum PodLook: Equatable {
        case tooSoon
        case notReached(String)
        case firstLook
        case phoneUsedPod(Date)
        case nobody
    }

    /// Reads the pod with a manager made from the standing grant, without dosing: the first look keeps the manager,
    /// the second, at least `fallbackWitnessGap` later, reports whether another controller made a session on the
    /// pod since (the pod resynchronizes the session counter, `lastForeignSessionAt`).
    func lookAtPod(readingAt: Date? = nil) async -> PodLook {
        let since = fallbackWitness?.at
        if let since, Date().timeIntervalSince(since) < Self.fallbackWitnessGap { return .tooSoon }
        let pump: PumpManager & ExclusiveDeviceControl
        // the copy the manager was made from: the takeover goes on with it only if it starts from the same
        var issuedAt = fallbackWitness?.issuedAt
        if let witness = fallbackWitness {
            pump = witness.pump
        } else {
            issuedAt = data.standingGrantIssuedAt
            guard let grant = data.standingGrant,
                  let configuration = Self.configuration(grant.pumpConfiguration),
                  let type = watchPumpManagers[configuration.managerIdentifier],
                  let made = type.init(adopting: configuration, localState: localState(for: configuration.managerIdentifier))
            else { return .notReached("no copy of the pod to look from") }
            // its link messages reach the log; its events and status are kept apart (isSessionPump)
            made.pumpManagerDelegate = self
            made.delegateQueue = .main
            pump = made
        }
        // A pod this watch never connected to has no handle here, and finding it takes a search, which watchOS
        // doesn't run for an app in the background (30 October: the pod changed at 20:25 on the 29th; from then
        // every look searched and none found it, as the watch's own takeover searches found the pod in the night
        // of the 28th only when Trio was opened at 02:38). The watch learns the handle in a session of its own.
        if pump.takeControlNeedsSearch, WKApplication.shared().applicationState != .active {
            askForSessionWithNewPod()
            return .notReached("the watch doesn't know this pod yet and can't search for it in the background")
        }
        // the link takes a few seconds: a single read right after taking control failed at once every time
        // (29 October, 20:28 to 20:53 with the phone in a pot: 6 looks, none reached the pod, no start)
        lookingPump = pump
        defer { lookingPump = nil }
        pump.takeControl()
        let started = Date()
        var read: UntetheredPodStatus?
        var readAt: Date?
        while read == nil, !lookAbandoned {
            read = await readPump(pump)
            if read != nil { readAt = Date() }
            guard read == nil, !lookAbandoned, Date().timeIntervalSince(started) < Self.fallbackLookPatience else { break }
            try? await Task.sleep(nanoseconds: Self.takeoverReadInterval)
        }
        if !pump.isControlReleased { pump.releaseControl() }
        // laid over the phone's pod slot in the logs: a look in it can keep the phone's loop from the pod
        let offset = { (date: Date?) -> String in
            guard let date, let readingAt else { return "?" }
            return "+\(Int(date.timeIntervalSince(readingAt))) s"
        }
        let lookLine = "⌚️ Untethered: fallback look — took the pod \(offset(started)) after the watch's reading, " +
            "\(readAt != nil ? "read it at \(offset(readAt))" : "no answer"), let go at \(offset(Date()))"
        Task { await WatchLogger.shared.log(lookLine, force: true) }
        if lookAbandoned { return .notReached("watchOS ended the background time; the watch let go of the pod") }
        guard read != nil else {
            return .notReached("no answer in \(Int(Date().timeIntervalSince(started))) s")
        }
        fallbackWitness = (pump, Date(), issuedAt)
        // the handle it found is kept, as a session keeps its own: the next look and a takeover connect directly
        if let local = Self.plist(pump.localState) { store.update { $0.localStates[pump.pluginIdentifier] = local } }
        guard let since else { return .firstLook }
        if let foreign = pump.lastForeignSessionAt, foreign > since { return .phoneUsedPod(foreign) }
        return .nobody
    }

    private static let newPodNoticeKey = "untethered.newPodNoticeAt"
    /// Whether the pod of the last standing grant was unknown to this watch: the notice goes out when a grant for a
    /// pod it doesn't know follows one for a pod it knew, that is right after a pod change.
    private static let grantPodUnknownKey = "untethered.grantPodUnknown"

    /// At most every 12 hours while the watch doesn't know the pod, and at once after a pod change (`force`).
    private func askForSessionWithNewPod(force: Bool = false) {
        let last = UserDefaults.standard.object(forKey: Self.newPodNoticeKey) as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) > 12 * 60 * 60 else { return }
        UserDefaults.standard.set(Date(), forKey: Self.newPodNoticeKey)
        notify(
            id: Self.notificationPrefix + "newPod",
            title: String(localized: "Watch Doesn't Know the Pod Yet"),
            body: String(
                localized: "To take over by itself, the watch has to have reached this pod once: after a pod change, or after Trio was installed again on the watch. Open Trio on the watch with the iPhone nearby: it looks for the pod by itself."
            ),
            asksForAction: true
        )
    }

    // MARK: - Meeting a new pod

    /// The pod of the standing grant has no handle on this watch. Finding it takes a search, which watchOS runs only
    /// for an app in front, so the fallback can't reach it in the background (2 November: the pod changed at 21:30,
    /// and the fallback's looks at 05:56 and 05:58 could not search for it; a session started by hand at 06:09
    /// found it in 4 s). False without a grant.
    var standingGrantPodUnknown: Bool {
        guard let grant = data.standingGrant,
              let configuration = Self.configuration(grant.pumpConfiguration),
              let type = watchPumpManagers[configuration.managerIdentifier]
        else { return false }
        return type.takeControlNeedsSearch(adopting: configuration, localState: localState(for: configuration.managerIdentifier))
    }

    /// A meeting that didn't find the pod is tried again at the next time Trio comes to the front, at most this often.
    static let podMeetingInterval: TimeInterval = 60
    /// How long a meeting keeps trying to reach the pod: the search and a read.
    static let podMeetingPatience: TimeInterval = 40

    /// A new standing grant: right after a pod change the watch doesn't know the pod. With Trio in front it looks for
    /// it at once; otherwise it says so now, in the evening of the change, not at the fallback's first look at night.
    func standingGrantArrived() {
        let unknown = standingGrantPodUnknown
        let wasUnknown = UserDefaults.standard.bool(forKey: Self.grantPodUnknownKey)
        UserDefaults.standard.set(unknown, forKey: Self.grantPodUnknownKey)
        guard unknown else { return }
        if WKApplication.shared().applicationState == .active {
            meetNewPodIfNeeded()
        } else if !wasUnknown, WatchState.shared.untetheredMode, WatchState.shared.allowUntetheredStartWithoutPhone {
            Task { await WatchLogger.shared.log("⌚️ Untethered: the phone's copy is for a pod the watch doesn't know yet", force: true) }
            askForSessionWithNewPod(force: true)
        }
    }

    private func isMeeting(_ pump: PumpManager) -> Bool {
        meetingPump.map { ($0 as AnyObject) === (pump as AnyObject) } ?? false
    }

    /// With Trio in front the watch can search: a pod of the standing grant it doesn't know yet is looked for once and
    /// its handle kept, so the fallback reaches it in the background later. It only reads the pod, as the fallback's
    /// looks do, and doses nothing.
    func meetNewPodIfNeeded() {
        guard data.session.phase == .idle, !isBusy, !isWitnessingPod, !isMeetingPod, fallbackWitness == nil,
              WatchState.shared.untetheredMode, WatchState.shared.allowUntetheredStartWithoutPhone,
              versionMismatch == nil, WKApplication.shared().applicationState == .active, standingGrantPodUnknown,
              Date().timeIntervalSince(podMeetingTriedAt ?? .distantPast) > Self.podMeetingInterval,
              let grant = data.standingGrant,
              let configuration = Self.configuration(grant.pumpConfiguration),
              let type = watchPumpManagers[configuration.managerIdentifier],
              let pump = type.init(adopting: configuration, localState: localState(for: configuration.managerIdentifier))
        else { return }
        podMeetingTriedAt = Date()
        isMeetingPod = true
        // its link messages reach the log; its events and status are kept apart (isSessionPump)
        pump.pumpManagerDelegate = self
        pump.delegateQueue = .main
        meetingPump = pump
        Task { await WatchLogger.shared.log("⌚️ Untethered: Trio in front, looking for the pod the watch doesn't know yet", force: true) }
        let releaseHold = Self.holdProcess(reason: "Untethered: looking for the new pod", upTo: Self.fallbackWitnessHold)
        Task { @MainActor in
            defer {
                self.isMeetingPod = false
                releaseHold()
            }
            pump.takeControl()
            let started = Date()
            var read: UntetheredPodStatus?
            while read == nil {
                read = await self.readPump(pump)
                guard read == nil, self.isMeeting(pump), self.data.session.phase == .idle,
                      Date().timeIntervalSince(started) < Self.podMeetingPatience
                else { break }
                try? await Task.sleep(nanoseconds: Self.takeoverReadInterval)
            }
            // a takeover took over meanwhile: it already let go of this manager
            guard self.isMeeting(pump) else { return }
            self.meetingPump = nil
            pump.releaseControl()
            let seconds = Int(Date().timeIntervalSince(started))
            guard read != nil, let local = Self.plist(pump.localState) else {
                await WatchLogger.shared.log("⌚️ Untethered: the pod wasn't found in \(seconds) s; tried again when Trio is opened", force: true)
                return
            }
            self.store.update { $0.localStates[pump.pluginIdentifier] = local }
            UserDefaults.standard.set(false, forKey: Self.grantPodUnknownKey)
            self.refresh()
            await WatchLogger.shared.log("⌚️ Untethered: found the new pod in \(seconds) s; the fallback can reach it now", force: true)
        }
    }

    /// The phone's ownership question and its take-back come from a phone that has just been at the pod: no look for a
    /// while. A look is a session on the pod the phone has to refuse and ask about, with its dosing held meanwhile; one
    /// 9 s after the phone took the pump back left it refusing for 10 minutes, a bolus with it (3 November, second
    /// tester, 14:28:52). Its phone readings reach a sleeping watch late, so they alone don't stop the looks.
    private func pauseLooksIfPhoneAtPod(_ message: UntetheredMessage) {
        switch message {
        case .revoke,
             .statusQuery:
            break
        default:
            return
        }
        guard data.session.phase == .idle || message == .revoke else { return }
        dropFallbackWitness()
        fallbackDecidedFor = nil
        let phoneNewest = WatchG7Reader.shared.phoneLoopSign ?? .distantPast
        fallbackLooksPaused = (phoneNewest, Date().addingTimeInterval(Self.fallbackLookPause))
        Task { await WatchLogger.shared.log("⌚️ Untethered: fallback — the phone was just at the pod, no look for 9 min", force: true) }
    }

    func dropFallbackWitness() {
        fallbackNobodySince = nil
        fallbackNobodyLooks = 0
        guard let witness = fallbackWitness else { return }
        if !witness.pump.isControlReleased { witness.pump.releaseControl() }
        fallbackWitness = nil
    }

    /// watchOS ends the look's background time: let go of the pod now, as a suspended look would keep it from the phone
    /// until the next wake (Fable, 12 November).
    func abandonLook() {
        lookAbandoned = true
        if let pump = lookingPump, !pump.isControlReleased { pump.releaseControl() }
        Task { await WatchLogger.shared.log("⌚️ Untethered: fallback — watchOS ended the look's background time, the watch let go of the pod", force: true) }
    }

    /// At a fallback try's first read with the deciding look's manager: the pod resynchronized its message count, so
    /// another controller (the phone) had a session after the look. The try stops before anything is dosed.
    func phoneUsedPodSinceDecision(_ pump: PumpManager & ExclusiveDeviceControl) -> Bool {
        guard isFallbackSession, fallbackTakeoverFromLook, let decidedAt = fallbackDecidedAt else { return false }
        if let foreign = pump.lastForeignSessionAt, foreign > decidedAt {
            fallbackAbortedForPhone = true
            Task {
                await WatchLogger.shared.log(
                    "⌚️ Untethered: fallback — the takeover's first read: the pod saw another controller after the deciding look (\(Self.timeText(decidedAt))), the phone is there; stopping before anything is dosed",
                    force: true
                )
            }
            apply(.takeoverFailed(String(localized: "The iPhone used the pod after the watch decided to take over.")))
            return true
        }
        Task {
            await WatchLogger.shared.log(
                "⌚️ Untethered: fallback — the takeover's first read: no other controller at the pod since the deciding look (\(Self.timeText(decidedAt)))",
                force: true
            )
        }
        return false
    }

    /// watchOS ends a fallback try's background time before the pod answered: the try lets go of the pod instead of
    /// keeping it from the phone for its lease; the next reading tries again after a look.
    func fallbackTakeoverHoldExpired() {
        guard isFallbackSession, data.session.phase == .starting else { return }
        Task { await WatchLogger.shared.log("⌚️ Untethered: fallback — watchOS ended the takeover's background time, the watch lets go of the pod", force: true) }
        apply(.takeoverFailed(String(localized: "watchOS ended the watch's background time before the pod answered.")))
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// The start itself, once the pod showed nobody used it between the watch's two looks.
    private func startFallback(phoneNewest: Date, minutes: Int) {
        // the look's manager, if the start didn't take it (`takeover`): let go of the pod
        defer {
            if let unused = fallbackTakeoverPump {
                fallbackTakeoverPump = nil
                if !unused.pump.isControlReleased { unused.pump.releaseControl() }
            }
        }
        // A few tries per outage, one per reading of the reader at most: the pod may not answer within the seconds
        // a background wake gives (24 October, tester: none in the first, and no second). The next outage needs a
        // newer reading from the phone first.
        let triedFor = UserDefaults.standard.object(forKey: Self.fallbackTriedForKey) as? Date
        let earlierTries = triedFor == phoneNewest ? UserDefaults.standard.integer(forKey: Self.fallbackTriesKey) : 0
        guard earlierTries < Self.fallbackTries else { return }
        let attempt = earlierTries + 1
        UserDefaults.standard.set(phoneNewest, forKey: Self.fallbackTriedForKey)
        UserDefaults.standard.set(attempt, forKey: Self.fallbackTriesKey)
        if let grant = data.standingGrant, let issuedAt = data.standingGrantIssuedAt { fallbackGrantCopy = (grant, issuedAt) }
        Task {
            await WatchLogger.shared.log(
                "⌚️ Untethered: fallback — no word from the phone for \(minutes) min, the watch reads the sensor: starting without the phone (try \(attempt) of \(Self.fallbackTries))",
                force: true
            )
        }
        // held before the start, not after: the wake that brought the reading may be ending already
        let releaseHold = holdForFallbackTakeover()
        startWithoutPhone(phoneReachableIsNoPhone: true)
        guard data.session.phase == .starting else {
            Task { await WatchLogger.shared.log("⌚️ Untethered: fallback start didn't begin", force: true) }
            releaseHold()
            return
        }
        UserDefaults.standard.set(data.session.epoch, forKey: Self.fallbackEpochKey)
        guard attempt == 1 else { return }
        // not "took over" yet: that comes when the pod answered (`fallbackTookOver`), usually within seconds, and
        // cancels this one before it shows. Only a takeover that takes longer says so first (7 November: both came
        // within 4 s, one tap, and neither was seen).
        notify(
            id: Self.notificationPrefix + "fallback",
            title: String(localized: "iPhone Out of Reach"),
            body: String(
                localized: "The iPhone has been silent for \(minutes) minutes. The watch is trying to take over the pump and tells you when it has."
            ),
            after: 60
        )
    }

    /// Awake for a while, so the takeover's pod reads can run: in the background the app is suspended within seconds.
    @discardableResult private func holdForFallbackTakeover() -> () -> Void {
        Self.holdProcess(
            reason: "Untethered fallback: reaching the pod",
            upTo: Self.fallbackTakeoverHold,
            onExpire: { [weak self] in self?.fallbackTakeoverHoldExpired() }
        )
    }

    private func fallbackTookOver() {
        fallbackGrantCopy = nil
        fallbackTakeoverFromLook = false
        fallbackDecidedAt = nil
        // This outage is done: a session ended later, by hand or otherwise, isn't started again until the phone has
        // sent a newer reading (before, the next reading started it again at once while the phone stayed away).
        fallbackDecidedFor = nil
        UserDefaults.standard.set(Self.fallbackTries, forKey: Self.fallbackTriesKey)
        Task { await WatchLogger.shared.log("⌚️ Untethered: fallback — the watch has the pod", force: true) }
        let minutes = (WatchG7Reader.shared.phoneGlucoseDate).map { Int(Date().timeIntervalSince($0) / 60) }
        let body = minutes.map {
            String(
                localized: "The iPhone has been silent for \($0) minutes and is out of reach. The watch runs the pump until it's back, then hands it back by itself."
            )
        } ?? String(localized: "The watch runs the pump until the iPhone is back, then hands it back by itself.")
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationPrefix + "fallback"])
        // watchOS starts Extended Untethered Mode's workout only with Trio in front
        let opensForWorkout = WatchState.shared.untetheredWorkout && WKApplication.shared().applicationState != .active
        // who doses changed: felt twice and asked again at 2 and 5 minutes until Trio is opened (7 November: a single
        // tap, and the notice wasn't seen); with the workout to start, the title says so too
        notify(
            id: Self.tookOverID,
            title: opensForWorkout ? String(localized: "Watch Took Over: Open Trio") : String(localized: "Watch Took Over"),
            body: opensForWorkout
                ? body + " " + String(localized: "Open Trio on the watch once, so it starts the workout that keeps it awake.")
                : body,
            asksForAction: WKApplication.shared().applicationState != .active
        )
    }

    static let tookOverID = notificationPrefix + "tookOver"

    /// A try's time ran out without the pod: the next reading tries again, the last one says so.
    private func fallbackTryFailed() {
        fallbackTakeoverFromLook = false
        if fallbackAbortedForPhone {
            fallbackAbortedForPhone = false
            // the phone is there: this outage is over, and the looks rest as after the phone's ownership question
            fallbackDecidedFor = nil
            fallbackDecidedAt = nil
            // the phone was there: no try used up, so a later real outage still gets all of them
            let attempt = UserDefaults.standard.integer(forKey: Self.fallbackTriesKey)
            UserDefaults.standard.set(max(0, attempt - 1), forKey: Self.fallbackTriesKey)
            if data.standingGrant == nil, let copy = fallbackGrantCopy {
                store.update {
                    $0.standingGrant = copy.grant
                    $0.standingGrantIssuedAt = copy.issuedAt
                }
                refresh()
            }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationPrefix + "fallback"])
            let phoneNewest = WatchG7Reader.shared.phoneLoopSign ?? .distantPast
            fallbackLooksPaused = (phoneNewest, Date().addingTimeInterval(Self.fallbackLookPause))
            return
        }
        let attempt = UserDefaults.standard.integer(forKey: Self.fallbackTriesKey)
        Task {
            await WatchLogger.shared.log(
                "⌚️ Untethered: fallback — try \(attempt) of \(Self.fallbackTries) didn't reach the pod",
                force: true
            )
        }
        // The try reached no pod and dosed nothing: the next starts from the same grant, unless the phone sent a newer
        // one meanwhile; after the last, Start Without Phone on the watch can still use it.
        if data.standingGrant == nil, let copy = fallbackGrantCopy {
            store.update {
                $0.standingGrant = copy.grant
                $0.standingGrantIssuedAt = copy.issuedAt
            }
            refresh()
        }
        guard attempt >= Self.fallbackTries else { return }
        notify(
            id: Self.notificationPrefix + "fallback",
            title: String(localized: "Watch Couldn't Take Over"),
            body: String(
                localized: "The watch couldn't reach the pod, and nothing is looping: the pod finishes the iPhone's last temp basal, then runs its scheduled basal. Bring the iPhone back, or open Trio on the watch near the pod and tap Start Without Phone."
            ),
            asksForAction: true
        )
    }

    /// The phone is back (in reach, or its watch state arrived with a fresh reading): after a minute the fallback's
    /// session goes back to it, by the queued request a stall uses, as the watch is rarely in reach in the background
    /// (2026-10-21: the walk's request reached the phone on its own). The status goes first, so the phone knows the
    /// session the request names.
    func scheduleFallbackHandback(grace: TimeInterval = UntetheredWatchManager.fallbackHandbackGrace) {
        guard isFallbackSession, data.session.phase == .active, !fallbackHandbackPending, phoneCanLoop() else { return }
        fallbackHandbackPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self else { return }
            self.fallbackHandbackPending = false
            // The fallback's own request goes again every 5 minutes while the phone shows up, not every 30 as a
            // stall's: on 23 October the phone's first take-back (07:49) found no pod link in 5 s, the requests at
            // the phone's next appearances (07:50 to 08:20) were held back, and the watch kept the pump until 08:25.
            guard self.isFallbackSession, self.data.session.phase == .active, !self.isBolusing, self.phoneCanLoop(),
                  Date().timeIntervalSince(self.handbackRequestedAt ?? .distantPast) > Self.fallbackHandbackRepeat
            else { return }
            self.handbackRequestedAt = Date()
            Task { await WatchLogger.shared.log("⌚️ Untethered: fallback — the phone is back, handing the pump back", force: true) }
            self.send(.statusReport(holding: self.data.session.startStatus), epoch: self.data.session.epoch, queueing: true)
            self.send(.handbackRequested(minutesWithoutLoop: 0), epoch: self.data.session.epoch, queueing: true)
            self.holdOffPodForTakeBack()
        }
    }

    /// The phone in reach isn't enough to hand back: on 8 November the phone's sensor had been removed at 11:48, the
    /// watch took over at 12:01 and handed back at 12:11 because the phone was in reach again, and the phone, with no
    /// glucose, didn't loop until 14:06. So the pump goes back once the phone has a reading of its own from the last
    /// 10 minutes. While the watch reads none either, it goes back as before: then neither loops, and the phone is
    /// where the pump can be used by hand. Ending by hand or the phone's take-back are unaffected.
    private func phoneCanLoop(now: Date = Date()) -> Bool {
        let window: TimeInterval = 10 * 60
        if let phone = WatchG7Reader.shared.phoneGlucoseDate, now.timeIntervalSince(phone) < window { return true }
        guard let own = ownReadingAt, now.timeIntervalSince(own) < window else { return true }
        if now.timeIntervalSince(fallbackHandbackHeldLoggedAt ?? .distantPast) > 15 * 60 {
            fallbackHandbackHeldLoggedAt = now
            let minutes = WatchG7Reader.shared.phoneGlucoseDate.map { "\(Int(now.timeIntervalSince($0) / 60)) min" } ?? "none"
            Task {
                await WatchLogger.shared.log(
                    "⌚️ Untethered: fallback — the phone is back without a reading of its own (newest: \(minutes)); the watch keeps the pump",
                    force: true
                )
            }
        }
        return false
    }

    /// The phone's watch state arrived: with a reading of its own from the last 10 minutes, the phone is back.
    func notePhoneState() {
        guard isFallbackSession, data.session.phase == .active,
              let phoneNewest = WatchG7Reader.shared.phoneGlucoseDate, Date().timeIntervalSince(phoneNewest) < 10 * 60
        else { return }
        scheduleFallbackHandback()
    }
}
