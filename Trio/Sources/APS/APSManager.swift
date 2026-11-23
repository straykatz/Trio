import Combine
import CoreData
import Foundation
import LoopKit
import LoopKitUI
import SwiftDate
import Swinject

protocol APSManager {
    func heartbeat(date: Date)
    /// Mark the next loop attempt as user-initiated (e.g. force-loop button).
    /// Surfaces transient errors immediately instead of waiting for the
    /// usual dwell threshold — when the user explicitly asks for a loop,
    /// they want feedback even if the underlying error is "transient".
    func markNextLoopUserInitiated()
    func enactBolus(amount: Double, isSMB: Bool, callback: ((Bool, String) -> Void)?) async
    var pumpManager: PumpManagerUI? { get set }
    var bluetoothManager: BluetoothStateManager? { get }
    var pumpDisplayState: CurrentValueSubject<PumpDisplayState?, Never> { get }
    var pumpName: CurrentValueSubject<String, Never> { get }
    var isLooping: CurrentValueSubject<Bool, Never> { get }
    var lastLoopDate: Date { get }
    /// The untethered hand-back carries the watch's last loop over: the loop's age and the minimum interval to the
    /// next loop both count from it, so the phone doesn't loop again straight away.
    func adoptLoop(at date: Date)
    var lastLoopDateSubject: PassthroughSubject<Date, Never> { get }
    var bolusProgress: CurrentValueSubject<Decimal?, Never> { get }
    var pumpExpiresAtDate: CurrentValueSubject<Date?, Never> { get }
    var pumpActivatedAtDate: CurrentValueSubject<Date?, Never> { get }
    var isManualTempBasal: Bool { get }
    var isSuspended: Bool { get }
    /// Runs a determination outside the loop, after a treatment or adjustment changed what the
    /// algorithm reads. Waits for a loop in flight to finish first, since that loop determined
    /// before the change landed. Concurrent calls collapse into the one already running. Algorithm
    /// errors propagate to the caller.
    func determineBasalSync() async throws
    func simulateDetermineBasal(
        simulatedCarbsAmount: Decimal,
        simulatedBolusAmount: Decimal,
        simulatedCarbsDate: Date?
    ) async -> Determination?
    func roundBolus(amount: Decimal) -> Decimal
    var lastError: CurrentValueSubject<Error?, Never> { get }
    func cancelBolus(_ callback: ((Bool, String) -> Void)?) async
    var iobFileDidUpdate: PassthroughSubject<Void, Never> { get }
}

/// Notified after a bolus-related failure so observing UI (e.g. the
/// treatment screen's bolus state) can clean up state. Broadcast by
/// `APSManager` from `enactBolus` / `cancelBolus` error paths.
protocol BolusFailureObserver {
    func bolusDidFail()
}

enum APSError: LocalizedError {
    case pumpError(Error)
    case invalidPumpState(message: String)
    case glucoseError(message: String)
    case apsError(message: String)
    case manualBasalTemp(message: String)

    var errorDescription: String? {
        switch self {
        case let .pumpError(error):
            return String(localized: "Pump Error (\(error.localizedDescription)).")
        case let .invalidPumpState(message):
            return String(localized: "Invalid Pump State (\(message)).")
        case let .glucoseError(message):
            return String(localized: "Invalid Glucose (\(message)).")
        case let .apsError(message):
            return String(localized: "Invalid Algorithm Response (\(message)).")
        case let .manualBasalTemp(message):
            return String(localized: "Manual Temporary Basal Rate (\(message)). Looping suspended.")
        }
    }
}

// MARK: - Thread-safe loop serialization

