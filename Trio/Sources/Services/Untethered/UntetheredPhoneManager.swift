import Combine
import CoreData
import Foundation
import HealthKit
import LoopKit
import OmnipodKit
import Swinject
import UIKit
import WatchConnectivity

/// Read by the loop, bolus and watch paths without resolving any service, so a relaunch holds
/// dosing from its first loop on.
enum UntetheredGate {
    private static let lock = NSLock()
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("untethered-phone.json")
    private static var cached = UntetheredPhoneState()
    /// The saved state is there but can't be read yet: iOS can wake Trio after a restart before the first unlock,
    /// when the file is still protected. Until it is read, the phone doesn't dose and saves nothing over it: an idle
    /// state written then would wipe out the watch's running session (Ponytail's review, 15 November).
    private static var locked = false
    private static var loaded = false

    /// Reads the saved state once, and again while it is locked. Called with the lock held.
    private static func loadIfNeeded() {
        guard !loaded || locked else { return }
        loaded = true
        let saved: Data
        do {
            saved = try Data(contentsOf: url)
        } catch {
            if (error as? CocoaError)?.code == .fileReadNoSuchFile || !FileManager.default.fileExists(atPath: url.path) {
                locked = false
                return
            }
            if !locked {
                locked = true
                warning(.watch, "Untethered: saved state locked (\(error.localizedDescription)); no dosing until it opens")
                DispatchQueue.main.async { observeProtectedData() }
            }
            return
        }
        if locked {
            debug(.watch, "Untethered: saved state open again, taken on")
            // what launch would have resumed from it runs now (`UntetheredPhoneManager.stateOpened`)
            DispatchQueue.main.async {
                Foundation.NotificationCenter.default.post(name: .untetheredGateOpened, object: nil)
                Foundation.NotificationCenter.default.post(name: .untetheredGateDidChange, object: nil)
            }
        }
        locked = false
        do {
            cached = try JSONDecoder().decode(UntetheredPhoneState.self, from: saved)
        } catch {
            // kept aside rather than overwritten by the next save, so nothing is lost silently
            let aside = url.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            cached = UntetheredPhoneState()
            warning(.watch, "Untethered: saved state unreadable, kept aside: \(error)")
        }
    }

    private static var protectedDataObserver: NSObjectProtocol?

    /// Reads again as soon as the phone is unlocked, and tells the screens and the manager.
    private static func observeProtectedData() {
        guard protectedDataObserver == nil else { return }
        protectedDataObserver = Foundation.NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { _ in
            // opening posts what follows itself
            lock.withLock { loadIfNeeded() }
        }
    }

    static var state: UntetheredPhoneState { lock.withLock {
        loadIfNeeded()
        return cached
    } }

    /// The saved state couldn't be read yet.
    static var isLocked: Bool { lock.withLock {
        loadIfNeeded()
        return locked
    } }

    /// The phone may loop, bolus and change the pump.
    static var phoneMayDose: Bool {
        let (state, locked) = lock.withLock { () -> (UntetheredPhoneState, Bool) in
            loadIfNeeded()
            return (cached, self.locked)
        }
        return !locked && state.session.isIdle && !state.pumpReturnPending
    }

    /// Every change reaches the screens, whichever path made it. While the saved state is locked a change stays in
    /// memory only; the saved state, once read, is what counts.
    @discardableResult static func update<T>(_ change: (inout UntetheredPhoneState) -> T) -> T {
        let result = lock.withLock {
            loadIfNeeded()
            let result = change(&cached)
            if !locked, let data = try? JSONEncoder().encode(cached) {
                try? data.write(to: url, options: .atomic)
            }
            return result
        }
        DispatchQueue.main.async {
            Foundation.NotificationCenter.default.post(name: .untetheredGateDidChange, object: nil)
        }
        return result
    }
}

extension Notification.Name {
    static let untetheredSessionDidChange = Notification.Name("untetheredSessionDidChange")
    static let untetheredGateDidChange = Notification.Name("untetheredGateDidChange")
    static let untetheredGateOpened = Notification.Name("untetheredGateOpened")
}

enum UntetheredError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(reason): return reason
        }
    }
}

/// The phone's side of untethered watch mode: hands the pump to the watch, holds its own dosing
/// meanwhile, takes the pump back and stores what the watch did.
final class UntetheredPhoneManager: ObservableObject, Injectable {
    @Injected() private var apsManager: APSManager!
    @Injected() private var fetchGlucoseManager: FetchGlucoseManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var storage: FileStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var carbsStorage: CarbsStorage!
    @Injected() private var tddStorage: TDDStorage!
    @Injected() private var pumpHistoryStorage: PumpHistoryStorage!
    @Injected() private var adjustmentManager: AdjustmentManager!
    @Injected() private var tempTargetsStorage: TempTargetsStorage!
    @Injected() private var determinationStorage: DeterminationStorage!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var nightscoutManager: NightscoutManager!
    @Injected() private var healthkitManager: HealthKitManager!
    @Injected() private var tidepoolManager: TidepoolManager!

    /// Read from the gate itself, never a copy: the screens can't show a state the loop no longer holds.
    var state: UntetheredPhoneState { UntetheredGate.state }
    private var wasIdle = UntetheredGate.state.session.isIdle

    static let leaseLength: TimeInterval = 120
    /// How old the newest glucose may be when the watch takes over.
    static let maxGlucoseAge: TimeInterval = 12 * 60

    private var openAPS: OpenAPS!
    private var ticker: Timer?
    /// Trio kept running for the first seconds of the wait for the watch's ownership answer.
    private var answerWaitTask = UIBackgroundTaskIdentifier.invalid
    private var lastHandledForeignSessionAt: Date?
    private let assembler = UntetheredChunks.Assembler()
    private var endRequestTimer: Timer?
    /// How long a normal hand-back waits for the watch's last records before the audit judges the pump.
    private static let historyWait: TimeInterval = 60
    /// Between reads of a returned pump: each read already waits for the link (20 s, 45 s with the eager connect).
    private static let pumpReadRetry: UInt64 = 2_000_000_000
    /// A returned pump with no link by then is searched for by its address (`escalateTakeControl`).
    private static let pumpEscalateAfter: UInt64 = 12_000_000_000
    private var linkedOverrideTimer: Timer?
    /// What ran on the phone at the last change, so a cancel made here can be told to the watch.
    private var runningOverrideStart: Date?
    private var runningTempTargetStart: Date?
    private var subscriptions = Set<AnyCancellable>()