/// Ensures only one loop runs at a time via actor isolation
private actor LoopGuard {
    private var isRunning = false
    private var isDeterminingStandalone = false
    private var loopWaiters: [CheckedContinuation<Void, Never>] = []

    /// Atomically checks whether a new loop can start and marks it as running if so.
    func tryStart(minInterval: TimeInterval, lastLoopDate: Date, lastLoopStartDate: Date) -> Bool {
        // If the last loop completed after it started, enforce minimum interval
        if lastLoopDate > lastLoopStartDate {
            guard lastLoopStartDate.addingTimeInterval(minInterval) < Date() else { return false }
        }
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    func finish() {
        isRunning = false
        let waiters = loopWaiters
        loopWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Claims the guard as a loop would, for a dose outside the loop that must not overlap one; `finish()` frees it.
    func tryClaim() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    /// Returns once no loop is running.
    func waitForLoop() async {
        guard isRunning else { return }
        await withCheckedContinuation { loopWaiters.append($0) }
    }

    /// Claims the guard for a determination that runs outside the loop. Refuses while another one
    /// runs, since it computes the same state. `tryStart` ignores this claim: a skipped loop has a
    /// therapy cost, an overlapping determination only wastes work.
    func tryStartStandaloneDetermination() -> Bool {
        guard !isDeterminingStandalone else { return false }
        isDeterminingStandalone = true
        return true
    }

    func finishStandaloneDetermination() {
        isDeterminingStandalone = false
    }
}

final class BaseAPSManager: APSManager, Injectable {
    private let processQueue = DispatchQueue(label: "BaseAPSManager.processQueue")
    private let therapyProfileManagerLock = NSLock()
    private var resolvedTherapyProfileManager: TherapyProfileManager?
    @Injected() private var storage: FileStorage!
    @Injected() private var pumpHistoryStorage: PumpHistoryStorage!
    @Injected() private var carbsStorage: CarbsStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var determinationStorage: DeterminationStorage!
    @Injected() private var deviceDataManager: DeviceDataManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var tddStorage: TDDStorage!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var trioAlertManager: TrioAlertManager!
    @Persisted(key: "lastLoopStartDate") private var lastLoopStartDate: Date = .distantPast

    func adoptLoop(at date: Date) {
        guard date > lastLoopDate else { return }
        lastLoopStartDate = date
        lastLoopDate = date
    }

    private var lastDosingMode: DosingMode?
    @Persisted(key: "lastLoopDate") var lastLoopDate: Date = .distantPast {
        didSet {
            lastLoopDateSubject.send(lastLoopDate)
        }
    }

    private var openAPS: OpenAPS!

    private var lifetime = Lifetime()

    private let loopGuard = LoopGuard()
    /// All reads/writes are dispatched onto `processQueue` so the bolus
    /// trigger sink, `cancelBolus`, and the `DoseProgressReporter`
    /// callback (which the pump manager already invokes on
    /// `processQueue`) all serialize through one queue
    private var bolusReporter: DoseProgressReporter?

    var pumpManager: PumpManagerUI? {
        get { deviceDataManager.pumpManager }
        set { deviceDataManager.pumpManager = newValue }
    }

    var bluetoothManager: BluetoothStateManager? { deviceDataManager.bluetoothManager }

    @Persisted(key: "isManualTempBasal") var isManualTempBasal: Bool = false

    @Persisted(key: "isSuspended") var isSuspended: Bool = false

    let isLooping = CurrentValueSubject<Bool, Never>(false)
    let lastLoopDateSubject = PassthroughSubject<Date, Never>()
    let lastError = CurrentValueSubject<Error?, Never>(nil)
    let iobFileDidUpdate = PassthroughSubject<Void, Never>()

    let bolusProgress = CurrentValueSubject<Decimal?, Never>(nil)

    var pumpDisplayState: CurrentValueSubject<PumpDisplayState?, Never> {
        deviceDataManager.pumpDisplayState
    }

    var pumpName: CurrentValueSubject<String, Never> {
        deviceDataManager.pumpName
    }

    var pumpExpiresAtDate: CurrentValueSubject<Date?, Never> {
        deviceDataManager.pumpExpiresAtDate
    }

    var pumpActivatedAtDate: CurrentValueSubject<Date?, Never> {
        deviceDataManager.pumpActivatedAtDate
    }

    var settings: TrioSettings {
        get { settingsManager.settings }
        set { settingsManager.settings = newValue }
    }

    /// The profile manager depends on this manager, so it is resolved on first use, through the app's locked resolver:
    /// the loop runs on several threads, and Swinject's container is not safe to use from more than one at a time.
    private var therapyProfileManager: TherapyProfileManager? {
        therapyProfileManagerLock.lock()
        defer { therapyProfileManagerLock.unlock() }
        if resolvedTherapyProfileManager == nil {
            resolvedTherapyProfileManager = TrioApp.resolver.resolve(TherapyProfileManager.self)
        }
        return resolvedTherapyProfileManager
    }

    init(resolver: Resolver) {
        injectServices(resolver)
        openAPS = OpenAPS(storage: storage, tddStorage: tddStorage, glucoseStorage: glucoseStorage, carbsStorage: carbsStorage)
        lastDosingMode = settingsManager.settings.dosingMode
        broadcaster.register(SettingsObserver.self, observer: self)
        subscribe()
        lastLoopDateSubject.send(lastLoopDate)

        isLooping
            .weakAssign(to: \.deviceDataManager.loopInProgress, on: self)
            .store(in: &lifetime)
    }

    private func subscribe() {
        if settingsManager.settings.units == .mmolL {
            let wasParsed = storage.parseOnFileSettingsToMgdL()
            if wasParsed {
                Task {
                    do {
                        try await openAPS.createProfiles(for: self.settingsManager.settings.dosingMode)
                    } catch {
                        warning(.algorithm, "Creating profiles after unit conversion failed", error: error)
                    }
                }
            }
        }

        deviceDataManager.recommendsLoop
            .receive(on: processQueue)
            .sink { [weak self] in
                self?.loop()
            }
            .store(in: &lifetime)

        deviceDataManager.errorSubject
            .receive(on: processQueue)
            .map { APSError.pumpError($0) }
            .sink { [weak self] in
                self?.processError($0)
            }
            .store(in: &lifetime)

        deviceDataManager.bolusTrigger
            .receive(on: processQueue)
            .sink { [weak self] bolusState in
                switch bolusState {
                case .initiating,
                     .inProgress:
                    self?.createBolusReporter()
                case .noBolus:
                    self?.clearBolusReporter()
                }
            }
            .store(in: &lifetime)

        deviceDataManager.suspended
            .receive(on: DispatchQueue.main)
            .sink { [weak self] suspended in
                self?.isSuspended = suspended
            }
            .store(in: &lifetime)

        // manage a manual Temp Basal from PumpManager - force loop() after manual temp basal is cancelled or finishes
        deviceDataManager.manualTempBasal
            .receive(on: DispatchQueue.main)
            .sink { [weak self] manualBasal in
                if manualBasal {
                    self?.isManualTempBasal = true
                } else {
                    if self?.isManualTempBasal == true {
                        self?.isManualTempBasal = false
                        self?.loop()
                    }
                }
            }
            .store(in: &lifetime)
    }

    func heartbeat(date: Date) {
        deviceDataManager.heartbeat(date: date)
    }

    // Loop entry point
    private func loop() {
        Task { [weak self] in
            guard let self else { return }

            // Consume the user-initiated flag unconditionally — it was set
            // for the loop the user just triggered. If the guards below block
            // (suspended, too-soon, no pump), the next scheduled tick must
            // not inherit it and bypass dwell suppression for an error the
            // user didn't request.
            let userInitiated = self.nextLoopUserInitiated
            self.nextLoopUserInitiated = false

            // Don't try to run a loop while pump setup / pod pairing is in
            // progress — `verifyStatus` would throw `invalidPumpState("Pump
            // not set")` and surface a modal banner on top of the pod
            // activation sheet, closing the sheet (reported by tester during
            // O5 pairing).
            guard self.pumpManager != nil else {
                debug(.loop, "Loop skipped: no pump configured")
                return
            }

            guard UntetheredGate.phoneMayDose else {
                debug(.loop, "The watch is in charge of the pump (untethered) — skipping loop attempt")
                return
            }
            guard !UntetheredGate.watchRecordsPending else {
                debug(.loop, "Waiting for the watch's records after the take-back (untethered) — skipping loop attempt")
                return
            }
            // Before the loop starts, so the loop doses with the new profile.
            await self.therapyProfileManager?.runDueScheduledSwitch()

            // Atomic check-and-set via actor — eliminates the race between
            // checking isLooping.value and sending isLooping(true).
            guard await loopGuard.tryStart(
                minInterval: Config.loopInterval,
                lastLoopDate: lastLoopDate,
                lastLoopStartDate: lastLoopStartDate
            ) else {
                debug(.loop, "Loop skipped: already running or too soon")
                return
            }

            // Affects whether transient errors surface immediately instead of
            // dwell-suppressed (see `surfaceErrorIfNeeded`).
            self.currentLoopUserInitiated = userInitiated
            defer { self.currentLoopUserInitiated = false }

            // Start background task
            // we probably need to refactor this when implementing Swift 6 due to mutation of a captured var in an async context
            var taskID: UIBackgroundTaskIdentifier = .invalid
            taskID = await UIApplication.shared.beginBackgroundTask(withName: "Loop starting") {
                // closure runs on the Main Thread
                // removed the Task that provided no guarantee to end the background task
                if taskID != .invalid {
                    UIApplication.shared.endBackgroundTask(taskID)
                    taskID = .invalid
                }
            }

            isLooping.send(true)
            info(.loop, "Loop started, mode \(settings.dosingMode.rawValue)\(userInitiated ? ", requested by user" : "")")

            let loopStartDate = Date()
            lastLoopStartDate = loopStartDate
            let interval = await calculateLoopInterval(loopStartDate: loopStartDate)

            var loopStatRecord = LoopStats(
                start: loopStartDate,
                loopStatus: "Starting",
                interval: interval
            )

            do {
                let enacted = try await executeLoop(loopStatRecord: &loopStatRecord)
                requestNightscoutUpload(
                    [.carbs, .pumpHistory, .overrides, .tempTargets, .profiles],
                    source: "APSManager"
                )
                await finalizeLoop(enacted: enacted, loopStatRecord: loopStatRecord)
            } catch {
                let endDate = Date()
                loopStatRecord.end = endDate
                loopStatRecord.duration = roundDouble((endDate - loopStatRecord.start).timeInterval / 60, 2)
                loopStatRecord.loopStatus = error.localizedDescription
                await finalizeLoop(error: error, loopStatRecord: loopStatRecord)
            }

            // End the background task
            if taskID != .invalid {
                await UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
    }

    /// Returns whether the determination was enacted.
    private func executeLoop(loopStatRecord: inout LoopStats) async throws -> Bool {
        let determination = try await determineBasal()

        // Closed loop: also enact the determination.
        var enacted = false
        if settings.dosingMode.automation != .off {
            enacted = try await enactDetermination(id: determination?.id)
        }

        let endDate = Date()
        loopStatRecord.end = endDate
        loopStatRecord.duration = roundDouble((endDate - loopStatRecord.start).timeInterval / 60, 2)
        loopStatRecord.loopStatus = "Success"
        return enacted
    }

    private func calculateLoopInterval(loopStartDate: Date) async -> Double? {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "calculateLoopInterval"
        do {
            return try await context.perform { [weak self] in
                guard let self else { return nil }
                let requestStats = LoopStatRecord.fetchRequest() as NSFetchRequest<LoopStatRecord>
                let sortStats = NSSortDescriptor(key: "end", ascending: false)
                requestStats.sortDescriptors = [sortStats]
                requestStats.fetchLimit = 1
                let previousLoop = try context.fetch(requestStats)

                if (previousLoop.first?.end ?? .distantFuture) < loopStartDate {
                    return self.roundDouble(
                        (loopStartDate - (previousLoop.first?.end ?? Date())).timeInterval / 60,
                        1
                    )
                }
                return nil
            }
        } catch {
            warning(.storage, "Fetching the last loop for its interval failed", error: error)
            return nil
        }
    }

    /// Single exit point for loop — replaces the old `loopCompleted()`.
    private func finalizeLoop(error: Error? = nil, enacted: Bool = false, loopStatRecord: LoopStats) async {
        await loopGuard.finish()
        isLooping.send(false)

        if let error = error {
            warning(.loop, "Loop failed", error: error)
            processError(error)
        } else {
            info(.loop, "Loop finished in \(String(format: "%.1f", Date().timeIntervalSince(loopStatRecord.start))) s")
            lastLoopDate = Date()
            lastError.send(nil)
            transientCategoryFirstSeen.removeAll()
            transientCategoryCount.removeAll()
        }

        loopStats(loopStatRecord: loopStatRecord)

        if settings.dosingMode.automation != .off {
            await reportEnacted(wasEnacted: error == nil && enacted)
        }
    }

    private func verifyStatus() -> Error? {
        guard let pump = pumpManager else {
            return APSError.invalidPumpState(message: String(localized: "Pump not set"))
        }
        guard UntetheredGate.phoneMayDose else {
            return APSError.invalidPumpState(message: String(localized: "The watch is in charge of the pump"))
        }
        guard !UntetheredGate.watchRecordsPending else {
            return APSError.invalidPumpState(
                message: String(
                    localized: "The watch's records aren't in yet, so insulin on board is incomplete. Try again in a minute."
                )
            )
        }
        let status = pump.status.pumpStatus

        guard !status.bolusing else {
            return APSError.invalidPumpState(message: String(localized: "Pump is bolusing"))
        }

        guard !status.suspended else {
            return APSError.invalidPumpState(message: String(localized: "Pump suspended"))
        }

        return nil
    }

    private func autosense() async throws -> Bool {
        let autosense = await storage.retrieveAsync(OpenAPS.Settings.autosense, as: Autosens.self)
        guard OrefPipeline.autosensIsCurrent(autosense, now: Date()) else {
            let result = try await openAPS.autosense(
                shouldSmoothGlucose: settingsManager.settings.smoothGlucose
            )
            return result != nil
        }

        return false
    }

    /// Calculates and stores the Total Daily Dose (TDD)
    private func calculateAndStoreTDD() async throws {
        guard let pumpManager else { return }

        let basalProfile = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []

        // Calculate TDD; uncovered gaps are inferred from the basal profile in memory
        let tddResult = try await tddStorage.calculateTDD(
            pumpManager: pumpManager,
            pumpHistory: pumpHistoryStorage.getPumpHistory(),
            basalProfile: basalProfile
        )

        // Store TDD in Core Data
        await tddStorage.storeTDD(tddResult, at: Date())
    }

    @discardableResult private func determineBasal() async throws -> Determination? {
        try await calculateAndStoreTDD()

        var invalidGlucoseError: String?

        // Fetch glucose and run validation on the same context to avoid cross-context property access.
        let validationContext = CoreDataStack.shared.newTaskContext()
        validationContext.name = "determineBasal.validation"

        let isValidGlucoseData = await validationContext.perform { [weak self] in
            guard let self else { return false }

            let glucose: [GlucoseStored]
            do {
                glucose = try self.fetchGlucose(
                    on: validationContext,
                    predicate: NSPredicate.predicateForOneHourAgo,
                    fetchLimit: 6
                )
            } catch {
                warning(.loop, "Fetching glucose for validation failed", error: error)
                return false
            }

            guard glucose.count > 2 else {
                debug(.loop, "Glucose check failed: \(glucose.count) readings in the last hour, need 3")
                invalidGlucoseError =
                    String(
                        localized: "Not enough glucose data. You need at least three glucose readings in the last six hours to run the algorithm."
                    )
                return false
            }

            let dateOfLastGlucose = glucose.first?.date
            guard dateOfLastGlucose ?? Date() >= Date().addingTimeInterval(-12.minutes.timeInterval) else {
                debug(.loop, "Glucose check failed: latest reading older than 12 min")
                invalidGlucoseError =
                    String(localized: "Glucose data is stale. The most recent glucose reading is from more than 12 minutes ago.")
                return false
            }

            info(.loop, "Glucose ready: BG \(glucose.first?.glucose ?? 0) mg/dL, \(glucose.count) recent readings")
            return true
        }

        do {
            let now = Date()

            // put profile creation up front since autosens needs it
            try await openAPS.createProfiles(for: settingsManager.settings.dosingMode)
            let currentTemp = try await fetchCurrentTempBasal(date: now)
            _ = try await autosense()

            let determination = try await openAPS.determineBasal(
                for: settingsManager.settings.dosingMode,
                currentTemp: currentTemp,
                supportedBasalRates: supportedBasalRates,
                shouldSmoothGlucose: settingsManager.settings.smoothGlucose,
                clock: now
            )
            iobFileDidUpdate.send(())

            guard isValidGlucoseData else {
                throw APSError.glucoseError(message: "Glucose validation failed")
            }

            if let determination = determination {
                info(
                    .loop,
                    "Determination: eventual BG \(determination.eventualBG.map { "\($0) mg/dL" } ?? "none"), temp basal \(determination.rate.map { "\($0) U/h for \(determination.duration ?? 0) min" } ?? "none"), SMB \(determination.units ?? 0) U"
                )
                // Capture weak self in closure
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.broadcaster.notify(DeterminationObserver.self, on: .main) {
                        $0.determinationDidUpdate(determination)
                    }
                }
            }
            return determination
        } catch {
            iobFileDidUpdate.send(())

            // if we have a glucose validation error we might still run
            // determineBasal to try to get IoB and CoB updates but we
            // know that it will fail, so the invalidGlucoseError always
            // takes priority
            if let invalidGlucoseError = invalidGlucoseError {
                throw APSError.apsError(message: invalidGlucoseError)
            } else {
                throw APSError.apsError(message: "Error determining basal: \(error.localizedDescription)")
            }
        }
    }

    func determineBasalSync() async throws {
        // the watch's determinations arrive with its history
        guard UntetheredGate.phoneMayDose else { return }
        await loopGuard.waitForLoop()
        guard await loopGuard.tryStartStandaloneDetermination() else {
            debug(.loop, "Standalone determination skipped: one is already running")
            return
        }
        do {
            try await determineBasal()
        } catch {
            await loopGuard.finishStandaloneDetermination()
            throw error
        }
        await loopGuard.finishStandaloneDetermination()
    }

    func simulateDetermineBasal(
        simulatedCarbsAmount: Decimal,
        simulatedBolusAmount: Decimal,
        simulatedCarbsDate: Date? = nil
    ) async -> Determination? {
        do {
            let temp = try await fetchCurrentTempBasal(date: Date.now)
            return try await openAPS.determineBasal(
                for: settingsManager.settings.dosingMode,
                currentTemp: temp,
                supportedBasalRates: supportedBasalRates,
                shouldSmoothGlucose: settingsManager.settings.smoothGlucose,
                clock: Date(),
                simulatedCarbsAmount: simulatedCarbsAmount,
                simulatedBolusAmount: simulatedBolusAmount,
                simulatedCarbsDate: simulatedCarbsDate,
                simulation: true
            )
        } catch {
            warning(.algorithm, "Simulated determination failed", error: error)
            return nil
        }
    }

    /// The paired pump's deliverable basal rates, for the algorithm to round against.
    /// Rounded to 3 dp because the kits build their tables as `Double(n) / 20` and similar, and the
    /// resulting binary error would push an entry just above the clean rate it is meant to match.
    private var supportedBasalRates: [Decimal] {
        (pumpManager?.supportedBasalRates ?? []).map { Decimal($0).rounded(scale: 3) }
    }

    func roundBolus(amount: Decimal) -> Decimal {
        guard let pump = pumpManager else { return amount }
        let rounded = Decimal(pump.roundToSupportedBolusVolume(units: Double(amount)))
        let maxBolus = Decimal(pump.roundToSupportedBolusVolume(units: Double(settingsManager.pumpSettings.maxBolus)))
        return min(rounded, maxBolus)
    }

    func enactBolus(amount: Double, isSMB: Bool, callback: ((Bool, String) -> Void)?) async {
        let requestedAt = Date()
        // Answer every caller: a silent return here left the watch waiting on "Processing…" forever
        guard amount > 0 else {
            warning(.bolus, "Bolus of \(amount) U not enacted, amount must be above 0")
            callback?(false, Self.invalidBolusAmountMessage)
            return
        }

        if let error = verifyStatus() {
            warning(.bolus, "Bolus of \(amount) U not enacted", error: error)
            processError(error)
            // Capture broadcaster and queue before async context
            let broadcaster = self.broadcaster
            Task { @MainActor in
                broadcaster?.notify(BolusFailureObserver.self, on: .main) {
                    $0.bolusDidFail()
                }
            }
            callback?(false, String(localized: "Error! Failed to enact bolus.", comment: "Error message for enacting a bolus"))
            return
        }

        guard let pump = pumpManager else {
            callback?(false, String(localized: "Error! Failed to enact bolus.", comment: "Error message for enacting a bolus"))
            return
        }

        let roundedAmount = pump.roundToSupportedBolusVolume(units: amount)

        guard roundedAmount > 0 else {
            warning(.bolus, "Bolus of \(amount) U not enacted, rounds to 0 U on this pump")
            callback?(false, Self.invalidBolusAmountMessage)
            return
        }

        debug(.bolus, "Enacting bolus \(roundedAmount) U, \(isSMB ? "automatic" : "manual")")

        do {
            try await pump.enactBolus(units: roundedAmount, automatic: isSMB)
            PhoneLastDose.note()
            info(.bolus, "Bolus enacted: \(roundedAmount) U, \(isSMB ? "automatic" : "manual")")
            bolusProgress.send(0)
            callback?(true, String(localized: "Bolus enacted successfully.", comment: "Success message for enacting a bolus"))
            if !isSMB {
                do {
                    try await determineBasalSync()
                } catch {
                    warning(.loop, "Determination after manual bolus failed", error: error)
                }
            }
        } catch let bolusError {
            error(.bolus, "Bolus of \(roundedAmount) U failed", error: bolusError)
            lastError.send(APSError.pumpError(bolusError))
            // Refused before anything reached the pod: the watch had just looked at it, which counts as another
            // controller's session. The phone now asks the watch, and once it answers "not holding" the loop runs
            // again by itself (10 November, third tester: each refused loop dosed again within 5–8 s). Nothing was
            // given, so a bolus asked for by hand says that plainly instead of "check pump history"; an SMB says
            // nothing, as the loop that follows decides afresh.
            var retryError: Error?
            if String(describing: bolusError).contains("Another controller has used this pod") {
                if !isSMB {
                    switch await retryRefusedBolus(
                        units: roundedAmount,
                        requestedAt: requestedAt,
                        refusedAt: Date(),
                        pump: pump
                    ) {
                    case .given:
                        PhoneLastDose.note()
                        info(.bolus, "Bolus enacted on the second try: \(roundedAmount) U, manual")
                        bolusProgress.send(0)
                        callback?(
                            true,
                            String(localized: "Bolus enacted successfully.", comment: "Success message for enacting a bolus")
                        )
                        do {
                            try await determineBasalSync()
                        } catch {
                            warning(.loop, "Determination after manual bolus failed", error: error)
                        }
                        return
                    case let .failed(error):
                        // the second try reached the pod and failed there: what it gave isn't known
                        retryError = error
                    case .notTried,
                         .refusedAgain:
                        break
                    }
                }
            }
            if retryError == nil, String(describing: bolusError).contains("Another controller has used this pod") {
                // the refusal may also come from a session of the watch's the phone hadn't heard of: then the watch
                // has the pump (Ponytail's review, 15 November)
                let watchHasPump = await MainActor.run { () -> Bool in
                    let session = UntetheredGate.state.session
                    return !session.isIdle && !session.isCheckingForeignSession
                }
                let message = watchHasPump
                    ? String(
                        localized: "Nothing was given: the watch has the pump. Bolus on the watch.",
                        comment: "A bolus refused before it reached the pod, because the watch holds the pump"
                    )
                    : String(
                        localized: "Nothing was given: the watch was checking the pod. Please try again in a moment.",
                        comment: "A bolus refused before it reached the pod, because the watch had just looked at the pod"
                    )
                if isSMB {
                    debug(.bolus, "SMB of \(roundedAmount) U refused after the watch's look at the pod; the next loop decides")
                } else {
                    issueAlertForCategory(.bolusFailed, title: String(localized: "Bolus not given"), body: message)
                    let broadcaster = self.broadcaster
                    Task { @MainActor in
                        broadcaster?.notify(BolusFailureObserver.self, on: .main) {
                            $0.bolusDidFail()
                        }
                    }
                }
                callback?(false, message)
                return
            }
            // with the iPhone's Bluetooth off the pump reads as "not connected": say why (28 October, flight mode)
            let bluetoothOff = await MainActor.run { self.bluetoothManager?.bluetoothState == .poweredOff }
            let reason = bluetoothOff
                ? String(localized: "The iPhone's Bluetooth is off, so it couldn't reach the pump.")
                : (retryError ?? bolusError).localizedDescription
            issueAlertForCategory(
                .bolusFailed,
                title: String(localized: "Bolus failed"),
                body: String(localized: "Check pump history before repeating.")
                    + "\n\n\(reason)"
            )
            if !isSMB {
                let broadcaster = self.broadcaster
                Task { @MainActor in
                    broadcaster?.notify(BolusFailureObserver.self, on: .main) {
                        $0.bolusDidFail()
                    }
                }
            }
            callback?(
                false,
                String(localized: "Error! Bolus failed with error: \(reason)")
            )
        }
    }

    enum RefusedBolusRetry {
        case given
        case notTried
        case refusedAgain
        case failed(Error)
    }

    /// How long after the request the second try may start: a bolus asked for on the watch is then answered before the
    /// watch's 15 s acknowledgement wait ends, the bolus command taking a few seconds more. From the request, not the
    /// refusal: a slow first connect can take most of it (Claude Fable's review, 14 November).
    static let refusedBolusRetryWindow: TimeInterval = 11

    /// A bolus asked for by hand, refused before anything reached the pod because the watch had just looked at it.
    /// The phone asks the watch at once and, when the watch doesn't hold the pump, has it back within a second or two
    /// (third tester, 12 November: a 1.4 U bolus refused, the pump back on the phone 2 s later). The bolus is then given once
    /// more by itself instead of asking for it again; only after a return that ended a look and whose audit found no
    /// insulin from elsewhere, if no other dose went out since the refusal and none is running, and only within
    /// `refusedBolusRetryWindow`. The pump's return starts a loop: the second try waits for it and holds the loop off
    /// while it runs, so the loop's SMB and the bolus never pass each other unseen.
    private func retryRefusedBolus(
        units: Double,
        requestedAt: Date,
        refusedAt: Date,
        pump: PumpManager
    ) async -> RefusedBolusRetry {
        let deadline = requestedAt.addingTimeInterval(Self.refusedBolusRetryWindow)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard (PhonePumpReturn.date ?? .distantPast) > refusedAt else { continue }
            guard (PhonePumpReturn.cleanLookDate ?? .distantPast) > refusedAt else {
                debug(.bolus, "Refused bolus of \(units) U not tried again: the pump came back from more than a look")
                return .notTried
            }
            // the loop the return started goes first, then none starts until this try is done
            await loopGuard.waitForLoop()
            guard await loopGuard.tryClaim() else { continue }
            let outcome = await tryRefusedBolusOnce(units: units, refusedAt: refusedAt, deadline: deadline, pump: pump)
            await loopGuard.finish()
            // a loop the claim held off runs now, with this bolus (if given) in its records; as at the return, only for a
            // reading no loop has had yet
            if (glucoseStorage.lastGlucoseDate() ?? .distantPast) > lastLoopDate { heartbeat(date: Date()) }
            return outcome
        }
        debug(.bolus, "Refused bolus of \(units) U not tried again: the pump didn't come back in time")
        return .notTried
    }

    private func tryRefusedBolusOnce(
        units: Double,
        refusedAt: Date,
        deadline: Date,
        pump: PumpManager
    ) async -> RefusedBolusRetry {
        guard Date() < deadline, UntetheredGate.phoneMayDose,
              (PhoneLastDose.date ?? .distantPast) < refusedAt,
              !pump.status.pumpStatus.bolusing
        else {
            debug(.bolus, "Refused bolus of \(units) U not tried again: a dose went out meanwhile, it is too late, or the phone may not dose")
            return .notTried
        }
        debug(.bolus, "Bolus of \(units) U was refused after the watch's look at the pod; the pump is back, trying once more")
        do {
            try await pump.enactBolus(units: units, automatic: false)
            return .given
        } catch {
            if String(describing: error).contains("Another controller has used this pod") {
                warning(.bolus, "Second try of the bolus of \(units) U refused as well; nothing was given")
                return .refusedAgain
            }
            return .failed(error)
        }
    }

    static let invalidBolusAmountMessage = String(
        localized: "Error! Bolus amount must be greater than 0 U.",
        comment: "Error message when a bolus of zero or less is requested"
    )

    func cancelBolus(_ callback: ((Bool, String) -> Void)?) async {
        guard let pump = pumpManager, pump.status.pumpStatus.bolusing else { return }
        debug(.bolus, "Cancelling bolus")
        do {
            _ = try await pump.cancelBolus()
            info(.bolus, "Bolus cancelled")
            callback?(true, String(localized: "Bolus cancelled successfully.", comment: "Success message for canceling a bolus"))
        } catch let cancelError {
            error(.bolus, "Bolus cancellation failed", error: cancelError)
            lastError.send(APSError.pumpError(cancelError))
            issueAlertForCategory(
                .bolusFailed,
                title: String(localized: "Bolus cancellation failed"),
                body: String(localized: "Try again.") + "\n\n\(cancelError.localizedDescription)"
            )
            callback?(
                false,
                String(
                    localized: "Error! Bolus cancellation failed with error: \(cancelError.localizedDescription)",
                    comment: "Error message for canceling a bolus"
                )
            )
        }
        clearBolusReporter()
    }

    private func fetchCurrentTempBasal(date: Date) async throws -> TempBasal {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "fetchCurrentTempBasal"
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: context,
            predicate: NSPredicate.recentPumpHistory,
            key: "timestamp",
            ascending: false,
            fetchLimit: 1,
            relationshipKeyPathsForPrefetching: ["tempBasal"]
        )

        let fetchedTempBasal = await context.perform {
            guard let fetchedResults = results as? [PumpEventStored],
                  let tempBasalEvent = fetchedResults.first,
                  let tempBasal = tempBasalEvent.tempBasal,
                  let eventTimestamp = tempBasalEvent.timestamp
            else {
                return TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: date)
            }

            let delta = Int((date.timeIntervalSince1970 - eventTimestamp.timeIntervalSince1970) / 60)
            let duration = max(0, Int(tempBasal.duration) - delta)
            let rate = tempBasal.rate as? Decimal ?? 0
            return TempBasal(duration: duration, rate: rate, temp: .absolute, timestamp: date)
        }

        guard let state = pumpManager?.status.basalDeliveryState else { return fetchedTempBasal }

        switch state {
        case .active,
             .pumpInoperable:
            return TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: date)
        case let .tempBasal(dose):
            let rate = Decimal(dose.unitsPerHour)
            let durationMin = max(0, Int((dose.endDate.timeIntervalSince1970 - date.timeIntervalSince1970) / 60))
            return TempBasal(duration: durationMin, rate: rate, temp: .absolute, timestamp: date)
        default:
            return fetchedTempBasal
        }
    }

    /// Returns false when the determination is skipped because the pump is suspended.
    private func enactDetermination(id: UUID?) async throws -> Bool {
        // only the determination this cycle saved; never fall back to an older one
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "enactDetermination"
        guard let id, let values = try await Self.dosingValues(ofDeterminationWithID: id, on: context) else {
            throw APSError.apsError(message: "Determination not found")
        }

        guard let pump = pumpManager else {
            throw APSError.apsError(message: "Pump not set")
        }

        if pump.status.pumpStatus.suspended {
            info(.loop, "Determination not enacted: pump suspended")
            return false
        }

        // Unable to do temp basal during manual temp basal 😁
        if isManualTempBasal {
            throw APSError.manualBasalTemp(message: "Loop not possible during the manual basal temp")
        }

        let (rateDecimal, durationInSeconds, smbToDeliver) = values

        if let rate = rateDecimal, let duration = durationInSeconds {
            try await performBasal(pump: pump, rate: rate, duration: duration)
            PhoneLastDose.note()
            info(.loop, "Temp basal enacted: \(rate) U/h for \(Int(duration / 60)) min")
        }

        // only perform a bolus if smbToDeliver is > 0
        if let smb = smbToDeliver, smb.compare(NSDecimalNumber(value: 0)) == .orderedDescending {
            try await performBolus(pump: pump, smbToDeliver: smb)
            PhoneLastDose.note()
            info(.loop, "SMB enacted: \(smb) U")
        }
        return true
    }

    /// Temp basal and SMB of the determination with this id; nil if it wasn't saved or was already enacted.
    static func dosingValues(ofDeterminationWithID id: UUID, on context: NSManagedObjectContext) async throws
        -> (NSDecimalNumber?, TimeInterval?, NSDecimalNumber?)?
    {
        try await context.perform {
            let request = OrefDetermination.fetchRequest() as NSFetchRequest<OrefDetermination>
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            guard let determination = try context.fetch(request).first, !determination.enacted else { return nil }

            let rate = determination.rate
            let duration = determination.duration.flatMap { TimeInterval(truncating: $0) * 60 }
            let smbToDeliver = determination.smbToDeliver ?? 0

            return (rate, duration, smbToDeliver)
        }
    }

    private func performBasal(pump: PumpManager, rate: NSDecimalNumber, duration: TimeInterval) async throws {
        // the algorithm already floored this against the pump's own table, so don't floor it
        // again here: the Decimal -> Double hop can land a hair low and cost a whole increment
        let unitsPerHour = rate.decimalValue.nearestDouble
        if pump.roundToSupportedBasalRate(unitsPerHour: unitsPerHour) != unitsPerHour {
            debug(.pump, "Temp basal \(unitsPerHour) U/h is not on the pump's rate table")
        }
        try await pump.enactTempBasal(unitsPerHour: unitsPerHour, for: duration)
    }

    private func performBolus(pump: PumpManager, smbToDeliver: NSDecimalNumber) async throws {
        try await pump.enactBolus(units: smbToDeliver.decimalValue.nearestDouble, automatic: true)
        bolusProgress.send(0)
    }

    private func reportEnacted(wasEnacted: Bool) async {
        do {
            guard let determinationID = try await determinationStorage
                .fetchLastDeterminationObjectID(predicate: NSPredicate.predicateFor30MinAgoForDetermination).first
            else {
                debug(.loop, "No recent determination to mark as enacted")
                return
            }

            let context = CoreDataStack.shared.newTaskContext()
            context.name = "reportEnacted"
            try await context.perform {
                guard let determinationUpdated = try context
                    .existingObject(with: determinationID) as? OrefDetermination
                else {
                    debug(.loop, "Determination to mark as enacted no longer exists")
                    return
                }

                determinationUpdated.timestamp = Date()
                determinationUpdated.enacted = wasEnacted
                determinationUpdated.isUploadedToNS = false

                guard context.hasChanges else { return }
                try context.save()
                debug(.loop, "Determination marked as \(wasEnacted ? "enacted" : "not enacted")")
            }
        } catch {
            warning(.storage, "Saving the enacted status failed", error: error)
        }
    }

    private func roundDouble(_ double: Double, _ digits: Double) -> Double {
        let rounded = round(Double(double) * pow(10, digits)) / pow(10, digits)
        return rounded
    }

    /// Synchronously fetches glucose on the given context. Must be called from within a `perform`/`performAndWait` block of that context
    private func fetchGlucose(
        on context: NSManagedObjectContext,
        predicate: NSPredicate,
        fetchLimit: Int? = nil,
        batchSize: Int? = nil
    ) throws -> [GlucoseStored] {
        let results = try CoreDataStack.shared.fetchEntities(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: predicate,
            key: "date",
            ascending: false,
            fetchLimit: fetchLimit,
            batchSize: batchSize
        )
        guard let glucoseResults = results as? [GlucoseStored] else {
            throw CoreDataError.fetchError(function: #function, file: #file)
        }
        return glucoseResults
    }

    private func loopStats(loopStatRecord: LoopStats) {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "loopStats.save"
        context.perform {
            let nLS = LoopStatRecord(context: context)
            nLS.start = loopStatRecord.start
            nLS.end = loopStatRecord.end ?? Date()
            nLS.loopStatus = loopStatRecord.loopStatus
            nLS.duration = loopStatRecord.duration ?? 0.0
            nLS.interval = loopStatRecord.interval ?? 0.0

            do {
                guard context.hasChanges else { return }
                try context.save()
            } catch {
                warning(.storage, "Saving loop statistics failed", error: error)
            }
        }
    }

    private var transientCategoryFirstSeen: [String: Date] = [:]
    private var transientCategoryCount: [String: Int] = [:]
    private static let transientDwellThreshold: TimeInterval = 60
    private static let transientCountThreshold = 2

    /// Set by `markNextLoopUserInitiated()` (e.g. force-loop button), consumed
    /// on the next entry into `loop()` so that errors during a user-initiated
    /// loop surface immediately instead of being suppressed by dwell logic.
    @SyncAccess private var nextLoopUserInitiated: Bool = false
    private var currentLoopUserInitiated: Bool = false

    func markNextLoopUserInitiated() {
        nextLoopUserInitiated = true
    }

    private func processError(_ error: Error) {
        lastError.send(error)
        surfaceErrorIfNeeded(error)
    }

    private func surfaceErrorIfNeeded(_ error: Error) {
        let category = TrioAlertClassifier.categorize(error: error)
        let key = String(describing: category)

        if category.shouldFireImmediately || currentLoopUserInitiated {
            transientCategoryFirstSeen.removeValue(forKey: key)
            transientCategoryCount.removeValue(forKey: key)
            issueAlertForError(error, category: category)
            return
        }

        let now = Date()
        let firstSeen = transientCategoryFirstSeen[key] ?? now
        let count = (transientCategoryCount[key] ?? 0) + 1
        let dwellElapsed = now.timeIntervalSince(firstSeen)
        let dwellMet = dwellElapsed >= Self.transientDwellThreshold
        let countMet = count >= Self.transientCountThreshold

        if dwellMet || countMet {
            transientCategoryFirstSeen.removeValue(forKey: key)
            transientCategoryCount.removeValue(forKey: key)
            issueAlertForError(error, category: category)
        } else {
            transientCategoryFirstSeen[key] = firstSeen
            transientCategoryCount[key] = count
            debug(
                .alerts,
                "Alert for transient \(category) held back: \(count) of \(Self.transientCountThreshold) occurrences, \(Int(dwellElapsed)) of \(Int(Self.transientDwellThreshold)) s"
            )
        }
    }

    private func issueAlertForCategory(_ category: TrioAlertCategory, title: String, body: String) {
        let content = Alert.Content(
            title: title,
            body: body,
            acknowledgeActionButtonLabel: String(localized: "OK")
        )
        let alert = Alert(
            identifier: Alert.Identifier(managerIdentifier: "trio.aps", alertIdentifier: category.alertIdentifier),
            foregroundContent: content,
            backgroundContent: content,
            trigger: .immediate,
            interruptionLevel: category.interruptionLevel
        )
        trioAlertManager?.issueAlert(alert)
    }

    private func issueAlertForError(_ error: Error, category: TrioAlertCategory) {
        let (title, body) = describeForAlert(error)
        let content = Alert.Content(
            title: title,
            body: body,
            acknowledgeActionButtonLabel: "OK"
        )
        let alert = Alert(
            identifier: Alert.Identifier(managerIdentifier: "trio.aps", alertIdentifier: category.alertIdentifier),
            foregroundContent: content,
            backgroundContent: content,
            trigger: .immediate,
            interruptionLevel: category.interruptionLevel
        )
        trioAlertManager?.issueAlert(alert)
    }

    private func describeForAlert(_ error: Error) -> (title: String, body: String) {
        if let apsError = error as? APSError {
            switch apsError {
            case let .pumpError(inner):
                return (
                    String(localized: "Pump Error"),
                    String(localized: "Trio could not communicate with the pump. Check the pump and try again.")
                        + "\n\n\(inner.localizedDescription)"
                )
            case let .invalidPumpState(message): return (String(localized: "Pump State Error"), message)
            case let .glucoseError(message): return (String(localized: "Glucose Error"), message)
            case let .apsError(message): return (String(localized: "Algorithm Error"), message)
            case let .manualBasalTemp(message): return (String(localized: "Manual Temp Basal Active"), message)
            }
        }
        return ("Trio", error.localizedDescription)
    }

    /// Called from the `bolusTrigger` Combine sink (already on
    /// `processQueue`) and from `doseProgressReporterDidUpdate` (the
    /// pump manager schedules the callback on `processQueue` too).
    /// Mutations are dispatched onto the queue regardless, so a future
    /// caller from another context (e.g. `cancelBolus`) stays safe.
    private func createBolusReporter() {
        if bolusReporter != nil {
            return
        }

        processQueue.async {
            self.bolusReporter = self.pumpManager?.createBolusProgressReporter(reportingOn: self.processQueue)
            self.bolusReporter?.addObserver(self)
        }
    }

    private func clearBolusReporter() {
        processQueue.async {
            self.bolusReporter?.removeObserver(self)
            self.bolusReporter = nil
            self.bolusProgress.send(nil)
        }
    }
}

private extension PumpManager {
    func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.enactTempBasal(decisionId: nil, unitsPerHour: unitsPerHour, for: duration) { error in
                if let error = error {
                    debug(.pump, "Temp basal command failed: \(unitsPerHour) U/h for \(Int(duration / 60)) min")
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func enactBolus(units: Double, automatic: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let automaticValue = automatic ? BolusActivationType.automatic : BolusActivationType.manualRecommendationAccepted

            self.enactBolus(decisionId: nil, units: units, activationType: automaticValue) { error in
                if let error = error {
                    debug(.pump, "Bolus command failed: \(units) U")
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func cancelBolus() async throws -> DoseEntry? {
        try await withCheckedThrowingContinuation { continuation in
            self.cancelBolus { result in
                switch result {
                case let .success(dose):
                    continuation.resume(returning: dose)
                case let .failure(error):
                    continuation.resume(throwing: APSError.pumpError(error))
                }
            }
        }
    }
}

extension BaseAPSManager: SettingsObserver {
    func settingsDidChange(_ settings: TrioSettings) {
        let previous = lastDosingMode
        lastDosingMode = settings.dosingMode

        // Only basal testing clears a running temp. Elsewhere it may be protecting against a low,
        // and dropping back to scheduled basal would remove that protection.
        // If the watch owns the pump, its loop performs this cleanup on the watch instead.
        guard UntetheredGate.phoneMayDose else { return }
        guard settings.dosingMode == .basalTesting, previous != .basalTesting else { return }

        Task { await cancelAutomaticTempBasal() }
    }

    /// Clears a Trio-set temp so a basal test starts from the scheduled rate.
    private func cancelAutomaticTempBasal() async {
        guard let pump = pumpManager else { return }

        // A temp the user set on the pump is theirs to cancel.
        guard !isManualTempBasal else { return }
        guard case let .tempBasal(dose) = pump.status.basalDeliveryState, dose.automatic ?? true else { return }

        do {
            try await pump.enactTempBasal(unitsPerHour: 0, for: 0)
            info(.pump, "Temp basal cancelled for basal testing")
        } catch {
            warning(.pump, "Cancelling temp basal for basal testing failed", error: error)
            processError(APSError.pumpError(error))
        }
    }
}

extension BaseAPSManager: DoseProgressObserver {
    func doseProgressReporterDidUpdate(_ doseProgressReporter: DoseProgressReporter) {
        bolusProgress.send(Decimal(doseProgressReporter.progress.percentComplete))
        if doseProgressReporter.progress.isComplete {
            clearBolusReporter()
        }
    }
}

extension PumpManagerStatus {
    var pumpStatus: PumpStatus {
        let bolusing = bolusState != .noBolus
        // A halted patch or faulted pod reports .pumpInoperable; never loop against it.
        let suspended = basalDeliveryState.map { $0.isSuspended || $0 == .pumpInoperable } ?? true
        let type = suspended ? StatusType.suspended : (bolusing ? .bolusing : .normal)
        return PumpStatus(status: type, bolusing: bolusing, suspended: suspended, timestamp: Date())
    }
}

/// When the pump last came back to the phone from the watch, or from a look of the watch's at the pod.
enum PhonePumpReturn {
    private static let key = "untethered.phonePumpReturnDate"
    private static let cleanLookKey = "untethered.phonePumpReturnCleanLookDate"

    static var date: Date? {
        UserDefaults.standard.object(forKey: key) as? Date
    }

    /// The last return that ended a look only: the watch answered "not holding" for the phone's own session, and the
    /// pod's delivered total matched the records. Only after such a return may a refused bolus be given by itself: after
    /// any other (the watch ran a session, released, or the audit booked insulin no record explains) the bolus was
    /// worked out without insulin the phone didn't know of (Claude Fable's review, 14 November).
    static var cleanLookDate: Date? {
        UserDefaults.standard.object(forKey: cleanLookKey) as? Date
    }

    static func note(_ date: Date = Date(), cleanLook: Bool) {
        UserDefaults.standard.set(date, forKey: key)
        if cleanLook { UserDefaults.standard.set(date, forKey: cleanLookKey) }
    }
}

/// When the phone last enacted a dose command on the pod: a temp basal or a bolus, automatic or by hand. Sent to the
/// watch with its state, where it counts as word from the phone besides its readings: a phone that doses is looping,
/// even when one of its readings didn't come (8 November, 17:21: the watch looked at the pod a minute after the phone's
/// bolus, its newest reading being 5.5 minutes old). Pod contact alone doesn't count: a phone without a sensor still
/// reaches the pod for status reads and heartbeats, and that would keep the watch from taking over from a phone that
/// can't loop (8 November, 11:48 to 14:06).
enum PhoneLastDose {
    private static let key = "untethered.phoneLastDoseDate"

    static var date: Date? {
        UserDefaults.standard.object(forKey: key) as? Date
    }

    static func note(_ date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: key)
    }
}