    init(resolver: Resolver) {
        injectServices(resolver)
        openAPS = OpenAPS(storage: storage, tddStorage: tddStorage, glucoseStorage: glucoseStorage, carbsStorage: carbsStorage)
        Foundation.NotificationCenter.default.publisher(for: .untetheredGateDidChange)
            .sink { [weak self] _ in Task { @MainActor in self?.publish() } }
            .store(in: &subscriptions)
        Foundation.NotificationCenter.default.publisher(for: .untetheredGateOpened)
            .sink { [weak self] _ in Task { @MainActor in await self?.stateOpened() } }
            .store(in: &subscriptions)
        Foundation.NotificationCenter.default.publisher(for: .didUpdateOverrideConfiguration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task {
                    await self?.forwardCancellations()
                    await self?.checkLinkedOverride()
                }
            }
            .store(in: &subscriptions)
        Foundation.NotificationCenter.default.publisher(for: .didUpdateTempTargetConfiguration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.forwardCancellations() } }
            .store(in: &subscriptions)
        glucoseStorage.updatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleWatchWake() }
            .store(in: &subscriptions)
        Publishers.Merge(apsManager.lastLoopDateSubject.map { _ in () }, carbsStorage.updatePublisher)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleStandingGrant() }
            .store(in: &subscriptions)
        // a bolus goes at once, not after the burst: the phone may be gone in seconds, and a copy without the bolus
        // leaves its rest unknown to a watch that starts without it
        pumpHistoryStorage.updatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleStandingGrant(immediately: true) }
            .store(in: &subscriptions)
        apsManager.lastLoopDateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.checkForeignSession()
                    await self?.checkPodGap()
                }
            }
            .store(in: &subscriptions)
        // a command the pod refused ends the loop with an error, and no loop date follows
        apsManager.lastError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in await self?.checkForeignSession() } }
            .store(in: &subscriptions)
        // A refusal outside a loop raises neither: opening Trio fetches the pod's status, and a loop that changes
        // nothing sends no command. On 3 November (second tester) the status fetches at 14:35 and 14:37 were refused
        // after a look of the watch's, nobody asked the watch, and the bolus at 14:38 was refused too. Checked a few
        // seconds after Trio comes to the front, when that fetch is done, and at every reading.
        Foundation.NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.tickWhileWaiting() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    Task { @MainActor in await self?.checkForeignSession() }
                }
            }
            .store(in: &subscriptions)
        glucoseStorage.updatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.checkForeignSession()
                    await self?.tickWhileWaiting()
                }
            }
            .store(in: &subscriptions)
        broadcaster.register(SettingsObserver.self, observer: self)
        broadcaster.register(PreferencesObserver.self, observer: self)
        broadcaster.register(PumpSettingsObserver.self, observer: self)
        broadcaster.register(BasalProfileObserver.self, observer: self)
        broadcaster.register(InsulinSensitivitiesObserver.self, observer: self)
        broadcaster.register(CarbRatiosObserver.self, observer: self)
        broadcaster.register(BGTargetsObserver.self, observer: self)
        Task { @MainActor in
            // the home screen's banner warns while the iPhone's Bluetooth is off (the state manager is main-actor)
            self.apsManager.bluetoothManager?.addBluetoothObserver(self, queue: .main)
            await self.forwardCancellations()
            if UntetheredGate.isLocked {
                self.setError(String(localized: "Trio can't read its watch mode state until the iPhone is unlocked. The iPhone doesn't dose until then."))
            }
            if self.state.pumpReturnPending { await self.finishPumpReturn() }
            await self.uploadSpans()
            self.updateTimers()
        }
    }

    /// The saved state, locked at launch, opened: what launch resumes from it runs now (Claude Fable's review,
    /// 15 November).
    /// Messages from the watch that came while the saved state was locked, in the order they came.
    private var lockedMessages: [[String: Any]] = []
    private let lockedMessagesLock = NSLock()
    private static let lockedMessagesLimit = 200

    @MainActor private func stateOpened() async {
        // the message about the locked state lived in memory only; the state read now has its own
        wasIdle = state.session.isIdle
        // the kept messages first: a pump return waits on the pod, and an answer among them may decide it
        let kept = lockedMessagesLock.withLock { () -> [[String: Any]] in
            defer { lockedMessages.removeAll() }
            return lockedMessages
        }
        if !kept.isEmpty { debug(.watch, "Untethered: taking on \(kept.count) message(s) kept while the saved state was locked") }
        // one after the other and in full, so the pump return below is decided on what they say
        for payload in kept {
            guard let envelope = try? UntetheredEnvelope.decode(payload) else { continue }
            await handle(envelope, replyHandler: nil)
        }
        updateTimers()
        publish()
        if state.pumpReturnPending { await finishPumpReturn() }
    }

    var isWatchInCharge: Bool { !state.session.isIdle }
    /// For what the screens show: not while the phone only asks the watch about the pod after another controller
    /// used it (`isCheckingForeignSession`); dosing is held then all the same.
    var isWatchShownInCharge: Bool { isWatchInCharge && !state.session.isCheckingForeignSession }

    /// After the phone's own reading, clear of the watch's: the two read the same sensor, and the watch's link to it
    /// comes up around the reading and stays some 40 s.
    private static let watchWakeDelay: TimeInterval = 45
    /// The publisher also fires as the watch's own readings are stored: one wake per reading cycle at most.
    private static let watchWakeInterval: TimeInterval = 4 * 60
    private var lastWatchWake: Date?
    /// The newest of the watch's own readings that reached the phone.
    private var lastWatchReadingAt: Date?
    /// A watch whose own reading is at most this old reads its sensor fine and was awake for it.
    private static let watchReadsFineWithin: TimeInterval = 10 * 60

    /// While the watch has the pump, a small application context after each phone reading wakes the watch app, so it
    /// re-checks its sensor and sends its history even if a Bluetooth callback was lost.
    private func scheduleWatchWake() {
        guard isWatchInCharge else { return }
        sendPhoneReading()
        if tellWatchPhoneIsBack() { return }
        guard Date().timeIntervalSince(lastWatchWake ?? .distantPast) >= Self.watchWakeInterval else { return }
        lastWatchWake = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchWakeDelay) { [weak self] in
            guard let self, self.isWatchInCharge else { return }
            // a wake of the app's own is a draw on its background budget: only for a watch whose readings stopped
            if let watchReading = self.lastWatchReadingAt, Date().timeIntervalSince(watchReading) < Self.watchReadsFineWithin {
                return
            }
            let session = WCSession.default
            guard WCSession.isSupported(), session.activationState == .activated, session.isWatchAppInstalled else { return }
            try? session.updateApplicationContext([WatchMessageKeys.untetheredWake: Date().timeIntervalSince1970])
        }
    }

    /// The phone's own reading the watch was last told about.
    private var phoneBackToldFor: Date?

    /// The phone's own reading last sent to the watch.
    private var phoneReadingSentFor: Date?
    /// A reading older than this is no use to the watch's loop.
    private static let phoneReadingMaxAge: TimeInterval = 6 * 60

    /// While the watch has the pump, the phone's own reading goes to the watch the moment it is stored: a watch whose
    /// own sensor link fails loops on it instead of handing the pump back (5 November, 02:53 to 03:18: the phone read
    /// every 5 minutes, the watch nothing, and after 25 minutes without a loop it gave the pump back). As userInfo:
    /// queued, delivered at the watch app's next wake, and no draw on the complication transfers. The watch takes it
    /// only when it has no reading of its own for that cycle.
    private func sendPhoneReading() {
        guard let own = PhoneOwnGlucose.newest, own > (phoneReadingSentFor ?? .distantPast),
              Date().timeIntervalSince(own) < Self.phoneReadingMaxAge,
              let reading = PhoneOwnGlucose.newestReading
        else { return }
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isWatchAppInstalled else { return }
        phoneReadingSentFor = own
        // only the newest is of use
        for transfer in session.outstandingUserInfoTransfers
            where transfer.userInfo[WatchMessageKeys.untetheredPhoneReading] != nil
        {
            transfer.cancel()
        }
        session.transferUserInfo([
            WatchMessageKeys.untetheredPhoneReading: [
                "date": own.timeIntervalSince1970,
                "mgdl": reading.mgdl,
                "direction": reading.direction
            ]
        ])
    }

    /// A session the watch started without the phone goes back by itself once the phone reads the sensor again, but the
    /// watch only learns that from the phone: while it has the pump the phone sends no watch state, and a watch app in
    /// the background never sees the phone come in reach (2 November, 18:15 to 18:28). Told at once after each of the
    /// phone's own readings, not after the wake's delay: in the background the phone is suspended seconds after its
    /// reading, so the delayed word went out only when Trio was next opened on the phone, and as an application
    /// context it waited on the watch until Trio ran there (3 November, back and reading from 11:19, the watch heard
    /// at 11:34). A complication transfer wakes the watch app in the background.
    private func tellWatchPhoneIsBack() -> Bool {
        guard state.session.startedWithoutPhone, let own = PhoneOwnGlucose.newest,
              Date().timeIntervalSince(own) < Self.watchReadsFineWithin
        else { return false }
        guard own > (phoneBackToldFor ?? .distantPast) else { return true }
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isWatchAppInstalled else { return true }
        phoneBackToldFor = own
        let context: [String: Any] = [
            WatchMessageKeys.untetheredWake: Date().timeIntervalSince1970,
            WatchMessageKeys.phoneOwnGlucoseDate: own.timeIntervalSince1970
        ]
        try? session.updateApplicationContext(context)
        if session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0 {
            session.transferCurrentComplicationUserInfo(context)
            debug(
                .watch,
                "Untethered: the phone reads the sensor again, told the watch now (complication transfer, \(session.remainingComplicationUserInfoTransfers) left today)"
            )
        } else {
            debug(.watch, "Untethered: the phone reads the sensor again, telling the watch at its next wake (no complication on the watch face)")
        }
        return true
    }

    // MARK: - Standing grant

    /// Changes come in bursts (a loop stores its temp, a meal its carbs and bolus): one grant after them.
    private static let standingGrantFloor: TimeInterval = 30
    /// Sent at least this often, so its glucose stays young enough to start from.
    private static let standingGrantInterval: TimeInterval = 30 * 60
    private static let standingGrantMarker = "untetheredStandingGrant"
    private var standingGrantTask: Task<Void, Never>?
    private var standingGrantSentAt: Date?
    private var standingGrantFingerprint: Int?
    /// The settings changed: sent whatever the fingerprint says.
    private var standingGrantSettingsChanged = false

    /// The observers call from their own queues.
    private func scheduleStandingGrant(settingsChanged: Bool = false, immediately: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.scheduleStandingGrant(settingsChanged: settingsChanged, immediately: immediately) }
            return
        }
        if settingsChanged { standingGrantSettingsChanged = true }
        if immediately {
            // the burst's grant comes with this one
            standingGrantTask?.cancel()
        } else if standingGrantTask != nil {
            return
        }
        standingGrantTask = Task { @MainActor [weak self] in
            if !immediately {
                try? await Task.sleep(nanoseconds: UInt64(Self.standingGrantFloor * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            await self?.sendStandingGrant()
            self?.standingGrantTask = nil
        }
    }

    /// While the phone has the pump, the grant the watch starts from without it (LoopKit/Loop#2545): issued expired,
    /// so it never starts a session on its own, and resent as the settings, carbs or doses change. Only the newest
    /// stays queued.
    @MainActor private func sendStandingGrant() async {
        let session = WCSession.default
        // only with the mode on and the start without the phone chosen in Settings › Apple Watch: without a copy
        // the watch can't start on its own
        guard isEnabled, settingsManager.settings.allowUntetheredStartWithoutPhoneWatch,
              UntetheredGate.phoneMayDose, WCSession.isSupported(), session.activationState == .activated,
              session.isWatchAppInstalled, let control = apsManager.pumpManager as? ExclusiveDeviceControl,
              !control.isControlReleased
        else { return }
        // The watch may start from this grant while the phone still holds the pod (phone off or out of reach). From
        // now on the phone refuses to command the pod if another controller used it since. Taking control back
        // clears this.
        if control.refusesForeignSessionsSince == nil {
            control.refusesForeignSessionsSince = Date()
        }
        guard let grant = try? await makeGrant(linkedOverrideID: nil, leaseLength: 0) else { return }
        // what a start would miss most: carbs, boluses and adjustments; temps and readings wait for the interval
        let encoder = JSONEncoder()
        var hasher = Hasher()
        for part in [
            try? encoder.encode(grant.carbs), try? encoder.encode(grant.tempTargets),
            try? encoder.encode(grant.activeOverride),
            try? encoder.encode(grant.tddPumpHistory.filter { $0.type == .bolus }.map(\.id))
        ] {
            hasher.combine(part)
        }
        let fingerprint = hasher.finalize()
        let now = Date()
        // a newer grant took over while this one was being made
        guard !Task.isCancelled,
              standingGrantSettingsChanged || fingerprint != standingGrantFingerprint
              || now.timeIntervalSince(standingGrantSentAt ?? .distantPast) >= Self.standingGrantInterval,
              UntetheredGate.phoneMayDose,
              var payload = try? UntetheredEnvelope(epoch: state.session.epoch, message: .standingGrant(grant, issuedAt: now))
              .payload()
        else { return }
        payload[Self.standingGrantMarker] = true
        for transfer in session.outstandingUserInfoTransfers where transfer.userInfo[Self.standingGrantMarker] != nil {
            transfer.cancel()
        }
        session.transferUserInfo(payload)
        standingGrantSettingsChanged = false
        standingGrantFingerprint = fingerprint
        standingGrantSentAt = now
        debug(.watch, "Untethered: standing grant sent")
    }

    /// The start reads the pump before it offers it: the toggle shows a spinner meanwhile.
    @Published private(set) var isCheckingDevices = false
    /// A take-back reaching for the pod before it tells the watch.
    @Published private(set) var isReachingPod = false
    /// Short: a pod in reach answers within a second or two, and a refusal costs one more tap.
    private static let takeBackLinkLimit: TimeInterval = 5
    /// Take-back tries after a watch's request, and the pause between them.
    private static let handbackRequestTries = 3
    private static let handbackRequestRetryDelay: TimeInterval = 20
    /// This return's audit ran and found no insulin that no record explains. Only then is a refused bolus tried again.
    private var auditFoundNoGap = false
    /// The returned pump has answered: what is left is the watch's last records and the audit.
    @Published private(set) var pumpReturnAnswered = false
    /// Sends of the current start's offer that didn't get through, for the progress the screens show.
    @Published private(set) var prepareAttempts = 0
    /// The watch's newest bolus while it still delivers, from its records: a hand-back says it goes on on the pod
    /// (9 November: a 2 U bolus from the watch, End Untethered Mode, and nothing seemed to happen).
    @Published private(set) var watchBolus: WatchBolusInFlight?

    struct WatchBolusInFlight: Equatable {
        let id: String
        let units: Double
        let start: Date
        let end: Date

        /// What is left now, as the pod delivers it evenly; nil once it is over.
        func left(at now: Date = Date()) -> (units: Double, until: Date)? {
            guard end > now, end > start else { return nil }
            let fraction = min(1, end.timeIntervalSince(now) / end.timeIntervalSince(start))
            return (units * fraction, end)
        }
    }

    /// From each pump event the watch sends: a bolus still delivering is noted, its final version clears it.
    @MainActor private func noteWatchDose(_ dose: DoseEntry?) {
        guard let dose, dose.type == .bolus, let id = dose.syncIdentifier else { return }
        if dose.isMutable, dose.endDate > Date() {
            watchBolus = WatchBolusInFlight(
                id: id, units: dose.programmedUnits, start: dose.startDate, end: dose.endDate
            )
        } else if watchBolus?.id == id {
            watchBolus = nil
        }
    }

    /// What the watch's running bolus has left, for the hand-back.
    var watchBolusLeft: (units: Double, until: Date)? { watchBolus?.left() }
    /// How long the start waits for the pump to answer.
    private static let pumpCheckTimeout: TimeInterval = 30

    // MARK: - User actions

    /// - Returns: why the start was refused, nil when it went on to the watch
    @discardableResult @MainActor func start(linkedOverrideID: String? = nil) async -> String? {
        guard !UntetheredGate.isLocked else {
            return String(localized: "Trio can't read its watch mode state until the iPhone is unlocked. The iPhone doesn't dose until then.")
        }
        guard state.session.isIdle, !state.pumpReturnPending else {
            return String(localized: "The phone is still taking the pump back from the last session.")
        }
        setError(nil)
        // about the last session; this one is judged on its own
        UntetheredGate.update {
            $0.auditFinding = nil
            $0.watchPump = nil
        }
        isCheckingDevices = true
        defer { isCheckingDevices = false }
        do {
            try preflight()
            // a pump the phone can't reach now is one the watch can't reach after the hand-over either
            guard await pumpAnswers() else {
                throw UntetheredError.unavailable(
                    String(localized: "The pump doesn't answer. Keep the phone close to the pod and try again.")
                )
            }
            let grant = try await makeGrant(linkedOverrideID: linkedOverrideID)
            prepareAttempts = 0
            await apply(.start(grant))
            return nil
        } catch {
            setError(error.localizedDescription)
            return error.localizedDescription
        }
    }

    @MainActor func end() async {
        if let left = watchBolusLeft {
            info(
                .watch,
                "Untethered: hand-back asked while the watch's bolus runs (\(String(format: "%.2f", left.units)) U left until \(left.until)): it goes on on the pod"
            )
        }
        await apply(.end)
        // a watch app the system has suspended isn't reachable, and the request (repeated every 30 s) only got through
        // once Trio was in front on the watch (1 November, 11:44 to 11:45:47). Queued as well, it reaches the watch
        // at its next wake, e.g. the next loop.
        let session = WCSession.default
        guard state.session.phase == .ending, WCSession.isSupported(), session.activationState == .activated,
              !session.isReachable,
              let payload = try? UntetheredEnvelope(epoch: state.session.epoch, message: .endRequest).payload()
        else { return }
        session.transferUserInfo(payload)
        debug(.watch, "Untethered: hand-back asked with the watch out of reach, queued for its next wake")
    }

    /// Reaches for the pod before the watch is told to stop: a phone that can't reach it leaves the watch dosing,
    /// instead of taking a pump that then neither side doses.
    @MainActor func forceTakeBack() async {
        // the state locked: whether the watch has the pump is unknown here, and the take-back would save over it
        guard !UntetheredGate.isLocked else {
            setError(String(localized: "Trio can't read its watch mode state until the iPhone is unlocked. The iPhone doesn't dose until then."))
            return
        }
        guard let control = apsManager.pumpManager as? ExclusiveDeviceControl else {
            await apply(.forceTakeBack)
            return
        }
        // Without Bluetooth the phone can't reach the pod, however long it tries; the watch's messages may still come
        // over another way (30 October, 16:34 to 16:57: eight take-backs refused with Bluetooth off).
        if isBluetoothOff {
            debug(.watch, "Untethered: take-back refused, the iPhone's Bluetooth is off")
            setError(String(localized: "The iPhone's Bluetooth is off. Turn it on to take the pump back; the watch keeps running."))
            return
        }
        isReachingPod = true
        defer { isReachingPod = false }
        setError(nil)
        control.takeControl()
        let deadline = Date().addingTimeInterval(Self.takeBackLinkLimit)
        while !control.isControlReady, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard control.isControlReady else {
            control.releaseControl()
            debug(.watch, "Untethered: take-back refused, no pod link after \(Int(Self.takeBackLinkLimit)) s")
            setError(String(
                localized: "Couldn't reach the pod. The watch keeps running; bring the phone close to the pod and try again."
            ))
            return
        }
        debug(.watch, "Untethered: take-back, pod link up — telling the watch to stop")
        await apply(.forceTakeBack)
    }

    /// The iPhone's Bluetooth is off, as in flight mode: no pod is in reach.
    @MainActor var isBluetoothOff: Bool {
        apsManager.bluetoothManager?.bluetoothState == .poweredOff
    }

    @MainActor func acknowledgeAuditFinding() {
        UntetheredGate.update { $0.auditFinding = nil }
        publish()
    }

    // MARK: - From the watch

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

    /// `payload` holds an `UntetheredEnvelope`. Every path calls `replyHandler` when there is one.
    func receive(_ payload: [String: Any], replyHandler: (([String: Any]) -> Void)?) {
        // the saved state locked: its epoch and phase are unknown, and a message taken on now (the watch holding the
        // pump, say) would release the pod beside a state that, once read, says otherwise. Kept and taken on once the
        // state opens: some the watch sends only once, as its release (Ponytail's review, 15 November).
        if UntetheredGate.isLocked {
            // over the limit, record batches give way first: the watch sends them again, its release it doesn't
            let isRecords: Bool = {
                guard let envelope = try? UntetheredEnvelope.decode(payload), case .records = envelope.message else { return false }
                return true
            }()
            let kept = lockedMessagesLock.withLock { () -> Bool in
                if lockedMessages.count >= Self.lockedMessagesLimit {
                    guard !isRecords, let index = lockedMessages.firstIndex(where: { held in
                        guard let envelope = try? UntetheredEnvelope.decode(held), case .records = envelope.message else { return false }
                        return true
                    }) else { return false }
                    lockedMessages.remove(at: index)
                }
                lockedMessages.append(payload)
                return true
            }
            debug(.watch, "Untethered: message from the watch \(kept ? "kept for later" : "left (too many kept)"), the saved state is locked")
            replyHandler?([:])
            return
        }
        guard let envelope = try? UntetheredEnvelope.decode(payload) else {
            warning(.watch, "Untethered: unreadable message from the watch")
            replyHandler?([:])
            return
        }
        Task { @MainActor in await self.handle(envelope, replyHandler: replyHandler) }
    }

    /// One message from the watch, taken on in full; awaited where the order matters (the messages kept while the
    /// saved state was locked, Claude Fable's review, 15 November).
    @MainActor private func handle(_ envelope: UntetheredEnvelope, replyHandler: (([String: Any]) -> Void)?) async {
        // a session the watch started without the phone: taken on before its records are stored, which would
        // otherwise be confirmed and dropped as a finished session's. Queued messages arrive in order, so its
        // end comes after.
        if self.state.session.isIdle || self.state.session.phase == .starting,
           envelope.epoch > self.state.session.epoch
        {
            let unknownWatchSince = self.state.session.unknownWatchSince
            defer {
                if let unknownWatchSince, self.state.session.epoch == envelope.epoch {
                    Task { await self.adoptProvisionalAudit(of: unknownWatchSince, epoch: envelope.epoch) }
                }
            }
            switch envelope.message {
            case let .statusReport(holding: .some(status)),
                 let .takeoverComplete(status):
                await self.apply(.watchHoldsPump(epoch: envelope.epoch, status: status))
            case .statusReport(holding: nil) where self.state.session.phase == .starting:
                await self.apply(.watchHoldsPump(epoch: envelope.epoch, status: nil))
            // records alone don't hand the pump over: the watch is asked (Ponytail's review, 15 November). Only
            // while idle: during the ownership check (`.starting`) the answer to it decides.
            case .records where self.state.session.isIdle:
                await self.apply(.watchRecordsSeen(epoch: envelope.epoch))
            // a session the phone never knew is over: its later messages then belong to an ended session
            case .released, .takeoverFailed:
                await self.apply(.watchSessionEnded(epoch: envelope.epoch))
            default: break
            }
        }
        switch envelope.message {
        case let .records(records):
            let stored = await self.ingestInOrder(records, epoch: envelope.epoch)
            // acknowledged as soon as stored, so the watch's backlog stays small while it loops
            if let replyHandler,
               let payload = try? UntetheredEnvelope(epoch: envelope.epoch, message: .recordsStored(stored)).payload()
            {
                replyHandler(payload)
            } else {
                replyHandler?([:])
                self.send(.recordsStored(stored), epoch: envelope.epoch)
            }
        case .syncDone:
            replyHandler?([:])
            await self.finishSync(epoch: envelope.epoch)
        case .standingGrantRequest:
            replyHandler?([:])
            // a copy for another build would start a session the two can't share
            guard UntetheredVersion.mismatch(watch: envelope.appVersion) == nil else { return }
            // whatever the fingerprint says: the watch has none
            self.scheduleStandingGrant(settingsChanged: true, immediately: true)
        case .startRequest:
            replyHandler?([:])
            // the watch asks again when its request seemed lost: one already on its way here is not refused
            if self.isCheckingDevices || self.state.session.phase == .preparing || self.state.session.phase == .starting {
                debug(.watch, "Untethered: the watch asked again for the start already under way")
                return
            }
            // a watch app watchOS hasn't updated yet (or an older phone): no hand-over between two builds
            if let reason = UntetheredVersion.mismatch(watch: envelope.appVersion) {
                warning(.watch, "Untethered: start refused, \(reason)")
                self.send(.startRefused(reason: reason), epoch: envelope.epoch)
                return
            }
            if let reason = await self.start() {
                self.send(.startRefused(reason: reason), epoch: envelope.epoch)
            }
        case let .handbackRequested(minutes):
            replyHandler?([:])
            guard self.state.session.phase == .active, envelope.epoch == self.state.session.epoch else { return }
            // the fallback's hand-back, once the phone is back, comes the same way with no minutes: it's no stall
            if minutes > 0 {
                warning(.watch, "Untethered: the watch hasn't reached the pod for \(minutes) min and asks the phone to take it back")
            } else {
                info(.watch, "Untethered: the watch hands the pump back, the phone is in reach again")
            }
            // as Take Back the Pump Now: the phone reaches for the pod first, and leaves the watch dosing if it can't.
            // The pod may still be busy with the watch's last command: a few more tries, a little apart, rather
            // than waiting for the watch's next request (24 October: refused at 13:55:56, taken back by hand 14:07).
            for attempt in 1 ... Self.handbackRequestTries {
                await self.forceTakeBack()
                // trying again in 20 s won't turn Bluetooth on: the watch asks again later
                guard !self.isBluetoothOff else { break }
                guard self.state.session.phase == .active, envelope.epoch == self.state.session.epoch,
                      attempt < Self.handbackRequestTries
                else { break }
                debug(.watch, "Untethered: the pod was busy, trying again in \(Int(Self.handbackRequestRetryDelay)) s (\(attempt) of \(Self.handbackRequestTries))")
                self.setError(String(localized: "The pod is still busy with the watch. The phone tries again in a moment; keep it near the pod."))
                try? await Task.sleep(nanoseconds: UInt64(Self.handbackRequestRetryDelay * 1_000_000_000))
                guard self.state.session.phase == .active, envelope.epoch == self.state.session.epoch else { break }
            }
        case let .remoteTreatmentResult(id, delivered, message):
            replyHandler?([:])
            self.answerRemoteTreatment(id, delivered ? .delivered(message) : .refused(message))
        case let .dosingModeChanged(mode):
            replyHandler?([:])
            guard envelope.epoch >= self.state.session.epoch else { return }
            var settings = self.settingsManager.settings
            guard settings.dosingMode != mode else { return }
            settings.dosingMode = mode
            self.settingsManager.settings = settings
        default:
            await self.apply(.received(envelope.message, epoch: envelope.epoch), reply: replyHandler)
        }
    }

    @MainActor func reachabilityChanged() {
        guard WCSession.default.isReachable else { return }
        switch state.session.phase {
        case .ending: send(.endRequest, epoch: state.session.epoch)
        case .starting where state.session.statusQueried: send(.statusQuery, epoch: state.session.epoch)
        default: break
        }
        for epoch in state.applied.keys {
            requestSync(epoch: epoch)
        }
    }

    // MARK: - State machine

    @MainActor private func apply(_ event: UntetheredSession.PhoneEvent, reply: (([String: Any]) -> Void)? = nil) async {
        let now = Date()
        // a take-back that ends the check of a foreign session with the watch's "not holding" for the phone's own
        // session: the watch only looked at the pod. Not a newer epoch's answer, a release, a failed takeover or a
        // forced take-back: in those the watch may have dosed and replaced the phone's temp (Claude Fable's review,
        // 14 November).
        let afterLook: Bool = {
            guard state.session.isCheckingForeignSession,
                  case let .received(.statusReport(holding: nil), messageEpoch) = event
            else { return false }
            return messageEpoch == state.session.epoch
        }()
        let (effects, spanEnded, spanStarted) = UntetheredGate.update { state -> ([UntetheredSession.Effect], Bool, Date?) in
            let held = state.session.phase == .active || state.session.phase == .ending
            let effects = state.session.phone(event, now: now)
            let holds = state.session.phase == .active || state.session.phase == .ending
            var ended = false
            var started: Date?
            if !held, holds {
                let start = state.session.startStatus?.date ?? now
                state.spans.append(UntetheredSpan(start: start, end: nil, uploaded: false))
                started = start
            } else if held, !holds, let last = state.spans.indices.last, state.spans[last].end == nil {
                state.spans[last].end = now
                ended = true
            }
            state.spans.removeAll { ($0.end ?? now) < now.addingTimeInterval(-3 * 24 * 60 * 60) }
            return (effects, ended, started)
        }
        if spanEnded { Task { await self.uploadSpans() } }
        // followers (LoopFollow) show it as running from now on; the end replaces this entry with its duration
        if let spanStarted { Task { await self.nightscoutManager.uploadUntetheredSession(from: spanStarted, to: nil) } }
        let epoch = UntetheredGate.state.session.epoch
        publish()
        var reply = reply
        func deliver(_ message: UntetheredMessage) {
            if let replyHandler = reply, let payload = try? UntetheredEnvelope(epoch: epoch, message: message).payload() {
                replyHandler(payload)
                reply = nil
            } else {
                send(message, epoch: epoch)
            }
        }
        for effect in effects {
            switch effect {
            case let .send(message):
                deliver(message)
            case .commit:
                var handover = await releasePump()
                // the deadline the session set at the watch's answer, the same for both sides
                handover.leaseExpiresAt = UntetheredGate.state.session.leaseExpiresAt
                handover.committedAt = Date()
                if let lease = handover.leaseExpiresAt {
                    debug(.watch, "Untethered: commit sent, takeover deadline in \(Int(lease.timeIntervalSinceNow)) s")
                }
                deliver(.commit(handover))
            case .takePump:
                takePump(keepingPhoneDoses: afterLook)
            case .reconcile:
                UntetheredGate.update { $0.applied[epoch] = $0.applied[epoch] ?? [:] }
                requestSync(epoch: epoch)
            case let .failed(reason):
                setError(reason)
            case .releasePump:
                // the watch started without the phone and has the pod: the phone stops reaching for it
                for _ in 0 ..< 60 where apsManager.isLooping.value {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                (apsManager.pumpManager as? ExclusiveDeviceControl)?.releaseControl()
                // what the phone started after the watch's copy stays the phone's
                _ = try? await pumpHistoryStorage.keepInFlightDoses(startedAfter: state.session.startStatus?.copyAsOf)
                UntetheredGate.update { $0.pumpReturnPending = false }
                setError(String(localized: "The watch started without the phone; the phone stopped dosing."))
            case .handback,
                 .takeover:
                break
            }
        }
        reply?([:])
        publish()
        updateTimers()
    }

    @MainActor private func publish() {
        objectWillChange.send()
        let isIdle = state.session.isIdle
        if isIdle != wasIdle {
            wasIdle = isIdle
            Foundation.NotificationCenter.default.post(name: .untetheredSessionDidChange, object: nil)
        }
    }

    @MainActor private func setError(_ message: String?) {
        if let message { warning(.watch, "Untethered: \(message)") }
        UntetheredGate.update { $0.lastError = message }
        publish()
    }

    @MainActor private func updateTimers() {
        let phase = state.session.phase
        if phase == .preparing || phase == .starting {
            if ticker == nil {
                ticker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    Task { await self?.apply(.tick) }
                }
            }
        } else {
            ticker?.invalidate()
            ticker = nil
        }
        // The ownership question goes out from a background wake (a reading, a refused pod command), and the watch's
        // answer, queued when the phone is out of reach for that moment, is delivered only while Trio runs: on
        // 9 November (second tester) Trio went back to sleep 4 s after asking at 10:40:03 and held its dosing until
        // it was opened at 10:48. Kept running for the seconds the system gives, which an answer usually needs.
        if state.session.isCheckingForeignSession {
            if answerWaitTask == .invalid {
                answerWaitTask = UIApplication.shared.beginBackgroundTask(withName: "Untethered ownership answer") {
                    [weak self] in self?.endAnswerWait()
                }
            }
        } else {
            endAnswerWait()
        }
        if phase == .ending {
            // repeated until the watch hands back; it may be reachable without a reachability change
            if endRequestTimer == nil {
                send(.endRequest, epoch: state.session.epoch)
                endRequestTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.send(.endRequest, epoch: self.state.session.epoch)
                }
            }
        } else {
            endRequestTimer?.invalidate()
            endRequestTimer = nil
        }
        Task { await scheduleLinkedOverrideCheck() }
    }

    @MainActor private func endAnswerWait() {
        guard answerWaitTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(answerWaitTask)
        answerWaitTask = .invalid
    }

    /// The ticker is a timer, and a timer stands still while Trio is in the background: the wait for the watch's answer
    /// ran 7 minutes instead of 3 (6 November, 07:36 to 07:43, until Trio was opened). Each reading and each return to
    /// the front gives it its tick as well.
    @MainActor private func tickWhileWaiting() async {
        let phase = state.session.phase
        guard phase == .preparing || phase == .starting else { return }
        await apply(.tick)
    }

    /// A refused pod command exposes the watch's newer EAP session before WatchConnectivity
    /// delivers its ownership message. Ask the watch while dosing stays held; if it cannot answer,
    /// the state machine takes the pod back and audits its delivery history.
    @MainActor private func checkForeignSession() async {
        guard state.session.isIdle,
              let control = apsManager.pumpManager as? ExclusiveDeviceControl,
              let since = control.refusesForeignSessionsSince,
              let foreignAt = control.lastForeignSessionAt, foreignAt > since,
              foreignAt > (lastHandledForeignSessionAt ?? .distantPast)
        else { return }
        lastHandledForeignSessionAt = foreignAt
        // a phone that still holds the pod lets go of it, so the watch reaches it
        if !control.isControlReleased { control.releaseControl() }
        debug(.watch, "Untethered: pod reports a foreign controller session; querying watch ownership")
        let previous = state.podReading
        let currentPod = (apsManager.pumpManager as? OmniPumpManager)?.state.podState?.activatedAt
        let startStatus = previous.flatMap { reading in
            reading.pod == currentPod
                ? UntetheredPodStatus(date: reading.at, deliveredUnits: reading.units, reservoir: nil)
                : nil
        }
        await apply(.foreignSessionDetected(startStatus))
    }

    // MARK: - Transport

    /// The commit tells the watch to take the released pump; one lost in a reachability flicker left the watch waiting
    /// and the phone taking the pump back after the lease (2026-10-20 06:20). Sent again every few seconds while the
    /// phone waits for the takeover, and never in the lease's last 30 s, so a late one can't meet the phone's take-back.
    private func retryCommit(_ message: UntetheredMessage, epoch: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.state.session.phase == .starting, self.state.session.epoch == epoch,
                  let lease = self.state.session.leaseExpiresAt, Date() < lease.addingTimeInterval(-30)
            else { return }
            debug(.watch, "Untethered: sending the commit again")
            self.send(message, epoch: epoch)
        }
    }

    /// A start's `prepare` that didn't get through goes again every few seconds until the watch answers or the start's
    /// time is up (`UntetheredSession.prepareTimeout`): on 25 October one "not reachable" or "transfer timed out" ended
    /// each start at once, and it took four tries. The watch answers a repeated prepare the same way.
    private func retryPrepare(_ message: UntetheredMessage, epoch: Int, why: String) {
        guard state.session.phase == .preparing, state.session.epoch == epoch else { return }
        if let deadline = state.session.prepareDeadline, Date() > deadline.addingTimeInterval(-Self.prepareRetryDelay) {
            // the tick ends the start with "the watch did not answer"
            return
        }
        prepareAttempts += 1
        debug(.watch, "Untethered: the start didn't reach the watch (\(why)), trying again (\(prepareAttempts + 1). try)")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.prepareRetryDelay) { [weak self] in
            guard let self, self.state.session.phase == .preparing, self.state.session.epoch == epoch else { return }
            self.send(message, epoch: epoch)
        }
    }

    private static let prepareRetryDelay: TimeInterval = 4

    private func send(_ message: UntetheredMessage, epoch: Int) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let payload = try? UntetheredEnvelope(epoch: epoch, message: message).payload()
        else { return }
        let session = WCSession.default

        switch message {
        case .adjustmentCancelled,
             .dosingModeChanged,
             .remoteAdjustment,
             .remoteTreatment,
             .revoke,
             .statusQuery:
            // queued as well: the watch must hear it whenever it comes back
            session.transferUserInfo(payload)
            // The ownership question after a foreign pod session: the phone doesn't dose until it has the answer, and
            // a queued message waits for the watch's next wake (2 November, 19:49 to 19:53: the watch had only looked
            // at the pod, and the phone's SMB waited 4.5 minutes). With Trio on the watch face, a complication
            // transfer wakes the watch app at once; rare, so well within its daily budget.
            if case .statusQuery = message, session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0 {
                session.transferCurrentComplicationUserInfo(payload)
                debug(
                    .watch,
                    "Untethered: ownership question also sent as a complication transfer (\(session.remainingComplicationUserInfoTransfers) left today)"
                )
            }
        case .recordsStored:
            session.transferUserInfo(payload)
            return
        default: break
        }
        guard session.isReachable else {
            if case .prepare = message {
                DispatchQueue.main.async { self.retryPrepare(message, epoch: epoch, why: "not reachable") }
            }
            if case .commit = message { retryCommit(message, epoch: epoch) }
            return
        }
        let replyHandler: ([String: Any]) -> Void = { [weak self] reply in
            guard reply[UntetheredEnvelope.key] != nil else { return }
            self?.receive(reply, replyHandler: nil)
        }
        var failed = false
        let errorHandler: (Error) -> Void = { [weak self] error in
            warning(.watch, "Untethered: sending failed: \(error.localizedDescription)")
            if case .commit = message, !failed {
                failed = true
                DispatchQueue.main.async { self?.retryCommit(message, epoch: epoch) }
                return
            }
            guard case .prepare = message, !failed else { return }
            failed = true
            DispatchQueue.main.async { self?.retryPrepare(message, epoch: epoch, why: error.localizedDescription) }
        }
        for part in UntetheredChunks.split(payload) ?? [payload] {
            session.sendMessage(part, replyHandler: replyHandler, errorHandler: errorHandler)
        }
    }

    // MARK: - Remote commands

    enum RemoteTreatmentAnswer {
        case delivered(String)
        case refused(String)
        /// Nothing heard within `remoteTreatmentWait`: the watch may still act on it until the command is 10 minutes old.
        case noAnswer
    }

    /// Keyed by the treatment's id: the first answer ends the wait (`forwardRemoteTreatment`), one after it goes to
    /// `late`. Main queue only.
    private var remoteTreatmentWaits: [UUID: CheckedContinuation<RemoteTreatmentAnswer, Never>] = [:]
    private var remoteTreatmentLate: [UUID: (RemoteTreatmentAnswer) -> Void] = [:]
    /// Within the ~30 s iOS gives the app for a push in the background. A later answer wakes the app as it arrives.
    private static let remoteTreatmentWait: TimeInterval = 25

    /// Passes a remote bolus or meal to the watch, which has the pump, and waits for its answer. Sent interactively and
    /// queued: a watch away from the phone (on Wi-Fi or cellular) may get the queued copy through Apple's relay later,
    /// and refuses it once the command is 10 minutes old. An answer after the wait goes to `late`.
    @MainActor func forwardRemoteTreatment(
        _ treatment: UntetheredRemoteTreatment,
        late: @escaping (RemoteTreatmentAnswer) -> Void
    ) async -> RemoteTreatmentAnswer {
        await forwardRemote(.remoteTreatment(treatment), id: treatment.id, summary: treatment.summary, late: late)
    }

    /// The same for a remote override or temp target.
    @MainActor func forwardRemoteAdjustment(
        _ adjustment: UntetheredRemoteAdjustment,
        late: @escaping (RemoteTreatmentAnswer) -> Void
    ) async -> RemoteTreatmentAnswer {
        await forwardRemote(.remoteAdjustment(adjustment), id: adjustment.id, summary: adjustment.summary, late: late)
    }

    @MainActor private func forwardRemote(
        _ message: UntetheredMessage,
        id: UUID,
        summary: String,
        late: @escaping (RemoteTreatmentAnswer) -> Void
    ) async -> RemoteTreatmentAnswer {
        guard state.session.phase == .active else {
            return .refused(String(localized: "Command rejected: the pump is changing hands between the iPhone and the Apple Watch. Try again in a few minutes."))
        }
        // the same command a second time (e.g. its push delivered twice): the first one's wait reports it
        guard remoteTreatmentWaits[id] == nil, remoteTreatmentLate[id] == nil else { return .delivered("") }
        let epoch = state.session.epoch
        info(.remote, "Untethered: passing a remote command to the watch: \(summary)")
        remoteTreatmentLate[id] = late
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.remoteTreatmentWait * 1_000_000_000))
            self.answerRemoteTreatment(id, .noAnswer)
            // until the watch would refuse the command anyway
            try? await Task.sleep(nanoseconds: UInt64(UntetheredRemoteTreatment.window * 1_000_000_000))
            self.remoteTreatmentLate[id] = nil
        }
        return await withCheckedContinuation { continuation in
            remoteTreatmentWaits[id] = continuation
            send(message, epoch: epoch)
        }
    }

    @MainActor private func answerRemoteTreatment(_ id: UUID, _ answer: RemoteTreatmentAnswer) {
        if let wait = remoteTreatmentWaits.removeValue(forKey: id) {
            wait.resume(returning: answer)
            return
        }
        if case .noAnswer = answer { return }
        if let late = remoteTreatmentLate.removeValue(forKey: id) {
            late(answer)
        } else {
            debug(.remote, "Untethered: the watch's answer to a remote command came after its wait ended")
        }
    }


    // MARK: - Starting

    /// Untethered mode offered at all (Settings › Apple Watch).
    var isEnabled: Bool { settingsManager.settings.untetheredModeWatch }
    /// Only then can another controller dose this pod unseen.
    private static func allowsStartWithoutPhone(_ settings: TrioSettings) -> Bool {
        settings.untetheredModeWatch && settings.allowUntetheredStartWithoutPhoneWatch
    }

    /// The home screen is tinted while the watch has the pump (Settings › Apple Watch).
    var tintsHomeScreen: Bool { isWatchInCharge && settingsManager.settings.untetheredTintHomeWatch }

    @MainActor private func preflight() throws {
        guard isEnabled else {
            throw UntetheredError.unavailable(String(localized: "Untethered mode is off in Settings › Apple Watch."))
        }
        guard WCSession.isSupported(), WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else {
            throw UntetheredError.unavailable(String(localized: "Trio is not installed on a paired Apple Watch."))
        }
        // not reachable this moment is no reason to refuse: the start offers itself for half a minute (`retryPrepare`)
        guard let pump = apsManager.pumpManager else {
            throw UntetheredError.unavailable(String(localized: "No pump is connected."))
        }
        guard pump is ExclusiveDeviceControl, pump is PumpDeliveryOdometer else {
            throw UntetheredError.unavailable(
                String(
                    localized: "\(pump.localizedTitle) can't be handed to the watch. Untethered mode supports Omnipod DASH and Omnipod 5."
                )
            )
        }
        guard let cgm = fetchGlucoseManager.cgmManager, cgm is DeviceConfigurationSharing else {
            throw UntetheredError.unavailable(
                String(localized: "This CGM can't be read by the watch. Untethered mode supports Dexcom G7.")
            )
        }
        // the watch reads the same sensor; it links only around each reading, so its last contact proves nothing
        guard cgm.cgmManagerStatus.hasValidSensorSession else {
            throw UntetheredError.unavailable(String(localized: "The CGM has no active sensor."))
        }
        let status = pump.status
        guard case .noBolus = status.bolusState else {
            throw UntetheredError.unavailable(String(localized: "Wait for the bolus to finish."))
        }
        guard !status.deliveryIsUncertain else {
            throw UntetheredError
                .unavailable(String(localized: "The pump's delivery is uncertain. Resolve it on the phone first."))
        }
        guard !apsManager.isManualTempBasal else {
            throw UntetheredError.unavailable(String(localized: "Cancel the manual temp basal first."))
        }
        if let inoperable = pump.localizedInoperableDescription {
            throw UntetheredError.unavailable(inoperable)
        }
    }

    /// A live read of the pump's delivered total, or false when it doesn't answer within the timeout.
    @MainActor private func pumpAnswers() async -> Bool {
        guard let odometer = apsManager.pumpManager as? PumpDeliveryOdometer else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // whichever comes first answers; the other finds it answered
            let lock = NSLock()
            var answered = false
            func answer(_ result: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !answered else { return }
                answered = true
                continuation.resume(returning: result)
            }
            Task { answer(await odometer.refreshDeliveredUnits()) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pumpCheckTimeout) { answer(false) }
        }
    }

    private func makeGrant(
        linkedOverrideID: String?,
        leaseLength: TimeInterval = UntetheredPhoneManager.leaseLength
    ) async throws -> UntetheredGrant {
        guard let pump = apsManager.pumpManager as? ExclusiveDeviceControl,
              let cgm = fetchGlucoseManager.cgmManager as? DeviceConfigurationSharing
        else { throw UntetheredError.unavailable(String(localized: "The pump or CGM can't be handed to the watch.")) }

        let now = Date()
        let settings = settingsManager.settings
        let preferences = settingsManager.preferences
        // raw readings travel; the watch smooths them as the phone does and syncs the originals back
        let glucose = try await glucoseStorage.getGlucoseForAlgorithm(shouldSmoothGlucose: false, fetchHours: 24)
        var smoothedGlucose: [String: Decimal] = [:]
        if settings.smoothGlucose {
            for reading in try await glucoseStorage.getGlucoseForAlgorithm(shouldSmoothGlucose: true, fetchHours: 24) {
                smoothedGlucose[reading.id] = (reading.sgv ?? reading.glucose).map { Decimal($0) }
            }
        }
        guard let newest = glucose.map(\.dateString).max(), now.timeIntervalSince(newest) < Self.maxGlucoseAge else {
            throw UntetheredError.unavailable(String(localized: "There is no recent glucose reading."))
        }

        let context = CoreDataStack.shared.newTaskContext()
        context.name = "untetheredGrant"
        let (tdd, tddRows, activeOverride, overridePresets, tempTargetPresets) = try await context.perform {
            let tdd = try self.openAPS.tddSummary(now: now, on: context)
            let tddRequest = TDDStored.fetchRequest() as NSFetchRequest<TDDStored>
            // zeros too: the stored weighted average counts them, the algorithm's averages don't
            tddRequest.predicate = NSPredicate(
                format: "date > %@ AND total != nil",
                now.addingTimeInterval(-10 * 24 * 60 * 60) as NSDate
            )
            let tddRows = try context.fetch(tddRequest).compactMap { row -> UntetheredTDD? in
                guard let date = row.date, let total = row.total?.decimalValue else { return nil }
                return UntetheredTDD(
                    date: date, total: total,
                    bolus: row.bolus?.decimalValue ?? 0, tempBasal: row.tempBasal?.decimalValue ?? 0,
                    scheduledBasal: row.scheduledBasal?.decimalValue ?? 0, weightedAverage: row.weightedAverage?.decimalValue
                )
            }
            let active = try self.openAPS.fetchActiveOverrides(on: context).first
            let overrideRequest = OverrideStored.fetchRequest()
            overrideRequest.predicate = NSPredicate(format: "isPreset == %@", true as NSNumber)
            let presets = try context.fetch(overrideRequest).sorted { $0.orderPosition < $1.orderPosition }
            let tempTargetRequest = TempTargetStored.fetchRequest()
            tempTargetRequest.predicate = NSPredicate(format: "isPreset == %@", true as NSNumber)
            let tempTargets = try context.fetch(tempTargetRequest).sorted { $0.orderPosition < $1.orderPosition }
            return (
                tdd,
                tddRows,
                active?.orefOverride(preferences: preferences),
                presets.map { $0.orefOverride(preferences: preferences) },
                tempTargets.map { $0.untetheredPreset(halfBasalTarget: preferences.halfBasalExerciseTarget) }
            )
        }

        return UntetheredGrant(
            leaseExpiresAt: now.addingTimeInterval(leaseLength),
            pumpConfiguration: try Self.plist(pump.exportConfiguration()),
            cgmConfiguration: try Self.plist(cgm.exportConfiguration()),
            pumpSettings: settingsManager.pumpSettings,
            bgTargets: storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self)
                ?? BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: []),
            basalProfile: storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? [],
            insulinSensitivities: storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self)
                ?? InsulinSensitivities(units: .mgdL, userPreferredUnits: .mgdL, sensitivities: []),
            carbRatios: storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self)
                ?? CarbRatios(units: .grams, schedule: []),
            preferences: preferences,
            dosingMode: settings.dosingMode,
            smoothGlucose: settings.smoothGlucose,
            units: settings.units,
            tdd: tdd,
            hasSufficientTDD: try await tddStorage.hasSufficientTDD(),
            tddRecentRows: tddRows.filter { $0.date >= now.addingTimeInterval(-2 * 60 * 60) },
            tddHours: UntetheredTDDHour.hours(tddRows),
            tddPumpHistory: try await pumpHistoryStorage.getPumpHistory(),
            autosens: storage.retrieve(OpenAPS.Settings.autosense, as: Autosens.self),
            reservoir: apsManager.pumpManager?.currentReservoir,
            maxBolus: settingsManager.pumpSettings.maxBolus,
            maxCarbs: settings.maxCarbs,
            bolusCalculator: UntetheredBolusCalculatorSettings(
                fraction: settings.overrideFactor,
                fattyMeals: settings.fattyMeals,
                fattyMealFactor: settings.fattyMealFactor,
                sweetMeals: settings.sweetMeals,
                sweetMealFactor: settings.sweetMealFactor
            ),
            glucoseColorScheme: settings.glucoseColorScheme.rawValue,
            lastDetermination: await determinationStorage.getOrefDeterminationNotYetUploadedToNightscout(
                (
                    try? await determinationStorage
                        .fetchLastDeterminationObjectID(predicate: .predicateFor30MinAgoForDetermination)
                ) ?? []
            ),
            lastLoopDate: apsManager.lastLoopDate,
            lowGlucose: settings.low,
            highGlucose: settings.high,
            pumpHistory: try await openAPS.algorithmPumpHistory(),
            glucose: glucose,
            smoothedGlucose: smoothedGlucose,
            carbs: try await carbsStorage.getCarbsForAlgorithm(additionalCarbs: nil, carbsDate: nil),
            activeOverride: activeOverride,
            tempTargets: storage.retrieve(OpenAPS.Settings.tempTargets, as: [TempTarget].self) ?? [],
            overridePresets: overridePresets,
            tempTargetPresets: tempTargetPresets,
            linkedOverrideID: linkedOverrideID
        )
    }

    private static func plist(_ configuration: SharedDeviceConfiguration) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: configuration.rawValue, format: .binary, options: 0)
    }

    /// The watch loops from here on; a loop already running finishes first. A running temp basal is cancelled; a low
    /// one goes to the watch to set again, a high one ends here. The pump is exported as released, after anything
    /// that loop enacted.
    @MainActor private func releasePump() async -> UntetheredHandover {
        for _ in 0 ..< 60 where apsManager.isLooping.value {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let tempBasal = await apsManager.pumpManager?.handOverTempBasal(scheduledRate: scheduledBasalRate(), cancellingHigh: true)
            .resume
        let pump = apsManager.pumpManager as? ExclusiveDeviceControl
        let configuration = pump.flatMap { try? Self.plist($0.exportConfiguration()) }
        pump?.releaseControl()
        for transfer in WCSession.default.outstandingUserInfoTransfers
            where transfer.userInfo[Self.standingGrantMarker] != nil
        {
            transfer.cancel()
        }
        debug(.watch, "Untethered: pump released to the watch")
        if let tempBasal { debug(.watch, "Untethered: temp basal \(tempBasal.unitsPerHour) U/h handed to the watch") }
        return UntetheredHandover(pumpConfiguration: configuration, tempBasal: tempBasal)
    }

    // MARK: - Taking the pump back

    /// `keepingPhoneDoses`: the watch only looked at the pod (its answer to a foreign session: not holding). A look
    /// reads the pod and doses nothing, so the phone's own bolus and temp still in flight stay as programmed. Purged
    /// as given away instead, the pod's delivered total then booked them as one "untethered gap" bolus at the take-back
    /// (13 November, third tester: an SMB of 0.35 U and a temp of 1.65 U/h became 0.51 U "no record explains").
    @MainActor private func takePump(keepingPhoneDoses: Bool = false) {
        UntetheredGate.update {
            $0.pumpReturnPending = true
            // the return's audit judges the session; the gap check starts over after it
            $0.podReading = nil
        }
        publish()
        // a silent watch never said what its copy held: before the take-back's pending report, the phone's own doses
        // in flight stay rather than being purged as given away
        let keepInFlight = state.session.unknownWatchSince != nil || keepingPhoneDoses
        Task {
            if keepInFlight { _ = try? await self.pumpHistoryStorage.keepInFlightDoses(startedAfter: nil) }
            (self.apsManager.pumpManager as? ExclusiveDeviceControl)?.takeControl()
            await self.finishPumpReturn(afterLook: keepingPhoneDoses)
        }
    }

    /// A pump return is being finished (`finishPumpReturn`).
    private var pumpReturnRunning = false
    /// Reads the pump until it answers, then audits its delivered total against the history before
    /// the loop may dose again.
    /// `afterLook`: the return ends a look of the watch's only (see `apply`), which lets a refused bolus be tried again.
    @MainActor private func finishPumpReturn(afterLook: Bool = false) async {
        // one at a time: a message taken on as the saved state opened can start one beside the launch's own
        // (Claude Fable's review, 15 November)
        guard !pumpReturnRunning else {
            debug(.watch, "Untethered: pump return already under way")
            return
        }
        pumpReturnRunning = true
        defer { pumpReturnRunning = false }
        auditFoundNoGap = false
        guard let odometer = apsManager.pumpManager as? PumpDeliveryOdometer else {
            UntetheredGate.update { $0.pumpReturnPending = false }
            publish()
            return
        }
        pumpReturnAnswered = false
        let control = apsManager.pumpManager as? ExclusiveDeviceControl
        control?.takeControl()
        debug(.watch, "Untethered: reading the pump back")
        // the reconnect keeps running with the phone in a pocket, rather than waiting for the next wake
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Untethered pump return") {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        defer { if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) } }
        let escalation = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.pumpEscalateAfter)
            // not once the watch holds the pump again: escalating lifts the release (Ponytail's review, 15 November)
            guard !Task.isCancelled, let control, !control.isControlReady, self.state.pumpReturnPending,
                  !control.isControlReleased else { return }
            let outcome = control.escalateTakeControl() ?? "nothing to escalate"
            debug(.watch, "Untethered: no pump link after 12 s, escalating: \(outcome)")
        }
        defer { escalation.cancel() }
        let started = Date()
        var attempts = 0
        var bannerShown = false
        while state.pumpReturnPending, !state.podEndedOnWatch, !(await odometer.refreshDeliveredUnits()) {
            attempts += 1
            debug(.watch, "Untethered: the pump did not answer yet (attempt \(attempts)), retrying")
            // with Bluetooth off nothing reaches the pod, and the watch has let go: said at once, as nobody doses
            if !bannerShown, isBluetoothOff {
                bannerShown = true
                warning(.watch, "Untethered: the pump comes back to the phone, but the iPhone's Bluetooth is off")
                setError(String(
                    localized: "The iPhone's Bluetooth is off, so it can't reach the pump and nothing doses. Turn Bluetooth on."
                ))
            }
            // dosing stays held until the pump is read; after a minute the banner says why
            if !bannerShown, Date().timeIntervalSince(started) >= 60 {
                bannerShown = true
                setError(String(
                    localized: "The phone can't reach the pump yet, so it doesn't dose. Keep the phone close to the pod; it keeps trying."
                ))
            }
            try? await Task.sleep(nanoseconds: Self.pumpReadRetry)
        }
        if bannerShown { setError(nil) }
        control?.endTakeEscalation()
        // the watch holds the pump again (`.releasePump`): nothing to read back
        guard state.pumpReturnPending else {
            debug(.watch, "Untethered: pump return given up, the watch holds the pump")
            return
        }
        if !state.podEndedOnWatch {
            pumpReturnAnswered = true
            debug(
                .watch,
                "Untethered: pump answered after \(Int(Date().timeIntervalSince(started))) s, \(attempts + 1) read(s); \(control?.connectionDiagnostics() ?? "")"
            )
        }
        // the temp basal the watch cancelled goes on as the phone's own, before the loop is let go
        if !state.podEndedOnWatch, let tempBasal = state.session.returnedTempBasal,
           let error = await apsManager.pumpManager?.resumeTempBasal(tempBasal)
        {
            warning(.watch, "Untethered: the watch's temp basal could not be set again: \(error.localizedDescription)")
        }
        // a high temp the watch left running ends here, now the phone has the pod; the schedule runs until its loop
        var endedHighTemp: (temp: UntetheredTempBasal, at: Date)?
        if !state.podEndedOnWatch, let high = state.session.returnedHighTemp, high.endsAt > Date() {
            if let error = await apsManager.pumpManager?.cancelTempBasal() {
                warning(.watch, "Untethered: the watch's high temp could not be cancelled: \(error.localizedDescription)")
            } else {
                endedHighTemp = (high, Date())
                debug(.watch, "Untethered: the watch's high temp \(high.unitsPerHour) U/h cancelled")
            }
        }
        if state.podEndedOnWatch {
            // nothing to read or audit: the watch's records carry the pod's doses up to its end
            (apsManager.pumpManager as? OmniPumpManager)?.forgetPodEndedElsewhere()
            UntetheredGate.update {
                $0.podEndedOnWatch = false
                $0.pumpReturnPending = false
            }
            publish()
            debug(.watch, "Untethered: the watch ended the pod; the phone is ready for a new one")
            return
        }
        // after a hand-back the watch's last records are on their way; judge the pump once they're in
        let epoch = state.session.epoch
        if !state.session.forced {
            let deadline = Date().addingTimeInterval(Self.historyWait)
            while state.applied[epoch] != nil, Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        // once the watch's records are in, so its record of that temp ends where the phone stopped it
        if let endedHighTemp { await endWatchTemp(endedHighTemp.temp, at: endedHighTemp.at) }
        await audit(odometer)
        // the last records may have come in while the audit read the history
        if let point = state.audit, point.epoch == epoch, state.applied[epoch] == nil {
            await judge(point, historyComplete: true)
        }
        UntetheredGate.update { $0.pumpReturnPending = false }
        publish()
        PhonePumpReturn.note(cleanLook: afterLook && auditFoundNoGap)
        debug(.watch, "Untethered: pump is back on the phone")
        // the session's start dropped the watch's copy: a phone gone again right after leaves it none to start from
        scheduleStandingGrant(settingsChanged: true, immediately: true)
        // each reading loops once, as on the watch: one the watch's last loop dosed on waits for the next
        if (glucoseStorage.lastGlucoseDate() ?? .distantPast) > apsManager.lastLoopDate {
            apsManager.heartbeat(date: Date())
        }
    }

    /// The scheduled basal rate now, as the hand-over's "high temp" test reads it.
    private func scheduledBasalRate() -> Decimal {
        let profile = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []
        return BolusCalculator.scheduleValue(profile.map { ($0.start, $0.rate) }, at: Date())
    }

    /// The watch reported a temp it left running as running to its planned end; the phone cancelled it. Its record
    /// ends where the phone stopped it, final, so IOB and the audit don't count the rest.
    @MainActor private func endWatchTemp(_ temp: UntetheredTempBasal, at end: Date) async {
        guard let identifier = temp.syncIdentifier else { return }
        let context = CoreDataStack.shared.newTaskContext()
        let ended: Bool = await context.perform {
            let request = PumpEventStored.fetchRequest() as NSFetchRequest<PumpEventStored>
            request.predicate = NSPredicate(format: "syncIdentifier == %@", identifier)
            guard let row = (try? context.fetch(request))?.first, let start = row.timestamp, let tempBasal = row.tempBasal
            else { return false }
            tempBasal.duration = Int16(max(0, (end.timeIntervalSince(start) / 60).rounded()))
            tempBasal.endDate = end
            row.isMutable = false
            row.isUploadedToNS = false
            try? context.save()
            return true
        }
        UntetheredGate.update { state in state.watchPendingDoses[state.session.epoch]?.remove(identifier) }
        if !ended { warning(.watch, "Untethered: no record of the watch's cancelled high temp to end") }
    }

    /// Insulin the pump delivered that no record explains is booked now, as a bolus. Records claiming more than the
    /// pump delivered only warn: that direction is safe. A history still missing the watch's last records is judged
    /// again once they are in, and only that second verdict is shown.
    @MainActor private func audit(_ odometer: PumpDeliveryOdometer) async {
        let session = state.session
        guard let start = session.startStatus, let startUnits = start.deliveredUnits,
              let current = odometer.deliveredUnits
        else { return }
        // after a silent watch, booked under an epoch of its own until the watch's records say what it delivered
        let provisional = session.unknownWatchSince.map { Self.provisionalEpoch($0) }
        let point = UntetheredAuditPoint(
            epoch: provisional ?? session.epoch,
            start: start.date,
            startUnits: startUnits,
            end: current.at,
            endUnits: current.units
        )
        await judge(point, historyComplete: provisional == nil && state.applied[session.epoch] == nil)
    }

    private static func provisionalEpoch(_ since: Date) -> Int { Int(since.timeIntervalSince1970) }

    /// The silent watch spoke: its booking moves to its epoch and is judged again once its history is in.
    @MainActor private func adoptProvisionalAudit(of since: Date, epoch: Int) async {
        let provisional = Self.provisionalEpoch(since)
        guard let point = state.audit, point.epoch == provisional else { return }
        await removeGap(epoch: provisional)
        await judge(
            UntetheredAuditPoint(
                epoch: epoch,
                start: point.start,
                startUnits: point.startUnits,
                end: point.end,
                endUnits: point.endUnits
            ),
            historyComplete: false
        )
    }

    /// Judges the span between the pump's two readings against the history as it is now.
    @MainActor private func judge(_ point: UntetheredAuditPoint, historyComplete: Bool, cause: String? = nil) async {
        // A pod's delivery counter only counts up. Lower at the end, the pod read isn't one to judge by: the pod
        // faulted or reset (2026-10-23 22:23, a pod past its 80 hours read 10.1 U below its start and the audit
        // warned of 10.8 U too many in the records).
        guard point.delivered >= 0 else {
            UntetheredGate.update { $0.audit = nil; $0.auditFinding = nil }
            warning(
                .watch,
                "Untethered: no audit, the pod's delivery counter went back by \(-point.delivered) U (a faulted or new pod)"
            )
            publish()
            return
        }
        // taken before the history is read, so the complete history judges it only once
        UntetheredGate.update { $0.audit = historyComplete ? nil : point }
        do {
            // an earlier verdict's booking is replaced, never counted as a record
            await removeGap(epoch: point.epoch)
            let expected = UntetheredAudit.expectedDelivery(
                from: point.start,
                to: point.end,
                history: try await pumpHistoryStorage.getPumpHistory(),
                basalProfile: storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? [],
                bolusDeliveryRate: (apsManager.pumpManager as? PumpDeliveryOdometer)?.bolusDeliveryRate ?? 0
            )
            // to the hundredth: the records' sum came out as 0.000050868113835652676 U after a look at the pod
            let rounded = { (value: Decimal) in value.formatted(.number.precision(.fractionLength(0 ... 2))) }
            let notes = [cause, historyComplete ? nil : "watch history incomplete"].compactMap { $0 }
            debug(
                .watch,
                "Untethered: audit\(notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))") — pump \(rounded(point.delivered)) U, records \(rounded(expected)) U"
            )
            let verdict = UntetheredAudit.verdict(delivered: point.delivered, expected: expected)
            // insulin no record explains counts at once, whatever the history still lacks: dosing must not go over it
            if case let .unrecorded(units) = verdict {
                auditFoundNoGap = false
                try await bookGap(units, at: point.end, epoch: point.epoch)
            } else {
                auditFoundNoGap = true
            }
            // only the complete history speaks: what the watch's last records would explain is no finding
            guard historyComplete else { return }
            let finding: String?
            switch verdict {
            case let .unrecorded(units):
                let amount = units.formatted(.number.precision(.fractionLength(0 ... 2)))
                finding = String(localized: "The pump delivered \(amount) U that no record explains. It is counted as a bolus.")
            case let .overstated(units):
                let amount = units.formatted(.number.precision(.fractionLength(0 ... 2)))
                finding = String(
                    localized: "The records show \(amount) U more insulin than the pump delivered. Insulin on board may be overstated."
                )
            case .explained:
                finding = nil
            }
            if let finding { warning(.watch, "Untethered: \(finding)") }
            UntetheredGate.update { $0.auditFinding = finding }
            publish()
        } catch {
            warning(.watch, "Untethered: audit failed: \(error.localizedDescription)")
        }
    }

    /// Loops come every five minutes; a longer pause may hide a controller the phone doesn't know of.
    private static let podGapCheck: TimeInterval = 10 * 60

    /// After a pause in the phone's own loops, what the pod delivered and no record explains, booked and shown as an
    /// audit finding: a watch that started without the phone and then failed leaves exactly this (LoopKit/Loop#2545).
    @MainActor private func checkPodGap() async {
        // only a watch that may start without the phone can dose unseen
        guard isEnabled, settingsManager.settings.allowUntetheredStartWithoutPhoneWatch,
              UntetheredGate.phoneMayDose, state.audit == nil,
              let current = (apsManager.pumpManager as? PumpDeliveryOdometer)?.deliveredUnits
        else { return }
        let pod = (apsManager.pumpManager as? OmniPumpManager)?.state.podState?.activatedAt
        let previous = state.podReading
        guard previous?.at != current.at else { return }
        UntetheredGate.update { $0.podReading = UntetheredPodReading(pod: pod, at: current.at, units: current.units) }
        guard let previous, previous.pod == pod, current.at.timeIntervalSince(previous.at) >= Self.podGapCheck,
              current.units >= previous.units
        else { return }
        let point = UntetheredAuditPoint(
            epoch: Int(current.at.timeIntervalSince1970),
            start: previous.at,
            startUnits: previous.units,
            end: current.at,
            endUnits: current.units
        )
        // one line, not two: the watch's fallback looks at the pod make one of these every 5 to 30 minutes
        await judge(
            point,
            historyComplete: true,
            cause: "\(Int(current.at.timeIntervalSince(previous.at) / 60)) min between pod readings"
        )
    }

    private static func gapIdentifier(_ epoch: Int) -> String { "untethered-gap-\(epoch)" }

    /// `NewPumpEvent` replaces a dose's sync identifier with its raw data in hex; the row is stored under that.
    private static func gapSyncIdentifier(_ epoch: Int) -> String {
        Data(gapIdentifier(epoch).utf8).map { String(format: "%02hhx", $0) }.joined()
    }

    private func bookGap(_ units: Decimal, at date: Date, epoch: Int) async throws {
        let identifier = Self.gapIdentifier(epoch)
        let dose = DoseEntry(
            type: .bolus,
            startDate: date,
            endDate: date,
            value: NSDecimalNumber(decimal: units).doubleValue,
            unit: .units,
            decisionId: nil,
            deliveredUnits: NSDecimalNumber(decimal: units).doubleValue,
            syncIdentifier: identifier
        )
        let event = NewPumpEvent(date: date, dose: dose, raw: Data(identifier.utf8), title: "Untethered gap", type: .bolus)
        try await pumpHistoryStorage.storePumpEvents([event], replacePendingEvents: false)
    }

    private func removeGap(epoch: Int) async {
        let context = CoreDataStack.shared.newTaskContext()
        let uploaded: [String] = await context.perform {
            let request = PumpEventStored.fetchRequest() as NSFetchRequest<PumpEventStored>
            request.predicate = NSPredicate(format: "syncIdentifier == %@", Self.gapSyncIdentifier(epoch))
            guard let rows = try? context.fetch(request), !rows.isEmpty else { return [] }
            let ids = rows.filter(\.isUploadedToNS).compactMap(\.id)
            rows.forEach(context.delete)
            try? context.save()
            return ids
        }
        // as the pump history withdraws a purged treatment
        for id in uploaded {
            await nightscoutManager.deleteInsulin(withID: id)
        }
    }

    /// Each finished span as a Nightscout note with its duration; one that didn't go goes with the next, or at launch.
    @MainActor private func uploadSpans() async {
        for span in state.spans where !span.uploaded {
            guard let end = span.end, await nightscoutManager.uploadUntetheredSession(from: span.start, to: end) else { continue }
            UntetheredGate.update { state in
                if let index = state.spans.firstIndex(where: { $0.start == span.start }) { state.spans[index].uploaded = true }
            }
        }
    }

    // MARK: - Linked override

    /// Untethered mode started from an override ends with it.
    /// An override or temp target that stopped running on the phone while the watch is in charge — cancelled here,
    /// from any screen, shortcut or remote command — ends on the watch too. The watch ends it only if it is the one
    /// that started then, so one started later on the wrist, or copied over from it, stays.
    @MainActor private func forwardCancellations() async {
        let override = await runningAdjustmentStarted(OverrideStored.self, predicate: .lastActiveOverride)
        let tempTarget = await runningAdjustmentStarted(TempTargetStored.self, predicate: .lastActiveTempTarget)
        defer {
            runningOverrideStart = override
            runningTempTargetStart = tempTarget
        }
        guard isWatchInCharge else { return }
        let now = Date()
        if let before = runningOverrideStart, before != override {
            send(.adjustmentCancelled(.override, start: before, at: now), epoch: state.session.epoch)
        }
        if let before = runningTempTargetStart, before != tempTarget {
            send(.adjustmentCancelled(.tempTarget, start: before, at: now), epoch: state.session.epoch)
        }
    }

    @MainActor private func checkLinkedOverride() async {
        guard state.session.phase == .active, let linkedID = state.session.linkedOverrideID else { return }
        if await !isOverrideActive(id: linkedID) {
            debug(.watch, "Untethered: the linked override is over, ending")
            await end()
        }
    }

    @MainActor private func scheduleLinkedOverrideCheck() async {
        linkedOverrideTimer?.invalidate()
        linkedOverrideTimer = nil
        guard state.session.phase == .active, let linkedID = state.session.linkedOverrideID,
              let end = await overrideEnd(id: linkedID)
        else { return }
        linkedOverrideTimer = Timer
            .scheduledTimer(withTimeInterval: max(1, end.timeIntervalSinceNow), repeats: false) { [weak self] _ in
                Task { await self?.checkLinkedOverride() }
            }
    }

    private func isOverrideActive(id: String) async -> Bool {
        guard let end = await overrideEnd(id: id) else { return false }
        return end > Date()
    }

    /// `.distantFuture` for an indefinite override, nil when it isn't enabled.
    private func overrideEnd(id: String) async -> Date? {
        let context = CoreDataStack.shared.newTaskContext()
        return await context.perform {
            let request = OverrideStored.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@ AND enabled == %@", id, true as NSNumber)
            guard let row = try? context.fetch(request).first, let start = row.date else { return nil }
            if row.indefinite { return .distantFuture }
            return start.addingTimeInterval((row.duration?.doubleValue ?? 0) * 60)
        }
    }

    // MARK: - History from the watch

    /// The batch in flight, so the next one waits for it.
    private var ingestTail: Task<Void, Never>?

    /// One batch at a time: `ingest` suspends at every save, and batches arriving meanwhile (several per burst, and
    /// resends after a reply timeout) would otherwise both see a record as new and store its carbs twice, or write
    /// back the applied set over each other's entries.
    @MainActor private func ingestInOrder(_ records: [UntetheredRecord], epoch: Int) async -> [UUID] {
        let previous = ingestTail
        let batch = Task { @MainActor () -> [UUID] in
            await previous?.value
            return await self.ingest(records, epoch: epoch)
        }
        ingestTail = Task { _ = await batch.value }
        return await batch.value
    }

    /// Returns the record versions now stored, including ones stored before.
    @MainActor private func ingest(_ records: [UntetheredRecord], epoch: Int) async -> [UUID] {
        // a session whose history is complete takes nothing more: a late copy (a queued transfer, a resend after a
        // relaunch) would store its carbs and doses a second time. Confirmed, so the watch lets go of it.
        let session = state.session
        guard state.applied[epoch] != nil || (epoch == session.epoch && !session.isIdle) else {
            // a newer session's records aren't confirmed: the watch sends them again once the phone follows it
            guard epoch <= session.epoch else { return [] }
            debug(.watch, "Untethered: \(records.count) record(s) of finished session \(epoch) ignored")
            return records.map(\.id)
        }
        var applied = state.applied[epoch] ?? [:]
        // the Apple Watch update waits until the batch is in: one per stored reading slowed the history to a crawl
        Self.historyBusyUntil = Date().addingTimeInterval(Self.historyQuietGap)
        let todo = records.sorted(by: { $0.date < $1.date }).filter { applied[$0.key]?.id != $0.id }
        // loops the watch uploaded to Nightscout itself: stored as uploaded, so the phone's upload doesn't repeat them
        let uploadedByWatch = Set(todo.compactMap { record -> Int? in
            if case let .nightscoutUploaded(date) = record.kind { return Int(date.timeIntervalSince1970) }
            return nil
        })
        var index = 0
        while index < todo.count {
            // a run of readings or of pump events goes in one save, one update for the app instead of one each
            // (24 October: 500 entries left after a 4 h session, each batch outlasting WatchConnectivity's reply time)
            let run = Self.storageRun(todo[index...])
            do {
                if run.count > 1 {
                    try await storeRun(run, epoch: epoch)
                } else {
                    try await store(run[0], epoch: epoch, uploadedByWatch: uploadedByWatch)
                }
                for record in run { applied[record.key] = record.syncEntry }
            } catch {
                // left out of the applied set, so the next sync asks for it again
                for record in run {
                    warning(.watch, "Untethered: could not store \(record.key): \(error.localizedDescription)")
                }
            }
            index += run.count
        }
        if todo.contains(where: { if case .determination = $0.kind { return true } else { return false } }) {
            await keepNewestDeterminationsForUpload()
        }
        Self.historyBusyUntil = Date().addingTimeInterval(Self.historyQuietGap)
        UntetheredGate.update { $0.applied[epoch] = applied }
        publish()
        if settingsManager.settings.smoothGlucose,
           records.contains(where: {
               switch $0.kind {
               case .glucose,
                    .glucoseDeleted: return true
               default: return false
               }
           })
        {
            let context = CoreDataStack.shared.newTaskContext()
            context.name = "untetheredSmoothing"
            await fetchGlucoseManager.exponentialSmoothingGlucose(context: context)
        }
        return records.filter { applied[$0.key]?.id == $0.id }.map(\.id)
    }

    /// While the watch's history comes in, and a moment after: the Apple Watch update waits for it.
    @MainActor static var historyBusyUntil = Date.distantPast
    static let historyQuietGap: TimeInterval = 3

    /// The records from the start of `records` that can be stored together: readings with readings, pump events with
    /// pump events, never two versions of one key. Anything else goes alone.
    private static func storageRun(_ records: ArraySlice<UntetheredRecord>) -> [UntetheredRecord] {
        guard let first = records.first else { return [] }
        func group(_ record: UntetheredRecord) -> Int? {
            switch record.kind {
            case .glucose: return 1
            case .pumpEvent: return 2
            default: return nil
            }
        }
        guard let kind = group(first) else { return [first] }
        var keys = Set<String>()
        var run: [UntetheredRecord] = []
        for record in records {
            guard group(record) == kind, keys.insert(record.key).inserted else { break }
            run.append(record)
        }
        return run
    }

    private static func pumpEvent(from data: Data) throws -> NewPumpEvent {
        guard let raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? NewPumpEvent
            .RawValue,
            let event = NewPumpEvent(rawValue: raw)
        else { throw UntetheredError.unavailable("unreadable pump event") }
        return event
    }

    /// A run from `storageRun`, in one call to its storage.
    private func storeRun(_ run: [UntetheredRecord], epoch: Int) async throws {
        var glucose: [BloodGlucose] = []
        var events: [NewPumpEvent] = []
        for record in run {
            switch record.kind {
            case let .glucose(reading): glucose.append(reading)
            case let .pumpEvent(data):
                let event = try Self.pumpEvent(from: data)
                await MainActor.run { self.noteWatchDose(event.dose) }
                events.append(event)
            default: break
            }
        }
        if !glucose.isEmpty {
            try await glucoseStorage.storeWatchGlucose(glucose)
            if let newest = glucose.map(\.dateString).max(), newest > lastWatchReadingAt ?? .distantPast {
                lastWatchReadingAt = newest
            }
        }
        if !events.isEmpty {
            // as `store` does for one: held before the rows exist, released once final
            let doses = events.compactMap { event -> (id: String, mutable: Bool)? in
                guard let id = event.dose?.syncIdentifier, !id.isEmpty else { return nil }
                return (id, event.dose?.isMutable == true)
            }
            let pending = doses.filter(\.mutable).map(\.id)
            if !pending.isEmpty {
                UntetheredGate.update { $0.watchPendingDoses[epoch, default: []].formUnion(pending) }
            }
            try await pumpHistoryStorage.storePumpEvents(events, replacePendingEvents: false)
            let final = doses.filter { !$0.mutable }.map(\.id)
            if !final.isEmpty {
                UntetheredGate.update { $0.watchPendingDoses[epoch]?.subtract(final) }
            }
        }
    }

    private func store(_ record: UntetheredRecord, epoch: Int, uploadedByWatch: Set<Int> = []) async throws {
        switch record.kind {
        case let .pumpEvent(data):
            let event = try Self.pumpEvent(from: data)
            await MainActor.run { self.noteWatchDose(event.dose) }
            // held before the row exists, so no purge can fall in between; released once the row is final
            let pendingDose = event.dose?.syncIdentifier.flatMap { $0.isEmpty ? nil : $0 }
            if let pendingDose, event.dose?.isMutable == true {
                UntetheredGate.update { $0.watchPendingDoses[epoch, default: []].insert(pendingDose) }
            }
            try await pumpHistoryStorage.storePumpEvents([event], replacePendingEvents: false)
            if let pendingDose, event.dose?.isMutable != true {
                UntetheredGate.update { $0.watchPendingDoses[epoch]?.remove(pendingDose) }
            }
        case let .pumpEventDropped(syncIdentifier):
            // as `storePumpEvents(replacePendingEvents: true)` purges an unasserted pending row
            let context = CoreDataStack.shared.newTaskContext()
            await context.perform {
                let request = PumpEventStored.fetchRequest() as NSFetchRequest<PumpEventStored>
                request.predicate = NSPredicate(format: "syncIdentifier == %@ AND isMutable == YES", syncIdentifier)
                guard let rows = try? context.fetch(request), !rows.isEmpty else { return }
                rows.forEach(context.delete)
                try? context.save()
            }
            UntetheredGate.update { $0.watchPendingDoses[epoch]?.remove(syncIdentifier) }
        case let .glucose(glucose):
            try await glucoseStorage.storeWatchGlucose([glucose])
            if glucose.dateString > lastWatchReadingAt ?? .distantPast { lastWatchReadingAt = glucose.dateString }
        case let .glucoseDeleted(date):
            let context = CoreDataStack.shared.newTaskContext()
            let found: (objectID: NSManagedObjectID, id: String?, date: Date?)? = await context.perform {
                let request = GlucoseStored.fetchRequest() as NSFetchRequest<GlucoseStored>
                request.predicate = NSPredicate(
                    format: "date >= %@ AND date <= %@",
                    date.addingTimeInterval(-1) as NSDate,
                    date.addingTimeInterval(1) as NSDate
                )
                return (try? context.fetch(request).first).map { (objectID: $0.objectID, id: $0.id?.uuidString, date: $0.date) }
            }
            if let found {
                // as the History screen deletes a reading: from the services it reached, then here
                if let id = found.id {
                    if let date = found.date { await nightscoutManager.deleteGlucose(withID: id, withDate: date) }
                    await healthkitManager.deleteGlucose(syncID: id)
                }
                await glucoseStorage.deleteGlucose(found.objectID)
            }
        case let .carbs(entry):
            if await carbEntryID(entry.id) == nil {
                try await carbsStorage.storeCarbs([entry], areFetchedFromRemote: false)
            }
        case let .carbsDeleted(id):
            if let objectID = await carbEntryID(id) {
                await deleteCarbsFromServices(objectID)
                await carbsStorage.deleteCarbsEntryStored(objectID)
            }
        case let .override(override):
            try await adjustmentManager.activateOverride(
                .presetID(override.id),
                source: .watch,
                waitForUpload: false,
                at: record.date
            )
        case let .overrideEnded(start):
            // may arrive long after the hand-back: never end an override started since
            if await runningAdjustmentStarted(OverrideStored.self, predicate: .lastActiveOverride) == start.rounded {
                try await adjustmentManager.cancelOverride(source: .watch, waitForUpload: false, at: record.date)
            }
        case let .tempTarget(tempTarget):
            // a preset by its id; a custom one (a remote command's target) is no preset here: stored first, as the
            // phone's own remote control does (`handleTempTargetCommand`), once (1 November, 13:38: "Preset … not
            // found", so the phone neither uploaded it nor knew it after the hand-back)
            let ref: AdjustmentRef
            if tempTarget.isPreset == true {
                ref = .presetID(tempTarget.id)
            } else {
                guard await !tempTargetsStorage.existsTempTarget(with: record.date) else { break }
                var custom = tempTarget
                custom.createdAt = record.date
                custom.enabled = false
                ref = .objectID(try await tempTargetsStorage.storeTempTarget(tempTarget: custom))
            }
            try await adjustmentManager.activateTempTarget(ref, source: .watch, waitForUpload: false, at: record.date)
        case let .tempTargetEnded(start):
            if await runningAdjustmentStarted(TempTargetStored.self, predicate: .lastActiveTempTarget) == start.rounded {
                try await adjustmentManager.cancelTempTarget(source: .watch, waitForUpload: false, at: record.date)
            }
        case let .determination(determination, enactedAt):
            let context = CoreDataStack.shared.newTaskContext()
            context.name = "untetheredDetermination"
            let uploaded = determination.deliverAt.map { uploadedByWatch.contains(Int($0.timeIntervalSince1970)) } ?? false
            await openAPS.processDetermination(determination, enactedAt: enactedAt, uploadedToNS: uploaded, on: context)
            // `ingest` sorts the uploads once the batch is in
        case let .tdd(tdd):
            await tddStorage.storeTDD(
                TDDResult(
                    total: tdd.total,
                    bolus: tdd.bolus,
                    tempBasal: tdd.tempBasal,
                    scheduledBasal: tdd.scheduledBasal,
                    weightedAverage: tdd.weightedAverage,
                    hoursOfData: 24
                ),
                at: tdd.date
            )
        case let .autosens(autosens):
            // the phone continues from the watch's ratio until its own next autosens run
            let stored = storage.retrieve(OpenAPS.Settings.autosense, as: Autosens.self)
            if (autosens.timestamp ?? .distantPast) > (stored?.timestamp ?? .distantPast) {
                storage.save(autosens, as: OpenAPS.Settings.autosense)
            }
        case .podEnded:
            UntetheredGate.update { $0.podEndedOnWatch = true }
        case let .pumpStatus(status):
            UntetheredGate.update { if ($0.watchPump?.date ?? .distantPast) < status.date { $0.watchPump = status } }
        case let .loopCompleted(date):
            // the loop's age and the interval to the next loop go on from the watch's last loop
            await MainActor.run { self.apsManager.adoptLoop(at: date) }
        case let .nightscoutUploaded(date):
            // the loop came in an earlier batch than this note: marked now, unless the phone uploaded it already
            await markDeterminationUploadedByWatch(deliveredAt: date)
        }
    }

    /// When the running override or temp target started, to the second.
    private func runningAdjustmentStarted<Entity: NSManagedObject>(_: Entity.Type, predicate: NSPredicate) async -> Date? {
        let context = CoreDataStack.shared.newTaskContext()
        return await context.perform {
            let request = NSFetchRequest<Entity>(entityName: String(describing: Entity.self))
            request.predicate = predicate
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            request.fetchLimit = 1
            return (try? context.fetch(request).first?.value(forKey: "date") as? Date)?.rounded
        }
    }

    /// A loop the untethered watch uploaded to Nightscout itself, as stored from its history.
    private func markDeterminationUploadedByWatch(deliveredAt date: Date) async {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "untetheredDeterminationUploadedByWatch"
        await context.perform {
            let request = OrefDetermination.fetchRequest() as NSFetchRequest<OrefDetermination>
            request.predicate = NSPredicate(
                format: "isUploadedToNS == NO AND deliverAt >= %@ AND deliverAt < %@",
                date.addingTimeInterval(-1) as NSDate,
                date.addingTimeInterval(1) as NSDate
            )
            for row in (try? context.fetch(request)) ?? [] { row.isUploadedToNS = true }
            if context.hasChanges { try? context.save() }
        }
    }

    /// Nightscout's live status is the newest loop; the upload takes the newest determination not yet uploaded, then
    /// the next older one, each stamped on arrival, so a session's backlog would end with Nightscout showing its oldest
    /// loop. The newest enacted and the newest suggested one stay for the live upload; the older ones go up as past
    /// statuses at their own times, so Nightscout's history shows their forecasts.
    private func keepNewestDeterminationsForUpload() async {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "untetheredDeterminationUpload"
        let older: [NSManagedObjectID] = await context.perform {
            let request = OrefDetermination.fetchRequest() as NSFetchRequest<OrefDetermination>
            request.predicate = NSPredicate(format: "isUploadedToNS == NO")
            request.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: false)]
            guard let rows = try? context.fetch(request), rows.count > 1 else { return [] }
            return Dictionary(grouping: rows, by: \.enacted).values.flatMap { $0.dropFirst().map(\.objectID) }
        }
        guard !older.isEmpty else { return }
        var determinations: [Determination] = []
        for objectID in older {
            if let determination = await determinationStorage.getOrefDeterminationNotYetUploadedToNightscout([objectID]) {
                determinations.append(determination)
            }
        }
        // left for the live upload to retry if Nightscout can't be reached now
        guard await nightscoutManager.uploadDeterminationHistory(determinations) else { return }
        await context.perform {
            for objectID in older {
                (try? context.existingObject(with: objectID) as? OrefDetermination)?.isUploadedToNS = true
            }
            if context.hasChanges { try? context.save() }
        }
    }

    /// As the History screen deletes an entry: carbs, and fat and protein entered with them, from Nightscout,
    /// Apple Health and Tidepool.
    private func deleteCarbsFromServices(_ objectID: NSManagedObjectID) async {
        let context = CoreDataStack.shared.newTaskContext()
        let entry: (id: UUID?, fpuID: UUID?, carbs: Decimal, date: Date?)? = await context.perform {
            (try? context.existingObject(with: objectID) as? CarbEntryStored)
                .map { (id: $0.id, fpuID: $0.fpuID, carbs: Decimal($0.carbs), date: $0.date) }
        }
        guard let entry else { return }
        if let fpuID = entry.fpuID?.uuidString {
            await nightscoutManager.deleteCarbs(withID: fpuID)
            for sampleType in [AppleHealthConfig.healthFatObject, AppleHealthConfig.healthProteinObject].compactMap({ $0 }) {
                await healthkitManager.deleteMealData(byID: fpuID, sampleType: sampleType)
            }
        }
        if let id = entry.id, let date = entry.date {
            await nightscoutManager.deleteCarbs(withID: id.uuidString)
            if let sampleType = AppleHealthConfig.healthCarbObject {
                await healthkitManager.deleteMealData(byID: id.uuidString, sampleType: sampleType)
            }
            tidepoolManager.deleteCarbs(withSyncId: id, carbs: entry.carbs, at: date, enteredBy: CarbsEntry.local)
        }
    }

    private func carbEntryID(_ id: String?) async -> NSManagedObjectID? {
        guard let uuid = id.flatMap(UUID.init(uuidString:)) else { return nil }
        let context = CoreDataStack.shared.newTaskContext()
        return await context.perform {
            let request = CarbEntryStored.fetchRequest() as NSFetchRequest<CarbEntryStored>
            request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            return try? context.fetch(request).first?.objectID
        }
    }

    /// Asks the watch for the buckets where its history and what the phone stored differ.
    @MainActor private func requestSync(epoch: Int) {
        let list = UntetheredSyncEntry.bucketChecksumList(of: Array((state.applied[epoch] ?? [:]).values))
        send(.syncRequest(bucketStart: list.start, checksums: list.checksums), epoch: epoch)
    }

    @MainActor private func finishSync(epoch: Int) async {
        await freezeWatchDoses(epoch: epoch)
        UntetheredGate.update { $0.applied[epoch] = nil }
        publish()
        debug(.watch, "Untethered: history of session \(epoch) complete")
        // a return audited before the history was complete is judged again; one still reading the pump does it itself
        if !state.pumpReturnPending, let point = state.audit, point.epoch == epoch {
            await judge(point, historyComplete: true)
        }
    }

    /// The watch's last records are in, so it finalizes nothing more: a dose it last reported as running stays as
    /// reported, final, and the phone's own pending reports leave it alone from here on.
    @MainActor private func freezeWatchDoses(epoch: Int) async {
        guard let identifiers = state.watchPendingDoses[epoch] else { return }
        if !identifiers.isEmpty {
            let context = CoreDataStack.shared.newTaskContext()
            await context.perform {
                let request = PumpEventStored.fetchRequest() as NSFetchRequest<PumpEventStored>
                request.predicate = NSPredicate(format: "syncIdentifier IN %@ AND isMutable == YES", Array(identifiers))
                guard let rows = try? context.fetch(request), !rows.isEmpty else { return }
                rows.forEach { $0.isMutable = false }
                try? context.save()
            }
            debug(.watch, "Untethered: \(identifiers.count) dose(s) the watch left running kept as it reported them")
        }
        UntetheredGate.update { $0.watchPendingDoses[epoch] = nil }
    }
}

private extension TempTargetStored {
    /// As the watch shows and activates it; `id` matches the preset for `AdjustmentRef.presetID`.
    func untetheredPreset(halfBasalTarget: Decimal) -> TempTarget {
        TempTarget(
            id: id?.uuidString ?? UUID().uuidString,
            name: name,
            createdAt: date ?? Date(),
            targetTop: target?.decimalValue,
            targetBottom: target?.decimalValue,
            duration: duration?.decimalValue ?? 0,
            enteredBy: TempTarget.local,
            reason: TempTarget.custom,
            isPreset: true,
            enabled: false,
            halfBasalTarget: self.halfBasalTarget?.decimalValue ?? halfBasalTarget
        )
    }
}

private extension Date {
    /// Whole seconds: dates that went through JSON and Core Data compare equal.
    var rounded: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded()) }
}

// The standing grant follows the settings it carries.
extension UntetheredPhoneManager: SettingsObserver, PreferencesObserver, PumpSettingsObserver, BasalProfileObserver,
    InsulinSensitivitiesObserver, CarbRatiosObserver, BGTargetsObserver
{
    func settingsDidChange(_ settings: TrioSettings) {
        scheduleStandingGrant(settingsChanged: true)
        // the home screen's tint reads a setting
        DispatchQueue.main.async { self.objectWillChange.send() }
        // with the start without the phone off, no other controller may use the pod: the guard set for it goes
        if !Self.allowsStartWithoutPhone(settings) {
            DispatchQueue.main.async { [weak self] in
                guard let control = self?.apsManager.pumpManager as? ExclusiveDeviceControl,
                      UntetheredGate.phoneMayDose || !control.isControlReleased,
                      control.refusesForeignSessionsSince != nil else { return }
                control.refusesForeignSessionsSince = nil
            }
        }
        if !state.session.isIdle {
            send(.dosingModeChanged(settings.dosingMode), epoch: state.session.epoch)
        }
        // turned off with the watch in charge: it hands back, as from the mode's own toggle
        if !settings.untetheredModeWatch, state.session.phase == .active {
            Task { @MainActor in await self.end() }
        }
    }

    func preferencesDidChange(_: Preferences) { scheduleStandingGrant(settingsChanged: true) }
    func pumpSettingsDidChange(_: PumpSettings) { scheduleStandingGrant(settingsChanged: true) }
    func basalProfileDidChange(_: [BasalProfileEntry]) { scheduleStandingGrant(settingsChanged: true) }
    func insulinSensitivitiesDidChange(_: InsulinSensitivities) { scheduleStandingGrant(settingsChanged: true) }
    func carbRatiosDidChange(_: CarbRatios) { scheduleStandingGrant(settingsChanged: true) }
    func bgTargetsDidChange(_: BGTargets) { scheduleStandingGrant(settingsChanged: true) }
}

extension UntetheredPhoneManager: BluetoothObserver {
    func bluetoothDidUpdateState(_: BluetoothState) {
        objectWillChange.send()
    }
}
