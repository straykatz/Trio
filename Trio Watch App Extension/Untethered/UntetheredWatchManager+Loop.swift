import Foundation
import OmnipodKit
import HealthKit
import LoopKit
import SwiftUI
import UserNotifications
import WatchConnectivity
import WatchKit

// MARK: - The loop

/// As on the phone, only a new reading loops: its pump heartbeat and timers start no loop (`FetchGlucoseManager`
/// heartbeats after storing a new reading, `pumpManagerBLEHeartbeatDidFire` does nothing).
enum UntetheredLoopTrigger {
    /// A new CGM reading: the loop.
    case newGlucose
    /// Carbs, a bolus, an override or a temp target changed what the algorithm reads: a determination for
    /// the screens without dosing, as the phone's `determineBasalSync`.
    case treatment
    /// A dosing mode changed: determine and enact again with that mode's constraints on the current readings.
    case modeChanged
    /// The pod link came back after this reading's loop failed to reach the pod: the same loop again, at once
    /// rather than at the next reading.
    case podBack
}

extension UntetheredWatchManager {
    /// One cycle, as the phone's `APSManager.loop()`: refresh the pump, determine, enact, record.
    func runLoop(_ trigger: UntetheredLoopTrigger) {
        // a hand-back doses on while its history drains, until its last stage
        let phase = data.session.phase
        guard phase == .active || (phase == .ending && !isFinalizing), !data.podEnded, let pump = pumpManager,
              let grant = data.grant else { return }
        if let quietUntil = podQuietUntil, Date() < quietUntil {
            Task { await WatchLogger.shared.log("⌚️ Untethered: loop skipped, the iPhone is taking the pod back", force: true) }
            return
        }
        guard !isLooping else {
            // as `determineBasalSync`, which waits for a loop in flight: run once it is done
            if trigger == .treatment { isDeterminationPending = true }
            if trigger == .modeChanged { isModeChangePending = true }
            return
        }
        let newestGlucose = data.glucose.map(\.dateString).max()
        // each reading loops once; the phone's last loop, carried over at the takeover, counts as one
        if trigger == .newGlucose, let used = data.lastLoopGlucose, let newestGlucose, newestGlucose <= used { return }
        let enacts = trigger != .treatment
        isLooping = true
        if enacts { store.update { $0.lastLoopGlucose = newestGlucose } }
        // A Bluetooth wake often comes with almost no time from watchOS; without time of its own the app can be
        // suspended in the middle of reaching the pod, and the loop stalls until the app is opened.
        loopHoldExpired = false
        let releaseHold = Self.holdProcess(
            reason: "Untethered loop",
            upTo: Self.loopHoldLimit + (trigger == .newGlucose ? Self.sensorQuietLimit + Self.sensorQuietMargin : 0)
        ) { [weak self] in
            self?.loopHoldExpired = true
        }
        Self.trace("loop started (\(trigger))")
        Task { @MainActor in
            defer {
                self.isLooping = false
                if self.isModeChangePending {
                    self.isModeChangePending = false
                    self.runLoop(.modeChanged)
                } else if self.isDeterminationPending {
                    self.isDeterminationPending = false
                    self.runLoop(.treatment)
                }
                if trigger == .podBack, self.podFrontTry == .running { self.podFrontTry = nil }
                if self.podFrontTry == .pending { self.retryPodInFront() }
                self.endLoopHold(releaseHold)
            }
            // the pod only once the sensor's link is closed (see `waitForSensorQuiet`)
            if trigger == .newGlucose {
                await self.waitForSensorQuiet()
                Self.trace("sensor link quiet, to the pod")
                // the session may have ended meanwhile (2026-10-23 08:25:46: a loop ran on after the hand-back)
                guard self.isActive else { return }
            }
            // the pod read is a pod command too: none without background time left (see `enact`)
            var explained = true
            var podReached = true
            if enacts, !self.loopHoldExpired {
                let synced = await withCheckedContinuation { (continuation: CheckedContinuation<Date?, Never>) in
                    pump.ensureCurrentPumpData { continuation.resume(returning: $0) }
                }
                // pod data older than the kit's own 6 minutes: the pod didn't answer this loop
                podReached = synced.map { Date().timeIntervalSince($0) <= 6 * 60 } ?? false
                // before the determination, so its IOB counts what the records miss
                explained = self.podTotalExplained(pump, grant: grant)
            }
            self.expireAdjustments(now: Date())
            self.checkLinkedOverride()
            let now = Date()
            self.store.trim(now: now)
            // the loop as the phone gets it, for the watch's own Nightscout upload
            var forNightscout: (determination: Determination, enactedAt: Date?)?
            do {
                // as `APSManager.determineBasal`: three readings in the last hour, the newest at most 12 minutes old
                let lastHour = self.store.data.glucose.filter { $0.dateString >= now.addingTimeInterval(-60 * 60) }
                guard lastHour.count > 2 else { throw UntetheredWatchError.notEnoughGlucose }
                guard let newest = lastHour.map(\.dateString).max(), newest >= now.addingTimeInterval(-12 * 60) else {
                    throw UntetheredWatchError.staleGlucose
                }
                // as `APSManager.calculateAndStoreTDD`, before the determination reads it
                if enacts { self.calculateTDD(pump: pump, grant: grant, now: now) }
                let previousAutosens = self.store.data.autosens?.timestamp
                let inputs = self.loopInputs(pump: pump, grant: grant, now: now)
                guard let result = try await Task.detached(operation: { try UntetheredAlgorithm.determine(inputs) }).value
                else { throw UntetheredWatchError.noDetermination }
                let (determination, autosens) = result
                if let autosens, let timestamp = autosens.timestamp, timestamp != previousAutosens {
                    // the phone continues from it after the hand-back
                    self.store.record(
                        UntetheredRecord(
                            key: UntetheredRecord.autosensKey(timestamp),
                            date: timestamp,
                            kind: .autosens(autosens)
                        ),
                        epoch: self.data.session.epoch
                    )
                }
                self.store.update {
                    $0.autosens = autosens
                    $0.lastDetermination = determination
                }
                // one version for the phone, with its forecasts and whether the pump took it, as the phone's own
                // determination is marked enacted after the pump acted
                let key = UntetheredRecord.determinationKey(determination.deliverAt ?? now)
                let epoch = self.data.session.epoch
                func record(enactedAt: Date?) {
                    self.store.record(
                        UntetheredRecord(key: key, date: now, kind: .determination(determination, enactedAt: enactedAt)),
                        epoch: epoch
                    )
                    forNightscout = (determination, enactedAt)
                }
                func looped() {
                    self.store.update {
                        $0.lastLoopDate = now
                        $0.lastLoopError = nil
                    }
                    self.podLinkRecovered(pump)
                    self.podRetryPending = nil
                }
                if enacts {
                    do {
                        // a loop that didn't reach the pod isn't one, also when it had nothing to send: such loops
                        // counted as done and kept the stall from being noticed (15 November, 22:41 to 23:06)
                        guard podReached else { throw UntetheredWatchError.podNotConnected }
                        // A selection made while this determination was running invalidates its old permissions.
                        guard self.data.grant?.dosingMode == grant.dosingMode else {
                            record(enactedAt: nil)
                            return
                        }
                        if grant.dosingMode.automation == .off || !explained {
                            // with insulin the records don't explain, this loop doses nothing (`podTotalExplained`),
                            // and a high temp an earlier loop set doesn't run on
                            if !explained { await self.cancelHighTemp(pump, grant: grant) }
                            record(enactedAt: nil)
                            looped()
                        } else {
                            let enacted = try await self.enact(determination, pump: pump, dosingMode: grant.dosingMode)
                            record(enactedAt: enacted ? Date() : nil)
                            looped()
                            self.scheduleNotLoopingAlert(from: now)
                            self.recordPumpStatus()
                            self.store.record(
                                UntetheredRecord(
                                    key: UntetheredRecord.loopCompletedKey,
                                    date: now,
                                    kind: .loopCompleted(now)
                                ),
                                epoch: self.data.session.epoch
                            )
                        }
                    } catch {
                        record(enactedAt: nil)
                        throw error
                    }
                    let rate = determination.rate.map { "\($0) U/h" } ?? "-"
                    let smb = determination.units.map { "\($0) U" } ?? "-"
                    let battery = Self.batteryText
                    Task {
                        await WatchLogger.shared.log(
                            "⌚️ Untethered loop: BG \(determination.bg ?? 0), temp \(rate), SMB \(smb), battery \(battery)",
                            force: true
                        )
                    }
                } else {
                    record(enactedAt: nil)
                }
            } catch {
                // a failed determination for the screens is no loop error
                if enacts { self.store.update { $0.lastLoopError = error.localizedDescription } }
                Task { await WatchLogger.shared.log("⌚️ Untethered loop failed: \(error)", force: true) }
                // refused because the phone used the pod: it has the pump now
                if self.yieldIfPhoneTookPod() { return }
                // the pod out of reach: loop again as soon as its link is back, not only at the next reading
                if enacts, String(describing: error).contains("podNotConnected") || String(describing: error).contains("commsError") {
                    self.podRetryPending = (newestGlucose ?? .distantPast, Date())
                    self.podLinkFailures.append(Date())
                    if self.podLinkFailures.count > 12 { self.podLinkFailures.removeFirst(self.podLinkFailures.count - 12) }
                    // the try with Trio in front failed too: opening Trio doesn't bring the pod back
                    if trigger == .podBack, self.podFrontTry == .running {
                        self.requestHandback(minutes: max(1, Int(Date().timeIntervalSince(self.loopReference ?? Date()) / 60)), reason: .podStall)
                    }
                    self.checkPodLinkEarly()
                }
            }
            if !self.loopHoldExpired, self.isActive {
                await self.uploadToNightscout(forNightscout, grant: grant)
            }
            self.refresh()
            self.streamRecords()
            self.publishToWatchState()
        }
    }

    /// With the phone out of reach, the readings and the loop's status go to Nightscout from the watch
    /// (`WatchNightscoutUploader`); with the phone in reach it uploads what the watch streams to it, as before. A
    /// status that went up is noted in the history, so the phone doesn't upload that loop again after the hand-back.
    @MainActor func uploadToNightscout(_ loop: (determination: Determination, enactedAt: Date?)?, grant: UntetheredGrant) async {
        guard !WCSession.default.isReachable, await WatchNightscoutUploader.shared.isConfigured else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let status = loop.flatMap { loop in
            try? UntetheredNightscout.deviceStatus(
                determination: loop.determination,
                enactedAt: loop.enactedAt,
                automates: grant.dosingMode.automation != .off,
                units: grant.units,
                bolusIncrement: grant.preferences.bolusIncrement,
                dosingMode: grant.dosingMode.rawValue,
                version: version
            )
        }
        // the session's own doses and carbs: the phone's copy uploaded them before the start
        let now = Date()
        let treatments = UntetheredNightscout.treatments(
            pumpHistory: data.pumpHistory,
            carbs: data.carbs,
            since: data.session.startStatus?.date ?? now.addingTimeInterval(-6 * 60 * 60),
            now: now,
            sessionStart: data.session.startStatus?.date,
            tempTargets: data.tempTargets,
            overrides: data.endedOverrides + (activeOverride(at: now).map { [Self.overrideRun($0, endedAt: nil)] } ?? [])
        )
        let outcome = await WatchNightscoutUploader.shared.upload(glucose: data.glucose, status: status, treatments: treatments)
        if outcome.statusUploaded, let deliverAt = loop?.determination.deliverAt {
            store.record(
                UntetheredRecord(key: UntetheredRecord.nightscoutKey(deliverAt), date: Date(), kind: .nightscoutUploaded(deliverAt)),
                epoch: data.session.epoch
            )
        }
        guard outcome.entries > 0 || outcome.statusUploaded || outcome.treatments > 0 || outcome.failure != nil else { return }
        let what = "\(outcome.entries) reading(s)" + (outcome.statusUploaded ? ", the loop's status" : "")
            + (outcome.treatments > 0 ? ", \(outcome.treatments) treatment(s)" : "")
        let line = outcome.failure.map { "⌚️ Nightscout: upload failed (\($0)) after \(what)" } ?? "⌚️ Nightscout: uploaded \(what)"
        Task { await WatchLogger.shared.log(line, force: true) }
    }

    func loopInputs(pump: PumpManager, grant: UntetheredGrant, now: Date) -> UntetheredAlgorithm.Inputs {
        let data = store.data
        let currentTemp: TempBasal
        switch pump.status.basalDeliveryState {
        case let .tempBasal(dose):
            currentTemp = TempBasal(
                duration: max(0, Int((dose.endDate.timeIntervalSince1970 - now.timeIntervalSince1970) / 60)),
                rate: Decimal(dose.unitsPerHour),
                temp: .absolute,
                timestamp: now
            )
        case .active:
            currentTemp = TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: now)
        default:
            currentTemp = UntetheredAlgorithm.historyTempBasal(data.pumpHistory, now: now)
        }
        return UntetheredAlgorithm.Inputs(
            grant: grant,
            pumpHistory: UntetheredAlgorithm.withoutOrphanedResumes(data.pumpHistory).sorted { $0.timestamp > $1.timestamp },
            glucose: UntetheredAlgorithm.algorithmGlucose(
                data.glucose,
                smoothed: data.smoothedGlucose,
                smoothing: grant.smoothGlucose
            ),
            carbs: data.carbs,
            tempTargets: data.tempTargets,
            activeTempTarget: activeTempTarget(at: now),
            override: activeOverride(at: now),
            autosens: data.autosens,
            tdd: UntetheredAlgorithm.tddSummary(rows: data.tddRows, hours: data.tddHours, now: now) ?? grant.tdd,
            hasSufficientTDD: UntetheredAlgorithm.hasSufficientTDD(hours: data.tddHours, now: now) ?? grant.hasSufficientTDD,
            currentTemp: currentTemp,
            supportedBasalRates: pump.supportedBasalRates.map { Decimal($0) },
            now: now
        )
    }

    /// As `APSManager.calculateAndStoreTDD`: a TDD row from the last day of pump history, kept for the
    /// averages and sent to the phone.
    func calculateTDD(pump: PumpManager, grant: UntetheredGrant, now: Date) {
        let result = TDDCalculator.calculate(
            pumpHistory: store.data.tddPumpHistory.sorted { $0.timestamp > $1.timestamp },
            basalProfile: grant.basalProfile,
            now: now,
            roundToSupportedBasalRate: pump.roundToSupportedBasalRate
        )
        let data = store.data
        let weightedAverage = UntetheredAlgorithm.weightedAverage(
            rows: data.tddRows,
            hours: data.tddHours,
            weight: grant.preferences.weightPercentage,
            now: now
        )
        let row = UntetheredTDD(
            date: now,
            total: result.total,
            bolus: result.bolus,
            tempBasal: result.tempBasal,
            scheduledBasal: result.scheduledBasal,
            weightedAverage: weightedAverage
        )
        store.update {
            $0.tddRows.append(row)
            UntetheredTDDHour.add(row, to: &$0.tddHours)
            $0.tddHours = UntetheredTDDHour.inWindow($0.tddHours, now: now)
        }
        store.record(UntetheredRecord(key: UntetheredRecord.tddKey(now), date: now, kind: .tdd(row)), epoch: data.session.epoch)
    }

    /// The phone's `exponentialSmoothingGlucose` over the watch's readings: CGM only, the last day, at most
    /// `GlucoseSmoothing.maximumReadings`.
    func smoothGlucose() {
        guard data.grant?.smoothGlucose == true else { return }
        let dayAgo = Date().addingTimeInterval(-24 * 60 * 60)
        let readings = data.glucose
            .filter { $0.sgv != nil && $0.dateString >= dayAgo }
            .sorted { $0.dateString < $1.dateString }
            .suffix(GlucoseSmoothing.maximumReadings)
        let smoothed = GlucoseSmoothing.smoothed(readings.map { (date: $0.dateString, glucose: $0.sgv ?? 0) })
        store.update { data in
            for (reading, value) in zip(readings, smoothed) {
                if let value { data.smoothedGlucose[reading.id] = value }
            }
        }
    }

    /// The phone's `APSManager.enactDetermination`: false when nothing could be enacted (a suspended or inoperable
    /// pod), as the phone records it.
    private func enact(_ determination: Determination, pump: PumpManager, dosingMode: DosingMode) async throws -> Bool {
        if case .suspended = pump.status.basalDeliveryState { return false }
        // a halted patch or faulted pod reports .pumpInoperable: never loop against it, as the phone (Trio 469033590)
        if case .pumpInoperable = pump.status.basalDeliveryState { return false }
        // a loop that waited on the pod link past the hand-back's last stage, or into the phone's take-back minute,
        // sends nothing: the watch's last records already went to the phone
        guard mayDose else { throw UntetheredWatchError.noPump }
        // a pod command watchOS can freeze half-way is what leaves the pod link stuck (2026-10-19 08:09,
        // 2026-10-20 02:25 and 12:11): none starts once the loop has no background time left
        guard !loopHoldExpired else { throw UntetheredWatchError.noBackgroundTime }
        var sentTemp = false
        if let rate = determination.rate, let duration = determination.duration {
            try await pump.enactTempBasal(
                unitsPerHour: rate.nearestDouble,
                for: TimeInterval(truncating: duration as NSNumber) * 60
            )
            sentTemp = true
        }
        // as the phone: no SMB on top of a bolus still running, e.g. the meal bolus just started
        if data.grant?.dosingMode == dosingMode, let units = determination.units, units > 0,
           pump.status.bolusState == .noBolus
        {
            guard !loopHoldExpired else { throw UntetheredWatchError.noBackgroundTime }
            guard mayDose else { throw UntetheredWatchError.noPump }
            try await pump.enactBolus(units: units.nearestDouble, automatic: true)
            return true
        }
        if !sentTemp { await readPodAheadOfNextWake(pump) }
        return true
    }

    /// Test (20 November, first tester): a background wake that sends the pod nothing skips the pod read (its data
    /// is under 6 minutes old), so the next wake's is 10 minutes old; when that wake changes the temp basal it needs a
    /// read, a cancel and the new temp, 6 pod messages, and each such wake added 14 or 15 to the watchOS count that
    /// cuts all of Trio's links near 200. Wakes of 2 or 4 messages added nothing. The quiet wake reads instead.
    private func readPodAheadOfNextWake(_ pump: PumpManager) async {
        guard WKApplication.shared().applicationState != .active, !loopHoldExpired, mayDose,
              let omnipod = pump as? OmniPumpManager else { return }
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Date?, Never>) in
            omnipod.readStatusIfOlder(than: 2 * 60) { continuation.resume(returning: $0) }
        }
    }

    /// The watch may still command the pod: the session runs (a hand-back until its last stage) and the phone isn't
    /// taking the pod back. `runLoop` checks this at the start; a dose checks it again after the waits on the pod.
    var mayDose: Bool {
        let phase = data.session.phase
        guard phase == .active || (phase == .ending && !isFinalizing) else { return false }
        return podQuietUntil.map { Date() >= $0 } ?? true
    }

    func activeOverride(at date: Date) -> Override? {
        guard let override = store.data.activeOverride, override.enabled else { return nil }
        if override.indefinite { return override }
        return override.date.addingTimeInterval(Double(truncating: override.duration as NSNumber) * 60) > date ? override : nil
    }

    func activeTempTarget(at date: Date) -> TempTarget? {
        guard let last = store.data.tempTargets.max(by: { $0.createdAt < $1.createdAt }), last.duration > 0,
              last.createdAt.addingTimeInterval(Double(truncating: last.duration as NSNumber) * 60) > date
        else { return nil }
        return last
    }

    /// Untethered mode started from an override ends with it, once the phone can take the pump.
    func checkLinkedOverride() {
        guard data.session.phase == .active, let linked = data.session.linkedOverrideID else { return }
        guard activeOverride(at: Date())?.id != linked, !isBolusing else { return }
        if WCSession.default.isReachable { end() }
    }
}

enum UntetheredWatchError: LocalizedError {
    case noDetermination
    case noPump
    case notEnoughGlucose
    case staleGlucose
    case noBackgroundTime
    case podNotConnected

    var errorDescription: String? {
        switch self {
        case .notEnoughGlucose: return String(localized: "Not enough glucose data: at least three readings in the last hour are needed.")
        case .staleGlucose: return String(localized: "Glucose data is stale: the most recent reading is more than 12 minutes old.")
        case .noDetermination: return String(localized: "The algorithm gave no result.")
        case .noPump: return String(localized: "The watch doesn't have the pump.")
        case .noBackgroundTime: return String(localized: "watchOS gave the watch no background time for the pump.")
        case .podNotConnected: return String(localized: "The watch couldn't reach the pod.")
        }
    }
}

extension PumpManager {
    func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enactTempBasal(decisionId: nil, unitsPerHour: unitsPerHour, for: duration) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func enactBolus(units: Double, automatic: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enactBolus(decisionId: nil, units: units, activationType: automatic ? .automatic : .manualRecommendationAccepted) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

// MARK: - Bolus recommendation

extension UntetheredWatchManager {
    /// What the phone answers a watch's request with (`BaseWatchManager`, `requestBolusRecommendation`):
    /// a loop simulated with the entered carbs sets the safety floor, then the phone's bolus calculator runs
    /// on the watch's own determination, glucose and settings.
    func recommendBolus(carbs: Int, useReducedBolus: Bool, useSuperBolus: Bool) async -> Decimal {
        guard let grant = data.grant, let pump = pumpManager else { return 0 }
        let now = Date()
        let settings = grant.bolusCalculator
        let useReducedBolus = useReducedBolus && settings.fattyMeals
        let useSuperBolus = !useReducedBolus && useSuperBolus && settings.sweetMeals
        let determination = data.lastDetermination
            .flatMap { ($0.deliverAt ?? .distantPast) > now.addingTimeInterval(-30 * 60) ? $0 : nil }

        var minPredBG = determination?.minPredBGFromReason ?? 54
        if carbs > 0 {
            var inputs = loopInputs(pump: pump, grant: grant, now: now)
            inputs.carbs.append(CarbsEntry(
                id: UUID().uuidString, createdAt: now, actualDate: now, carbs: Decimal(carbs), fat: 0, protein: 0,
                note: nil, enteredBy: CarbsEntry.local, isFPU: false, fpuID: nil
            ))
            if let simulated = try? await Task.detached(operation: { try UntetheredAlgorithm.determine(inputs) }).value?.0
                .minPredBGFromReason
            {
                minPredBG = simulated
            }
        }

        func current(_ entries: [(start: String, value: Decimal)]) -> Decimal {
            BolusCalculator.scheduleValue(entries, at: now)
        }
        let glucose = BolusCalculator.glucoseVariables(
            newestFirst: data.glucose.sorted { $0.dateString > $1.dateString }
                .map { (date: $0.dateString, glucose: Decimal($0.glucose ?? $0.sgv ?? 0)) },
            now: now
        )
        let input = CalculationInput(
            carbs: Decimal(carbs),
            currentBG: glucose.currentBG,
            deltaBG: glucose.deltaBG,
            target: determination?.current_target ?? current(grant.bgTargets.targets.map { ($0.start, $0.low) }),
            isf: determination?.isf ?? current(grant.insulinSensitivities.sensitivities.map { ($0.start, $0.sensitivity) }),
            carbRatio: determination?.carbRatio ?? current(grant.carbRatios.schedule.map { ($0.start, $0.ratio) }),
            iob: determination?.iob ?? 0,
            cob: Int16(truncatingIfNeeded: NSDecimalNumber(
                decimal: (determination?.cob ?? 0)
                    .rounded(scale: 0, roundingMode: .down)
            ).intValue),
            useFattyMealCorrectionFactor: useReducedBolus,
            fattyMealFactor: settings.fattyMealFactor,
            useSuperBolus: useSuperBolus,
            sweetMealFactor: settings.sweetMealFactor,
            basal: current(grant.basalProfile.map { ($0.start, $0.rate) }),
            fraction: settings.fraction,
            maxBolus: grant.pumpSettings.maxBolus,
            // the dosing mode's limit, as the phone's calculator reads it
            maxIOB: grant.preferences.clamped(for: grant.dosingMode).maxIOB,
            maxCOB: grant.preferences.maxCOB,
            minPredBG: minPredBG,
            lastLoopDate: data.lastLoopDate ?? .distantPast
        )
        // as `APSManager.roundBolus`: the pump's increment, never above max bolus
        let maxBolus = Decimal(pump.roundToSupportedBolusVolume(units: grant.pumpSettings.maxBolus.nearestDouble))
        return BolusCalculator.calculate(input) {
            min(Decimal(pump.roundToSupportedBolusVolume(units: $0.nearestDouble)), maxBolus)
        }.insulinCalculated
    }
}

// MARK: - Treatments on the wrist

extension UntetheredWatchManager {
    /// Where a bolus was asked for, for the log and the notification.
    enum BolusSource: String {
        case watch
        case remote
    }

    func bolus(_ units: Decimal, source: BolusSource = .watch, completion: @escaping (Bool, String) -> Void) {
        func log(_ line: String) {
            Task { await WatchLogger.shared.log("⌚️ Untethered bolus (\(source.rawValue)): \(line)", force: true) }
        }
        log("\(units) U requested")
        // the phone is taking the pump back (the watch leaves the pod to it), or the hand-back is in its last stage:
        // a bolus now would take the pod's one connection the phone needs, as the loop's own check `mayDose` knows
        // (Ponytail's review, 15 November). Remote boluses come this way too.
        // with the time it ends: the iPhone may never have got the request (away, or the watch asked because the
        // sensor, not the pod, stopped), and then the watch takes boluses again after it
        var handingBack: String {
            guard let until = podQuietUntil, until > Date() else {
                return String(localized: "The pump is being handed to the iPhone. Bolus from the iPhone once it has the pump.")
            }
            let time = until.formatted(date: .omitted, time: .shortened)
            return String(
                localized: "The watch leaves the pod to the iPhone until \(time). Bolus on the iPhone, or on the watch after \(time)."
            )
        }
        if (podQuietUntil ?? .distantPast) > Date() {
            log("not delivered: \(handingBack)")
            notifyBolus(units, delivered: false, message: handingBack, source: source)
            return completion(false, handingBack)
        }
        guard !isFinalizing, mayDose, let pump = pumpManager, let grant = data.grant else {
            let reason = UntetheredWatchError.noPump.localizedDescription
            log("not delivered: \(reason)")
            notifyBolus(units, delivered: false, message: reason, source: source)
            return completion(false, reason)
        }
        let amount = min(units, grant.maxBolus)
        let rounded = pump.roundToSupportedBolusVolume(units: amount.nearestDouble)
        if amount < units { log("limited to the max bolus of \(grant.maxBolus) U") }
        Task { @MainActor in
            // checked again right before the pod command, as the loop does
            guard self.mayDose else {
                log("not delivered: \(handingBack)")
                self.notifyBolus(Decimal(rounded), delivered: false, message: handingBack, source: source)
                return completion(false, handingBack)
            }
            do {
                try await pump.enactBolus(units: rounded, automatic: false)
                log("\(rounded) U started")
                self.notifyBolus(Decimal(rounded), delivered: true, message: nil, source: source)
                completion(true, String(localized: "Bolus started."))
                // as the phone's `enactBolus`: IOB and the forecast take the bolus in at once
                self.runLoop(.treatment)
            } catch {
                log("not delivered: \(error.localizedDescription)")
                self.notifyBolus(Decimal(rounded), delivered: false, message: error.localizedDescription, source: source)
                completion(false, error.localizedDescription)
                self.yieldIfPhoneTookPod()
            }
        }
    }

    /// Said on the wrist, as it can come while nobody looks: always for a remote bolus, for one from the watch only
    /// with Trio in the background (in front, its own screen says it).
    private func notifyBolus(_ units: Decimal, delivered: Bool, message: String?, source: BolusSource) {
        guard source == .remote || WKApplication.shared().applicationState != .active else { return }
        let amount = NSDecimalNumber(decimal: units).doubleValue.formatted(.number.precision(.fractionLength(0 ... 2)))
        let title: String
        if source == .remote {
            title = delivered ? String(localized: "Remote Bolus Started") : String(localized: "Remote Bolus Failed")
        } else {
            title = delivered ? String(localized: "Bolus Started") : String(localized: "Bolus Failed")
        }
        notify(
            id: Self.notificationPrefix + "bolus",
            title: title,
            body: delivered
                ? String(localized: "\(amount) U is being delivered.")
                : String(localized: "\(amount) U not delivered: \(message ?? "")")
        )
    }

    // MARK: Remote commands

    /// A remote bolus or meal (LoopFollow, Nightscout) the phone passed on while the watch has the pump. Checked as the
    /// phone checks one (`TrioRemoteControl`, `BolusSafetyEvaluator`), with the watch's own IOB and history, which are
    /// the current ones now.
    /// - Parameter reply: for a command sent straight to the watch (`WatchRemoteCommands`), which answers the sender
    ///   itself; nil when the copy came first by the other way and was handled there. Without it the answer goes to
    ///   the phone, which passes it on.
    func handleRemoteTreatment(
        _ treatment: UntetheredRemoteTreatment,
        epoch: Int,
        reply: (((delivered: Bool, message: String)?) -> Void)? = nil
    ) {
        // one command can arrive up to three times: from the phone interactively and queued, and straight from the
        // sender; the watch acts on the first. An empty answer tells the phone not to report it.
        guard Self.claimRemoteTreatment(treatment.id) else {
            if let reply {
                reply(nil)
            } else {
                send(.remoteTreatmentResult(id: treatment.id, delivered: true, message: ""), epoch: epoch, queueing: true)
            }
            return
        }
        let age = Date().timeIntervalSince(treatment.sentAt)
        let via = reply == nil ? "through the iPhone" : "straight to the watch"
        func log(_ line: String) {
            Task { await WatchLogger.shared.log("⌚️ Untethered remote command (\(via)): \(line)", force: true) }
        }
        log("\(treatment.summary), sent \(Int(age)) s ago")
        func answer(_ delivered: Bool, _ message: String) {
            log(delivered ? "done: \(message)" : "refused: \(message)")
            if let reply {
                reply((delivered, message))
            } else {
                send(.remoteTreatmentResult(id: treatment.id, delivered: delivered, message: message), epoch: epoch, queueing: true)
            }
        }
        func refuse(_ reason: String) {
            answer(false, reason)
            notify(id: Self.notificationPrefix + "remote", title: String(localized: "Remote Command Refused"), body: reason)
        }
        guard data.session.phase == .active, epoch == data.session.epoch, !isFinalizing, pumpManager != nil,
              let grant = data.grant
        else { return refuse(String(localized: "Command rejected: the Apple Watch doesn't have the pump right now.")) }
        guard age <= UntetheredRemoteTreatment.window else {
            return refuse(String(localized: "Command rejected: the message is too old (sent \(Int(age)) seconds ago)."))
        }
        guard age >= -UntetheredRemoteTreatment.window else {
            return refuse(String(localized: "Command rejected: the message has an invalid future timestamp."))
        }

        let carbs = treatment.carbs ?? 0, fat = treatment.fat ?? 0, protein = treatment.protein ?? 0
        let isMeal = carbs > 0 || fat > 0 || protein > 0
        if isMeal {
            if carbs > grant.maxCarbs {
                return refuse(String(localized: "Command rejected: carbs amount (\(carbs)g) exceeds the maximum allowed (\(grant.maxCarbs)g)."))
            }
            // as the phone: only entries already in the past can mean a replay
            let now = Date()
            if data.carbs.contains(where: { ($0.actualDate ?? $0.createdAt) > treatment.sentAt && ($0.actualDate ?? $0.createdAt) <= now }) {
                return refuse(String(localized: "Command rejected: newer carb entries have been logged since the command was sent."))
            }
            addCarbs(
                NSDecimalNumber(decimal: carbs).intValue,
                fat: NSDecimalNumber(decimal: fat).intValue,
                protein: NSDecimalNumber(decimal: protein).intValue,
                at: treatment.carbsDate ?? now,
                note: Self.remoteMealNote
            )
        }
        guard let units = treatment.bolus, units > 0 else {
            notify(
                id: Self.notificationPrefix + "remote",
                title: String(localized: "Remote Meal Logged"),
                body: treatment.summary
            )
            return answer(true, String(localized: "Meal logged on the Apple Watch"))
        }
        // as the phone, after the meal is logged: the bolus is checked on its own
        if let reason = remoteBolusRejection(units, since: treatment.sentAt, grant: grant) {
            return refuse(isMeal ? String(localized: "Meal logged, bolus not given. \(reason)") : reason)
        }
        if let busy = remoteBolusBusyReason() {
            return refuse(isMeal ? String(localized: "Meal logged, bolus not given. \(busy)") : busy)
        }
        bolus(units, source: .remote) { delivered, message in
            DispatchQueue.main.async {
                answer(delivered, delivered ? String(localized: "Bolus started on the Apple Watch") : message)
            }
        }
    }

    /// A remote override or temp target, started or cancelled on the watch's own loop; the phone takes it over with the
    /// watch's history. Answered as a treatment is: to the phone, or to the sender with `reply`.
    func handleRemoteAdjustment(
        _ adjustment: UntetheredRemoteAdjustment,
        epoch: Int,
        reply: (((delivered: Bool, message: String)?) -> Void)? = nil
    ) {
        guard Self.claimRemoteTreatment(adjustment.id) else {
            if let reply {
                reply(nil)
            } else {
                send(.remoteTreatmentResult(id: adjustment.id, delivered: true, message: ""), epoch: epoch, queueing: true)
            }
            return
        }
        let age = Date().timeIntervalSince(adjustment.sentAt)
        let via = reply == nil ? "through the iPhone" : "straight to the watch"
        func log(_ line: String) {
            Task { await WatchLogger.shared.log("⌚️ Untethered remote command (\(via)): \(line)", force: true) }
        }
        log("\(adjustment.summary), sent \(Int(age)) s ago")
        func answer(_ done: Bool, _ message: String) {
            log(done ? "done: \(message)" : "refused: \(message)")
            notify(
                id: Self.notificationPrefix + "remote",
                title: done ? String(localized: "Remote Command") : String(localized: "Remote Command Refused"),
                body: message
            )
            if let reply {
                reply((done, message))
            } else {
                send(.remoteTreatmentResult(id: adjustment.id, delivered: done, message: message), epoch: epoch, queueing: true)
            }
        }
        guard data.session.phase == .active, epoch == data.session.epoch, !isFinalizing, let grant = data.grant else {
            return answer(false, String(localized: "Command rejected: the Apple Watch doesn't have the pump right now."))
        }
        guard age <= UntetheredRemoteTreatment.window else {
            return answer(false, String(localized: "Command rejected: the message is too old (sent \(Int(age)) seconds ago)."))
        }
        guard age >= -UntetheredRemoteTreatment.window else {
            return answer(false, String(localized: "Command rejected: the message has an invalid future timestamp."))
        }
        switch adjustment.action {
        case let .startOverride(name):
            // as the phone's `AdjustmentManager`: by preset name only
            guard grant.overridePresets.contains(where: { $0.name == name }) else {
                return answer(false, String(localized: "Command rejected: Preset \"\(name)\" not found."))
            }
            activateOverride(named: name)
            answer(true, String(localized: "Override started on the Apple Watch"))
        case .cancelOverride:
            // nothing running is the state asked for, as on the phone
            endOverride()
            answer(true, String(localized: "Override canceled on the Apple Watch"))
        case let .startTempTarget(target, minutes):
            guard target > 0, minutes > 0 else {
                return answer(false, String(localized: "Command rejected: temp target data is incomplete or invalid."))
            }
            activateTempTarget(targetMgdl: target, minutes: minutes, halfBasalTarget: grant.preferences.halfBasalExerciseTarget)
            answer(true, String(localized: "Temp target set on the Apple Watch"))
        case .cancelTempTarget:
            endTempTarget()
            answer(true, String(localized: "Temp target canceled on the Apple Watch"))
        }
    }

    // MARK: Checks after Elias Maurer's Watch Loop (EJM0/Trio, feat/watch-loop-3/5 to 5/5)

    /// At each loop's pod read: insulin the pod delivered since the last check that the watch's records don't explain
    /// means another controller dosed (the phone, a second watch, a remote command it didn't see). It is booked as a
    /// bolus in the watch's history, so IOB errs high and dosing errs low, and this loop doses nothing. The idea and
    /// its rule come from Elias Maurer's Watch Loop (`pumpTotalIsExplained`, EJM0/Trio feat/watch-loop-5/5); before,
    /// the watch made this check only when it started from the phone's copy.
    func podTotalExplained(_ pump: PumpManager, grant: UntetheredGrant) -> Bool {
        guard let odometer = pump as? PumpDeliveryOdometer, let reading = odometer.deliveredUnits else { return true }
        let now = Date()
        let units = reading.units
        let start = data.session.startStatus
        let baseline = data.podTotalCheck.map { (units: $0.units, at: $0.at) }
            ?? start.flatMap { status in status.deliveredUnits.map { (units: $0, at: status.date) } }
        // compared by the time the pod gave each count, not the time of the check: a loop that finds the pump data
        // fresh enough reads no new count, and a dose command's answer brings a newer one after the check. With the
        // time of the check, an SMB counted in such a later answer looked like insulin from elsewhere (0.67 U,
        // 2026-11-01 09:23, after a 0.7 U SMB at 09:13)
        guard let baseline, reading.at > baseline.at else { return true }
        store.update { $0.podTotalCheck = UntetheredWatchData.PodTotalCount(units: units, at: reading.at) }
        guard units >= baseline.units else { return true }
        // older than the kept history (trimmed to a day) the records can't explain it: start counting again
        guard reading.at.timeIntervalSince(baseline.at) < Self.podTotalCheckSpan else { return true }
        let expected = UntetheredAudit.expectedDelivery(
            from: baseline.at,
            to: reading.at,
            // a booked unexplained amount isn't expected delivery: it would hide real insulin from elsewhere in the
            // next check
            history: data.tddPumpHistory.filter { !$0.id.hasPrefix(Self.unexplainedPrefix) },
            basalProfile: grant.basalProfile,
            bolusDeliveryRate: odometer.bolusDeliveryRate
        )
        guard case let .unrecorded(extra) = UntetheredAudit.verdict(delivered: Decimal(units - baseline.units), expected: expected)
        else { return true }
        let rounded = extra.rounded(scale: 2)
        let bolus = PumpHistoryEvent(
            id: Self.unexplainedPrefix + "\(Int(now.timeIntervalSince1970))",
            type: .bolus,
            timestamp: now,
            amount: rounded,
            duration: 0,
            isSMB: false,
            isExternal: false
        )
        store.update { $0.upsertPumpEvent(id: bolus.id, history: [bolus], tdd: bolus) }
        Task {
            await WatchLogger.shared.log(
                "⌚️ Untethered: the pod delivered \(rounded) U the watch has no record of since \(baseline.at.formatted(date: .omitted, time: .shortened)); counted as a bolus, this loop doses nothing",
                force: true
            )
        }
        notify(
            id: Self.notificationPrefix + "unexplained",
            title: String(localized: "Insulin From Elsewhere"),
            body: String(localized: "The pod delivered \(rounded) U the watch didn't give. It counts it and skips this loop's dose. Check that only the watch is dosing.")
        )
        return false
    }

    /// Back to the scheduled basal when a temp above it runs: after insulin from elsewhere the watch adds none.
    func cancelHighTemp(_ pump: PumpManager, grant: UntetheredGrant) async {
        guard case let .tempBasal(dose) = pump.status.basalDeliveryState else { return }
        let scheduled = BolusCalculator.scheduleValue(grant.basalProfile.map { ($0.start, $0.rate) }, at: Date())
        guard Decimal(dose.unitsPerHour) > scheduled else { return }
        do {
            try await pump.enactTempBasal(unitsPerHour: 0, for: 0)
            recordPumpStatus()
            Task { await WatchLogger.shared.log("⌚️ Untethered: high temp \(dose.unitsPerHour) U/h cancelled after insulin from elsewhere", force: true) }
        } catch {
            Task { await WatchLogger.shared.log("⌚️ Untethered: high temp not cancelled: \(error.localizedDescription)", force: true) }
        }
    }

    static let unexplainedPrefix = "untethered-unexplained-"
    /// Shorter than the day of history the watch keeps (`UntetheredStore.trim`).
    static let podTotalCheckSpan: TimeInterval = 20 * 60 * 60

    static let handbackUnconfirmedID = notificationPrefix + "handbackUnconfirmed"
    static let phoneSilentID = notificationPrefix + "phoneSilent"
    /// As Elias Maurer's dead man's switches (EJM0/Trio feat/watch-loop-4/5): set ahead and pushed out by each sign of
    /// life, so they come even with the watch app suspended or ended.
    static let handbackUnconfirmedAfter: TimeInterval = 2 * 60
    static let phoneSilentAfter: TimeInterval = 25 * 60

    /// A hand-back the phone hasn't confirmed: a warning 2 min after the offer, withdrawn when the session ends.
    func updateHandbackWarning() {
        if data.session.phase == .ending, let offered = data.session.handbackOfferedAt {
            guard scheduledHandbackWarning != offered else { return }
            scheduledHandbackWarning = offered
            notify(
                id: Self.handbackUnconfirmedID,
                title: String(localized: "Hand-Back Not Confirmed"),
                body: String(localized: "The watch offered the pump back to the iPhone, which hasn't confirmed it. Open Trio on the iPhone and keep it near the pod."),
                after: max(1, offered.addingTimeInterval(Self.handbackUnconfirmedAfter).timeIntervalSinceNow),
                asksForAction: true
            )
        } else if scheduledHandbackWarning != nil {
            scheduledHandbackWarning = nil
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.handbackUnconfirmedID])
        }
        if data.session.phase != .idle {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.phoneSilentID])
        }
    }

    /// With the fallback on and no session: each word from the phone pushes a warning 25 min out. It comes when the
    /// phone went silent and the fallback didn't take over by then (it would after about 15 min).
    func notePhoneHeardForWarning() {
        let state = WatchState.shared
        guard data.session.phase == .idle, state.fallbackLoop, state.untetheredMode, state.allowUntetheredStartWithoutPhone
        else { return }
        // about once a minute is enough: the phone's messages come in bursts
        guard Date().timeIntervalSince(phoneSilentScheduledAt ?? .distantPast) > 60 else { return }
        phoneSilentScheduledAt = Date()
        notify(
            id: Self.phoneSilentID,
            title: String(localized: "No Word From iPhone"),
            body: String(localized: "Trio on the iPhone hasn't reached the watch for 25 minutes, and the watch hasn't taken over. Check that Trio on the iPhone is running and looping."),
            after: Self.phoneSilentAfter,
            asksForAction: true
        )
    }

    /// `BolusSafetyEvaluator`'s rules (phone only) with the watch's numbers.
    private func remoteBolusRejection(_ units: Decimal, since sentAt: Date, grant: UntetheredGrant) -> String? {
        if units > grant.maxBolus {
            return String(localized: "Command rejected: bolus amount (\(units) units) exceeds the maximum allowed (\(grant.maxBolus) units).")
        }
        // the last loop's IOB, while it is recent, with the boluses since it: the loop's own SMB and anything after
        // it, which its IOB (calculated before them) doesn't hold
        guard let lastLoop = data.lastLoopDate, Date().timeIntervalSince(lastLoop) < Self.remoteIOBMaxAge,
              let loopIOB = data.lastDetermination?.iob
        else { return String(localized: "Command rejected: current IOB is not available.") }
        let sinceLoop = data.pumpHistory
            .filter { [.bolus, .smb].contains($0.type) && $0.timestamp >= lastLoop }
            .reduce(Decimal(0)) { $0 + ($1.amount ?? 0) }
        let iob = loopIOB + sinceLoop
        let maxIOB = grant.preferences.clamped(for: grant.dosingMode).maxIOB
        if iob + units > maxIOB {
            return String(localized: "Command rejected: bolus amount (\(units) units) would exceed max IOB (\(maxIOB) units). Current IOB: \(iob) units.")
        }
        let recent = data.pumpHistory
            .filter { [.bolus, .smb].contains($0.type) && $0.timestamp > sentAt }
            .reduce(Decimal(0)) { $0 + ($1.amount ?? 0) }
        if recent >= units * Self.remoteRecentBolusThreshold {
            return String(localized: "Command rejected: boluses totaling more than 20% of the requested amount have been delivered since the command was sent.")
        }
        return nil
    }

    /// The pod takes one bolus at a time: a remote bolus that comes while a bolus or SMB runs is refused with when to
    /// send it again, rather than failing at the pod with a less clear error. Not delivered later on its own: by then
    /// the sender may have decided otherwise, and the safety checks would need the newer IOB.
    private func remoteBolusBusyReason() -> String? {
        let state = pumpManager?.status.bolusState ?? .noBolus
        if case let .inProgress(dose) = state {
            let units = dose.programmedUnits.formatted(.number.precision(.fractionLength(0 ... 2)))
            let left = Int(dose.endDate.timeIntervalSinceNow.rounded(.up))
            guard left > 0 else {
                return String(localized: "A bolus of \(units) U is just finishing. Please send the bolus again in a moment.")
            }
            return String(
                localized: "A bolus of \(units) U is being delivered right now, about \(left) s left. Please send the bolus again once it has finished."
            )
        }
        guard state != .noBolus || isBolusing else { return nil }
        return String(localized: "A bolus is in progress right now. Please send the bolus again in a moment.")
    }

    static let remoteMealNote = "📡"
    private static let remoteRecentBolusThreshold: Decimal = 0.2
    private static let remoteIOBMaxAge: TimeInterval = 15 * 60
    private static let handledRemoteKey = "untethered.handledRemoteTreatments"

    /// Remembered across relaunches for as long as a command can be acted on: the queued copy may wake a new process.
    private static func claimRemoteTreatment(_ id: UUID) -> Bool {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        var handled = (defaults.dictionary(forKey: handledRemoteKey) as? [String: Double] ?? [:])
            .filter { now - $0.value < UntetheredRemoteTreatment.window * 2 }
        guard handled[id.uuidString] == nil else { return false }
        handled[id.uuidString] = now
        defaults.set(handled, forKey: handledRemoteKey)
        return true
    }

    // MARK: Ending the pod

    /// Deactivates the pod, e.g. one that alarms: it stops delivering, goes quiet and must come off. The watch can't
    /// pair the next one, so it hands back to the phone as soon as the phone is reachable.
    func deactivatePod(completion: @escaping (_ error: String?) -> Void) {
        guard let pump = pumpManager else { return completion(UntetheredWatchError.noPump.localizedDescription) }
        let started = watchDeactivatePod(pump) { error in
            DispatchQueue.main.async {
                if let error {
                    completion(error.localizedDescription)
                } else {
                    self.podDidEnd()
                    completion(nil)
                }
            }
        }
        if !started { completion(String(localized: "The watch can't deactivate this pump.")) }
    }

    /// For a pod that doesn't answer: forgotten without its last word. It may go on alarming until it is removed.
    func discardPod() {
        guard let pump = pumpManager else { return }
        _ = watchDiscardPod(pump) { DispatchQueue.main.async { self.podDidEnd() } }
    }

    private func podDidEnd() {
        let now = Date()
        store.update {
            $0.podEnded = true
            $0.pendingPumpAlerts.removeAll { $0.managerIdentifier == self.pumpManager?.pluginIdentifier }
        }
        // no loop follows until the phone pairs the next pod
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: Self.notLoopingIDs)
        store.record(
            UntetheredRecord(key: UntetheredRecord.podEndedKey, date: now, kind: .podEnded(now)),
            epoch: data.session.epoch
        )
        savePumpState()
        refresh()
        streamRecords()
        Task { await WatchLogger.shared.log("⌚️ Untethered: pod ended on the watch", force: true) }
        if WCSession.default.isReachable { end() }
    }

    func cancelBolus() {
        pumpManager?.cancelBolus { result in
            DispatchQueue.main.async {
                if case let .failure(error) = result {
                    self.setError(error.localizedDescription)
                } else {
                    // as the phone's: a bolus cancelled early ends its delivery now, so its meal-time reminder counts
                    // from here
                    if let reminder = self.pendingMealReminder, reminder.deliveredBy > Date() {
                        self.remindToEat(after: reminder.minutes, bolus: 0)
                    }
                    // in case the pod books the cancelled bolus only later: what it delivered so far counts now
                    self.runLoop(.treatment)
                }
            }
        }
    }

    func addCarbs(_ grams: Int, fat: Int = 0, protein: Int = 0, at date: Date, note: String? = nil) {
        guard let grant = data.grant else { return }
        let entry = CarbsEntry(
            id: UUID().uuidString,
            createdAt: date,
            actualDate: date,
            carbs: min(Decimal(grams), grant.maxCarbs),
            fat: fat > 0 ? Decimal(fat) : nil,
            protein: protein > 0 ? Decimal(protein) : nil,
            note: note,
            enteredBy: CarbsEntry.local,
            isFPU: false,
            fpuID: fat > 0 || protein > 0 ? UUID().uuidString : nil
        )
        // ponytail: fat and protein travel to the phone, which converts them; the watch's own loop counts carbs only
        store.update { $0.carbs.append(entry) }
        store.record(
            UntetheredRecord(key: UntetheredRecord.carbsKey(entry.id ?? ""), date: date, kind: .carbs(entry)),
            epoch: data.session.epoch
        )
        refresh()
        runLoop(.treatment)
    }

    /// The sensor's readings alone, without manual BGs: what the sensor checks, the alarms for missing readings
    /// and the 3.5-minute filter go by, so a manual BG neither hides a silent sensor nor drops its next reading.
    var sensorGlucose: [BloodGlucose] { data.glucose.filter { $0.mbg == nil } }

    /// A blood glucose from a meter, entered on the watch: as the phone's History → Add Glucose, it goes into the
    /// readings the loop uses (unsmoothed) and reaches the phone as a manual entry (`mbg` set → `isManual`). Like
    /// the phone, it doesn't start a loop of its own: the next sensor reading's loop takes it into account.
    func addManualGlucose(mgdl: Int) {
        guard isActive else { return }
        let now = Date()
        let glucose = BloodGlucose(
            id: UUID().uuidString,
            mbg: mgdl,
            date: Decimal(Int64(now.timeIntervalSince1970 * 1000)), // Int64: see takeReadings
            dateString: now,
            glucose: mgdl,
            type: "mbg"
        )
        store.update { $0.glucose.append(glucose) }
        store.record(
            UntetheredRecord(key: UntetheredRecord.glucoseKey(now), date: now, kind: .glucose(glucose)),
            epoch: data.session.epoch
        )
        Task { await WatchLogger.shared.log("⌚️ Untethered: manual BG \(mgdl) mg/dL entered on the watch", force: true) }
        refresh()
        checkAlarms()
        publishToWatchState()
    }

    /// Deleted for the loop and the screens; the same key's new version tells the phone.
    func deleteGlucose(id: String) {
        guard let reading = data.glucose.first(where: { $0.id == id }) else { return }
        store.update {
            $0.glucose.removeAll { $0.id == id }
            $0.smoothedGlucose[id] = nil
        }
        smoothGlucose()
        store.record(
            UntetheredRecord(
                key: UntetheredRecord.glucoseKey(reading.dateString),
                date: reading.dateString,
                kind: .glucoseDeleted(date: reading.dateString)
            ),
            epoch: data.session.epoch
        )
        refresh()
        publishToWatchState()
    }

    func deleteCarbs(id: String) {
        store.update { $0.carbs.removeAll { $0.id == id } }
        store.record(
            UntetheredRecord(key: UntetheredRecord.carbsKey(id), date: Date(), kind: .carbsDeleted(id: id)),
            epoch: data.session.epoch
        )
        refresh()
        runLoop(.treatment)
    }

    func activateOverride(named name: String) {
        guard let preset = data.grant?.overridePresets.first(where: { $0.name == name }) else { return }
        endOverride()
        let now = Date()
        let override = Override(
            name: preset.name, enabled: true, date: now, duration: preset.duration, indefinite: preset.indefinite,
            percentage: preset.percentage, smbIsOff: preset.smbIsOff, isPreset: true, id: preset.id,
            overrideTarget: preset.overrideTarget, target: preset.target, advancedSettings: preset.advancedSettings,
            isfAndCr: preset.isfAndCr, isf: preset.isf, cr: preset.cr, smbIsScheduledOff: preset.smbIsScheduledOff,
            start: preset.start, end: preset.end, smbMinutes: preset.smbMinutes, uamMinutes: preset.uamMinutes,
            showUntetheredButton: preset.showUntetheredButton
        )
        let key = UntetheredRecord.overrideKey(now)
        store.update {
            $0.activeOverride = override
            $0.activeOverrideKey = key
        }
        store.record(UntetheredRecord(key: key, date: now, kind: .override(override)), epoch: data.session.epoch)
        refresh()
        runLoop(.treatment)
    }

    func endOverride(at date: Date = Date()) {
        guard let override = activeOverride(at: Date()), let key = data.activeOverrideKey else { return }
        store.update {
            $0.activeOverride = nil
            $0.activeOverrideKey = nil
            $0.endedOverrides.append(Self.overrideRun(override, endedAt: date))
        }
        store.record(
            UntetheredRecord(key: key, date: date, kind: .overrideEnded(start: override.date)),
            epoch: data.session.epoch
        )
        refresh()
        checkLinkedOverride()
        runLoop(.treatment)
    }

    /// For Nightscout: the minutes an override ran, or its planned ones while it runs (30 days when indefinite, as
    /// the phone uploads it).
    static func overrideRun(_ override: Override, endedAt end: Date?) -> UntetheredNightscout.OverrideRun {
        let planned = override.indefinite ? UntetheredNightscout.indefiniteMinutes : override.duration
        let minutes = end.map { min(planned, Decimal(max(1, $0.timeIntervalSince(override.date) / 60))) } ?? planned
        return UntetheredNightscout.OverrideRun(name: override.name, start: override.date, minutes: minutes)
    }

    func activateTempTarget(named name: String) {
        guard let preset = data.grant?.tempTargetPresets.first(where: { $0.name == name }) else { return }
        endTempTarget()
        let now = Date()
        let tempTarget = TempTarget(
            id: preset.id, name: preset.name, createdAt: now, targetTop: preset.targetTop, targetBottom: preset.targetBottom,
            duration: preset.duration, enteredBy: TempTarget.local, reason: TempTarget.custom, isPreset: true,
            enabled: true, halfBasalTarget: preset.halfBasalTarget
        )
        let key = UntetheredRecord.tempTargetKey(now)
        store.update {
            $0.tempTargets.append(tempTarget)
            $0.activeTempTargetKey = key
        }
        store.record(UntetheredRecord(key: key, date: now, kind: .tempTarget(tempTarget)), epoch: data.session.epoch)
        refresh()
        runLoop(.treatment)
    }

    /// A custom temp target, as the phone's remote control sets one (`handleTempTargetCommand`).
    func activateTempTarget(targetMgdl target: Decimal, minutes: Decimal, halfBasalTarget: Decimal) {
        endTempTarget()
        let now = Date()
        let tempTarget = TempTarget(
            name: TempTarget.custom, createdAt: now, targetTop: target, targetBottom: target, duration: minutes,
            enteredBy: TempTarget.local, reason: TempTarget.custom, isPreset: false, enabled: true,
            halfBasalTarget: halfBasalTarget
        )
        let key = UntetheredRecord.tempTargetKey(now)
        store.update {
            $0.tempTargets.append(tempTarget)
            $0.activeTempTargetKey = key
        }
        store.record(UntetheredRecord(key: key, date: now, kind: .tempTarget(tempTarget)), epoch: data.session.epoch)
        refresh()
        runLoop(.treatment)
    }

    func endTempTarget(at date: Date = Date()) {
        guard let tempTarget = activeTempTarget(at: Date()), let key = data.activeTempTargetKey else { return }
        store.update {
            $0.tempTargets.append(TempTarget.cancel(at: date))
            $0.activeTempTargetKey = nil
        }
        store.record(
            UntetheredRecord(key: key, date: date, kind: .tempTargetEnded(start: tempTarget.createdAt)),
            epoch: data.session.epoch
        )
        refresh()
        runLoop(.treatment)
    }

    /// An override or temp target that ran out on the watch reaches the phone as ended at its scheduled end,
    /// so the phone doesn't keep it running when the watch's history arrives.
    func expireAdjustments(now: Date) {
        let epoch = data.session.epoch
        if let override = data.activeOverride, override.enabled, !override.indefinite, activeOverride(at: now) == nil,
           let key = data.activeOverrideKey
        {
            let end = override.date.addingTimeInterval(Double(truncating: override.duration as NSNumber) * 60)
            store.update {
                $0.activeOverride = nil
                $0.activeOverrideKey = nil
                $0.endedOverrides.append(Self.overrideRun(override, endedAt: end))
            }
            store.record(UntetheredRecord(key: key, date: end, kind: .overrideEnded(start: override.date)), epoch: epoch)
        }
        if let key = data.activeTempTargetKey, activeTempTarget(at: now) == nil,
           let tempTarget = data.tempTargets.last(where: { UntetheredRecord.tempTargetKey($0.createdAt) == key })
        {
            let end = tempTarget.createdAt.addingTimeInterval(Double(truncating: tempTarget.duration as NSNumber) * 60)
            store.update { $0.activeTempTargetKey = nil }
            store.record(UntetheredRecord(key: key, date: end, kind: .tempTargetEnded(start: tempTarget.createdAt)), epoch: epoch)
        }
        refresh()
    }

    func acknowledgePumpAlert(_ alert: UntetheredWatchData.PendingPumpAlert) {
        let manager = pumpManager
        Task { try? await manager?.acknowledgeAlert(alertIdentifier: alert.alertIdentifier) }
        store.update { $0.pendingPumpAlerts.removeAll { $0.id == alert.id } }
        refresh()
    }
}

// MARK: - Pump

private struct WatchReservoir: ReservoirValue {
    let startDate: Date
    let unitVolume: Double
}

extension UntetheredWatchManager: PumpManagerDelegate {
    /// The session's pump, not the fallback's look at the pod: the look's manager reports here too, for its link
    /// messages, but its events, status and errors are not the session's.
    func isSessionPump(_ manager: AnyObject) -> Bool {
        pumpManager.map { ($0 as AnyObject) === manager } ?? false
    }

    /// As on the phone: the pod's heartbeat keeps the link, the CGM drives the loop.
    func pumpManagerBLEHeartbeatDidFire(_: PumpManager) {}

    func pumpManagerMustProvideBLEHeartbeat(_: PumpManager) -> Bool { false }

    /// LoopKit#685: the old `pumpManagerWillDeactivate`, now awaited by the pump manager's `delete()`.
    func pumpManagerWantsDeletion(_ manager: PumpManager) async {
        await MainActor.run {
            guard self.isSessionPump(manager as AnyObject) else { return }
            self.setError(String(localized: "The pod was deactivated. Pair a new one on the phone."))
        }
    }

    func pumpManagerPumpWasReplaced(_: PumpManager) {}

    func pumpManager(_: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents _: Bool) {}

    func pumpManager(_ manager: PumpManager, didError error: PumpManagerError) {
        guard isSessionPump(manager as AnyObject) else {
            Task { await WatchLogger.shared.log("⌚️ Untethered: fallback — the look's pump: \(error.localizedDescription)", force: true) }
            return
        }
        setError(error.localizedDescription)
    }

    func pumpManager(
        _ manager: PumpManager,
        hasNewPumpEvents events: [NewPumpEvent],
        lastReconciliation _: Date?,
        replacePendingEvents: Bool,
        completion: @escaping (Error?) -> Void
    ) {
        // the look only reads the pod; its records are the phone's
        guard isSessionPump(manager as AnyObject) else { return completion(nil) }
        let increment = data.grant?.preferences.bolusIncrement ?? 0.05
        let epoch = data.session.epoch
        let identifiers = events.map { event in
            event.dose?.syncIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? event.raw.map { String(format: "%02x", $0) }.joined()
        }
        // a bolus that ends, or is cancelled, is booked with what it delivered: IOB and the forecast follow at once
        let wasMutable = store.data.mutablePumpEventIDs
        let bolusFinalized = zip(events, identifiers).contains { event, id in
            event.type == .bolus && event.dose?.isMutable == false && wasMutable.contains(id)
        }
        if replacePendingEvents {
            let asserted = Set(identifiers)
            let dropped = store.data.mutablePumpEventIDs.subtracting(asserted)
            store.update {
                $0.removePumpEvents(dropped)
                $0.mutablePumpEventIDs = []
            }
            for id in dropped {
                store.record(
                    UntetheredRecord(key: UntetheredRecord.pumpEventKey(id), date: Date(), kind: .pumpEventDropped(id)),
                    epoch: epoch
                )
            }
        }
        store.update { data in
            for (event, id) in zip(events, identifiers) where event.dose?.isMutable == true {
                data.mutablePumpEventIDs.insert(id)
            }
        }
        for (event, identifier) in zip(events, identifiers) {
            store.update {
                $0.upsertPumpEvent(
                    id: identifier,
                    history: UntetheredAlgorithm.historyEvents(event, id: identifier, bolusIncrement: increment),
                    tdd: UntetheredAlgorithm.tddEvent(event, id: identifier, bolusIncrement: increment)
                )
            }
            if let raw = try? PropertyListSerialization.data(fromPropertyList: event.rawValue, format: .binary, options: 0) {
                store.record(
                    UntetheredRecord(key: UntetheredRecord.pumpEventKey(identifier), date: event.date, kind: .pumpEvent(raw)),
                    epoch: epoch
                )
            }
        }
        refresh()
        completion(nil)
        if bolusFinalized { DispatchQueue.main.async { self.runLoop(.treatment) } }
    }

    func pumpManager(
        _ manager: PumpManager,
        didReadReservoirValue units: Double,
        at date: Date,
        completion: @escaping (Result<
            (newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool),
            Error
        >)
            -> Void
    ) {
        if isSessionPump(manager as AnyObject) { store.update { $0.reservoir = Decimal(units) } }
        completion(.success((
            newValue: WatchReservoir(startDate: date, unitVolume: units),
            lastValue: nil,
            areStoredValuesContinuous: true
        )))
    }

    func pumpManager(_: PumpManager, didAdjustPumpClockBy _: TimeInterval) {}

    func pumpManagerDidUpdateState(_: PumpManager) {
        savePumpState()
    }

    func pumpManager(
        _: PumpManager,
        didRequestBasalRateScheduleChange _: BasalRateSchedule,
        completion: @escaping (Error?) -> Void
    ) {
        completion(nil)
    }

    func startDateToFilterNewPumpEvents(for _: PumpManager) -> Date {
        Date().addingTimeInterval(-24 * 60 * 60)
    }

    var detectedSystemTimeOffset: TimeInterval { 0 }

    var automaticDosingEnabled: Bool { data.grant.map { $0.dosingMode.automation != .off } ?? false }

    // Display-only hint for pump UIs; the watch shows none.
    var automatedTreatmentState: AutomatedTreatmentState? { nil }

    func pumpManager(_ manager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus _: PumpManagerStatus) {
        guard isSessionPump(manager as AnyObject) else { return }
        updateBolusState(status)
        refresh()
    }

    func deviceManager(
        _ manager: DeviceManager,
        logEventForDeviceIdentifier _: String?,
        type: DeviceLogEntryType,
        message: String,
        completion: ((Error?) -> Void)?
    ) {
        // The pod's messages are logged in the background too: a few per command, and they show what the pod
        // last said before a link drops mid-command (the stall of 24 Oct, 05:36, has none in its log).
        if Self.isRawDump(message), !(manager is PumpManager) {
            // a sensor link writes over a hundred of these, written out at every wake: only with Trio in front
            DispatchQueue.main.async {
                guard WKApplication.shared().applicationState == .active else { return }
                Task { await WatchLogger.shared.log("⌚️ Device: \(message)") }
            }
        } else {
            // the fallback's look at the pod: its link messages say why a look didn't reach the pod
            let look = manager is PumpManager && !isSessionPump(manager as AnyObject)
            Task { await WatchLogger.shared.log(look ? "⌚️ Device (look): \(message)" : "⌚️ Device: \(message)", force: look) }
        }
        DispatchQueue.main.async { self.noteSensorPairingEvent(message) }
        if message.hasPrefix("Pod connected"), isSessionPump(manager as AnyObject) {
            DispatchQueue.main.async { self.loopAgainIfPodBack() }
        }
        // ponytail: matched on OmnipodKit's disconnect line, as the sensor's link errors above; a link OmnipodKit
        // didn't end itself ("no reason recorded") and nothing from the pod either: watchOS ended it
        if isSessionPump(manager as AnyObject) {
            if message.hasPrefix("[disconnect] ours: no reason recorded"), message.contains("app in background") {
                DispatchQueue.main.async { self.noteBackgroundLinkCut() }
            } else if message.hasPrefix("[connect] configured in") {
                DispatchQueue.main.async { self.backgroundLinkCuts.removeAll() }
            }
        }
        // ponytail: matched on G7SensorKit's log line, which is the only place it reports a link error;
        // move to a delegate call if the kit ever reports one. 14 = the peer removed the pairing: the sensor no
        // longer has this watch's bond. 15 = encryption timed out, which a weak link does too: only twice in a row,
        // with no reading between, counts as a refusal (4 November, 05:08: one, readings went on at 05:13, and the
        // warning sent the user through two pairings that weren't needed).
        if message.contains("Sensor didRead") {
            DispatchQueue.main.async {
                self.sensorEncryptTimeouts = 0
                if self.data.lastError == Self.sensorRefusalMessage { self.setError(nil) }
            }
        } else if type == .error, message.contains("CBErrorDomain Code=14") || message.contains("CBErrorDomain Code=15") {
            let removed = message.contains("CBErrorDomain Code=14")
            DispatchQueue.main.async {
                self.sensorEncryptTimeouts += removed ? 0 : 1
                if removed || self.sensorEncryptTimeouts >= 2 {
                    self.setError(Self.sensorRefusalMessage)
                } else {
                    Task { await WatchLogger.shared.log("⌚️ Untethered: the sensor's link timed out while encrypting; a refusal only if the next connect fails the same way", force: true) }
                }
            }
        }
        completion?(nil)
    }

    /// A kit's raw packet line: a hex dump alone, or behind G7SensorKit's "backfill" or "control".
    static func isRawDump(_ message: String) -> Bool {
        let words = message.split(separator: " ")
        guard let last = words.last, last.count >= 8, last.allSatisfy(\.isHexDigit) else { return false }
        return words.count == 1 || (words.count == 2 && ["backfill", "control"].contains(words[0]))
    }

    func deviceManagerControlDidBecomeReady(_ manager: DeviceManager) {
        let look = manager is PumpManager && !isSessionPump(manager as AnyObject)
        Task { await WatchLogger.shared.log(look ? "⌚️ Untethered: fallback — the look's pump link ready" : "⌚️ Untethered: pump link ready") }
    }

    // MARK: Alerts

    /// A scheduled alert (the G7 schedules its session-end warnings days ahead) shows from when it is due.
    func issueAlert(_ alert: LoopKit.Alert) {
        // the fallback's look reads the pod's alerts too; they are the phone's to show
        guard pumpManager != nil || !isWitnessingPod else { return }
        let content = alert.foregroundContent ?? alert.backgroundContent
        let delay: TimeInterval?
        switch alert.trigger {
        case .immediate: delay = nil
        case let .delayed(interval): delay = interval
        case let .repeating(interval): delay = interval
        }
        let pending = UntetheredWatchData.PendingPumpAlert(
            managerIdentifier: alert.identifier.managerIdentifier,
            alertIdentifier: alert.identifier.alertIdentifier,
            title: content.title,
            body: content.body,
            due: delay.map { Date().addingTimeInterval($0) }
        )
        store.update {
            $0.pendingPumpAlerts.removeAll { $0.id == pending.id }
            $0.pendingPumpAlerts.append(pending)
        }
        refresh()
        // the phone sounds its own devices' alerts until the watch takes over
        if isActive { notify(id: Self.notificationID(pending.id), title: pending.title, body: pending.body, after: delay) }
    }

    /// Alerts issued before the takeover sound on the wrist from it on; at the hand-back the phone's again.
    func handOverAlertNotifications(toWatch: Bool) {
        let alerts = data.pendingPumpAlerts
        guard toWatch else {
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(
                    withIdentifiers: alerts.map { Self.notificationID($0.id) } + Self.notLoopingIDs + [Self.noReadingsID]
                )
            return
        }
        // from the takeover at the earliest: booked from the phone's last loop, a start without the phone sounded
        // "Not Looping" at once (2026-10-22 20:41, with the watch's first loop 22 s after the takeover)
        scheduleNotLoopingAlert(from: loopReference ?? Date())
        scheduleNoReadingsAlert(from: sensorGlucose.map(\.dateString).max() ?? Date())
        for alert in alerts {
            guard let due = alert.due, due > Date() else { continue }
            notify(id: Self.notificationID(alert.id), title: alert.title, body: alert.body, after: due.timeIntervalSinceNow)
        }
    }

    func retractAlert(identifier: LoopKit.Alert.Identifier) {
        let id = identifier.managerIdentifier + "." + identifier.alertIdentifier
        store.update { $0.pendingPumpAlerts.removeAll { $0.id == id } }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationID(id)])
        refresh()
    }

    /// A pump or CGM alert's notification: untethered's prefix, so it also shows with Trio open on the wrist
    /// (`WatchNotificationHandler.willPresent` shows only prefixed ones).
    static func notificationID(_ alertID: String) -> String { notificationPrefix + alertID }

    func doesIssuedAlertExist(identifier: LoopKit.Alert.Identifier) async throws -> Bool {
        data.pendingPumpAlerts.contains { $0.id == identifier.managerIdentifier + "." + identifier.alertIdentifier }
    }

    func lookupAllUnretracted(managerIdentifier _: String) async throws -> [PersistedAlert] { [] }

    func lookupAllUnacknowledgedUnretracted(managerIdentifier _: String) async throws -> [PersistedAlert] { [] }

    func recordRetractedAlert(_: LoopKit.Alert, at _: Date) async throws {}
}

// MARK: - CGM

extension UntetheredWatchManager: CGMManagerDelegate {
    func startDateToFilterNewData(for _: CGMManager) -> Date? {
        sensorGlucose.map(\.dateString).max()
    }

    /// The most a loop holds the app awake: a pod command, retries included, is done well within it.
    static let loopHoldLimit: TimeInterval = 30
    /// Past OmnipodKit's idle disconnect (4 s after the last command): an app asleep before it leaves the pod connected.
    static let podIdleDisconnectWait: TimeInterval = 5

    /// The loop is done: its hold ends past the pod's idle disconnect, so an app asleep doesn't leave the pod
    /// connected. In front, while a bolus runs or with the workout keeping the app awake, it ends at once. The sensor
    /// keeps its own hold, which waits out its tail (no start delay since Pete Schwamb's LoopKit/G7SensorKit#80).
    func endLoopHold(_ release: @escaping () -> Void) {
        // a running workout keeps the app awake anyway: the sensor keeps its own hold, which loses no bursts
        guard WKApplication.shared().applicationState != .active, !isBolusing, !isKeptAwake else { return release() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.podIdleDisconnectWait) { release() }
    }

    /// A test (22 October): every pod stall so far began with a command cut off within seconds of a sensor reading
    /// (02:25, 12:10, 00:45, 01:00), and the loop reached for the pod while the G7's link was still up, both on the
    /// one radio. The loop a reading starts now waits until the sensor has closed its link (at most 12 s), then
    /// 3 s more, before it talks to the pod. If the stalls get rarer, this is why.
    static let sensorQuietLimit: TimeInterval = 12
    static let sensorQuietMargin: TimeInterval = 3

    @MainActor func waitForSensorQuiet() async {
        let start = Date()
        while watchCGMIsConnected(cgmManager), Date().timeIntervalSince(start) < Self.sensorQuietLimit {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let linkOpen = Date().timeIntervalSince(start)
        try? await Task.sleep(nanoseconds: UInt64(Self.sensorQuietMargin * 1_000_000_000))
        Task {
            await WatchLogger.shared.log(
                String(
                    format: "⌚️ Untethered: pod after the sensor — link closed after %.1f s%@, then %.0f s margin",
                    linkOpen, watchCGMIsConnected(self.cgmManager) ? " (still open, limit reached)" : "", Self.sensorQuietMargin
                )
            )
        }
    }

    /// Keeps the app running until `release` is called, `wait` has passed, or watchOS ends it, whichever comes first.
    /// watchOS ends it by calling the block again with `expired`, or calls it only so when it grants no time: the hold
    /// lets go at once, since an app that holds on past that gets less background time from then on, logs how long it
    /// had, and `onExpire` tells the work to start nothing new.
    static func holdProcess(
        reason: String,
        upTo wait: TimeInterval,
        onExpire: (@MainActor() -> Void)? = nil
    ) -> () -> Void {
        let gate = DispatchSemaphore(value: 0)
        let started = Date()
        // each hold logs once, how it ended: released by us, or ended by watchOS (with what may have limited it)
        let once = NSLock()
        var ended = false
        let end = { () -> Bool in
            once.lock()
            defer { once.unlock() }
            guard !ended else { return false }
            ended = true
            return true
        }
        // Granted before the caller goes on: asked for on another queue, a hold could come too late for a wake that
        // is ending (26 October, 19:55:13, tester: the fallback start's hold never ran, the app was suspended in the
        // middle of the start and relaunched 4.5 minutes later, with nobody looping in between).
        let begun = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
                begun.signal()
                guard expired else {
                    if gate.wait(timeout: .now() + wait) == .timedOut, end() {
                        logHold(reason, after: Date().timeIntervalSince(started), how: "held to its \(Int(wait)) s limit")
                    }
                    return
                }
                gate.signal()
                guard end() else { return }
                let granted = Date().timeIntervalSince(started)
                let process = ProcessInfo.processInfo
                let thermal = ["nominal", "fair", "serious", "critical"][min(process.thermalState.rawValue, 3)]
                // before this handler returns: once it has, watchOS may suspend the app, and a task queued for the main
                // actor would run only at the next wake, letting go of the pod minutes late (Fable, 12 November).
                // This runs off the main thread, so waiting for it can't deadlock.
                if let onExpire {
                    let done = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { onExpire() }
                        done.signal()
                    }
                    _ = done.wait(timeout: .now() + 2)
                }
                Task { @MainActor in
                    let inFront = WKApplication.shared().applicationState == .active
                    logHold(
                        reason,
                        after: granted,
                        how: "background time ended by watchOS · lowPower=\(process.isLowPowerModeEnabled) thermal=\(thermal) front=\(inFront)"
                    )
                }
            }
        }
        _ = begun.wait(timeout: .now() + 0.5)
        return {
            let first = end()
            gate.signal()
            if first { logHold(reason, after: Date().timeIntervalSince(started), how: "released") }
        }
    }

    private static func logHold(_ reason: String, after seconds: TimeInterval, how: String) {
        Task { await WatchLogger.shared.log(String(format: "⌚️ hold %@: %.1f s, %@", reason, seconds, how), force: true) }
    }

    // MARK: Sensor pairing

    /// A sensor pairing ends with the system's Bluetooth pairing request, which watchOS only shows with Trio in front.
    /// In the background the sensor drops the link a second after asking and discards the key (2026-10-19, 07:04
    /// and 17:54); with Trio in front it bonded (18:19). While a pairing is due, Trio is kept in front for up to
    /// 10 minutes once it is open, it vibrates as the request comes, and the user is told to open it otherwise.
    static let pairingID = "untethered.pairing"

    /// G7SensorKit reports its pairing steps only in its log lines; matched here, as the link errors above are.
    func noteSensorPairingEvent(_ message: String) {
        guard isActive else { return }
        if message.contains("Pairing: running the key exchange")
            // the same sensor asking to bond again (bond=2) after its Bluetooth pairing was lost; 2026-10-22 05:00:
            // Trio left the screen a second into it, the sensor dropped the link, no reading for 50 minutes
            || message.contains("Running the certificate exchange")
        {
            sensorPairingDue()
        } else if message.contains("expect the system pairing prompt") {
            // felt only when the request can show; behind the watch face the "Pair the Sensor" notice asks instead
            if WKApplication.shared().applicationState == .active {
                WKInterfaceDevice.current().play(.notification)
            } else {
                sensorPairingDue()
            }
        } else if message.contains("dropped the link after the bond request") {
            // Not always the end: the sensor may take the key without the system's Bluetooth pairing, as G7SensorKit
            // reports a moment later (30 October, 20:58:41: dropped, then "authenticated directly" in the same second,
            // and the warning stayed, saying Trio wasn't on the screen while it was). Said only if still unpaired.
            let wasInFront = WKApplication.shared().applicationState == .active
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.isActive, self.isPairingSensor else { return }
                self.notify(
                    id: Self.pairingID,
                    title: String(localized: "Sensor Pairing Not Finished"),
                    body: wasInFront
                        ? String(
                            localized: "The sensor didn't finish pairing with the watch. Keep Trio open on the watch: it pairs again at the next reading."
                        )
                        : String(
                            localized: "Trio wasn't on the watch screen for the Bluetooth pairing request. Open Trio on the watch and keep it open: it pairs again at the next reading."
                        ),
                    asksForAction: true
                )
            }
        } else if message.hasPrefix("Bonded") || message.contains("Authenticated with the sensor directly") {
            sensorPairingDone()
        }
    }

    /// A new sensor, or one that refused the saved key: the next connection pairs.
    func sensorPairingDue() {
        if !isPairingSensor {
            isPairingSensor = true
            Task { await WatchLogger.shared.log("⌚️ Untethered: sensor pairing due", force: true) }
        }
        if WKApplication.shared().applicationState == .active {
            keepTrioInFrontForPairing()
        } else {
            notify(
                id: Self.pairingID,
                title: String(localized: "Pair the Sensor"),
                body: String(
                    localized: "Open Trio on the watch and keep it open until a glucose value shows. If a Bluetooth pairing request appears, accept it."
                ),
                asksForAction: true
            )
        }
    }

    func sensorPairingDone() {
        guard isPairingSensor else { return }
        isPairingSensor = false
        pairingKeepAlive?.stop()
        pairingKeepAlive = nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.pairingID])
        ActionNotice.clearReminders()
        center.removeDeliveredNotifications(withIdentifiers: [Self.pairingID])
        Task { await WatchLogger.shared.log("⌚️ Untethered: sensor paired", force: true) }
    }

    /// Trio came to the front: a pairing that is due keeps it there.
    func appBecameActive() {
        ActionNotice.clearReminders()
        watchCGMRecheckAcquisition(cgmManager)
        if isPairingSensor { keepTrioInFrontForPairing() }
        updateWorkoutKeepAlive()
        // Trio in front can search: a pod the watch doesn't know yet is looked for now (opened from a notification,
        // Trio may count as in front only a moment later)
        meetNewPodIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.meetNewPodIfNeeded() }
        guard isActive else { return }
        let state = WKApplication.shared().applicationState
        Task { await WatchLogger.shared.log("⌚️ Untethered: Trio in front (state \(state.rawValue))", force: true) }
        // opened after the early notice (from it, Trio may count as in front only a moment later)
        if podLinkEarlyNoticeAt != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.retryPodInFront() }
        }
        // Opened from a notification, Trio may not count as in front yet when this runs, and the workout start is
        // skipped (31 October, 11:09: "Watch Took Over" tapped, no workout). Asked again once it has settled.
        for delay in [1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isActive, WatchState.shared.untetheredWorkout, !self.isKeptAwake else { return }
                self.updateWorkoutKeepAlive()
                guard delay == 3.0, self.workoutKeepAlive == nil else { return }
                let state = WKApplication.shared().applicationState
                let line = "⌚️ Untethered: workout not started 3 s after Trio came to the front (state \(state.rawValue), "
                    + "ended by user \(self.workoutEndedByUser), earlier start failed \(self.workoutStartFailed))"
                Task { await WatchLogger.shared.log(line, force: true) }
            }
        }
    }

    /// How long a workout start may go unanswered before Trio in front asks again.
    static let workoutStartPatience: TimeInterval = 15

    /// Extended Untethered Mode: the workout runs while the watch has the pump and the setting is on.
    func updateWorkoutKeepAlive() {
        guard isActive, WatchState.shared.untetheredWorkout else {
            workoutKeepAlive?.stop()
            workoutEndedByUser = false
            return
        }
        let inFront = WKApplication.shared().applicationState == .active
        // a start in the background that watchOS never answered: with Trio in front it goes again
        if workoutKeepAlive != nil, !isKeptAwake, inFront,
           let requested = workoutStartRequestedAt, Date().timeIntervalSince(requested) > Self.workoutStartPatience
        {
            Task {
                await WatchLogger.shared
                    .log("⌚️ Untethered: extended mode workout never started, again with Trio in front", force: true) }
            // Ended, not only let go: its late answer is ignored (`current`), but a session left behind may still hold
            // HealthKit's one workout (30 October, 19:59 to 20:11: three starts after one another, none answered).
            workoutKeepAlive?.stop()
            workoutKeepAlive = nil
        }
        // watchOS starts a workout only for an app in front: one that failed in the background (a fallback start) goes
        // again as soon as Trio is opened
        guard workoutKeepAlive == nil, !workoutEndedByUser, !workoutStartFailed || inFront else { return }
        // an attempt let go above may still answer: only the current one counts
        weak var current: UntetheredWorkoutKeepAlive?
        let keepAlive = UntetheredWorkoutKeepAlive(onChange: { [weak self] isRunning, note in
            guard let self, current != nil, current === self.workoutKeepAlive else { return }
            Task { await WatchLogger.shared.log("⌚️ Untethered: extended mode workout \(note)", force: true) }
            let wasRunning = self.isKeptAwake
            self.isKeptAwake = isRunning
            if !isRunning { self.heartRate = nil }
            if isRunning {
                self.workoutStartFailed = false
                // the session may have ended while it started
                self.updateWorkoutKeepAlive()
            } else {
                self.workoutKeepAlive = nil
                if wasRunning {
                    // ended in watchOS, not by Trio, also by a workout started in another app (one runs at a time):
                    // no new one until the next session, which would end that workout in turn
                    if self.isActive, WatchState.shared.untetheredWorkout {
                        self.workoutEndedByUser = true
                        // with the other app in front Trio's screen doesn't show (29 October: an outdoor walk ended
                        // it at once, and 2 of 5 readings were missed): say so, as the face's symbol can't
                        self.notify(
                            id: Self.notificationPrefix + "workoutReplaced",
                            title: String(localized: "Workout Replaced Trio's"),
                            body: String(
                                localized: "The watch still has the pump, but without Trio's workout it may miss readings and loop less often until this session ends. The watch symbol on the face turns orange when it hasn't looped for 10 minutes."
                            )
                        )
                    }
                } else {
                    // refused, as in the background, or ended before it ran: again with Trio in front
                    self.workoutStartFailed = true
                }
            }
        }, onHeartRate: { [weak self] in self?.heartRate = $0 })
        current = keepAlive
        workoutKeepAlive = keepAlive
        workoutStartRequestedAt = Date()
        keepAlive.start()
    }

    /// watchOS relaunched Trio with its workout running: taken back, or ended when no longer wanted.
    func recoverWorkout() {
        guard workoutKeepAlive == nil else { return }
        guard isActive, WatchState.shared.untetheredWorkout else {
            HKHealthStore().recoverActiveWorkoutSession { session, _ in session?.end() }
            return
        }
        updateWorkoutKeepAlive()
    }

    private func keepTrioInFrontForPairing() {
        guard pairingKeepAlive?.isRunning != true, WKApplication.shared().applicationState == .active else { return }
        let keepAlive = SensorPairingKeepAlive { [weak self] reason in
            Task { await WatchLogger.shared.log("⌚️ Untethered: pairing screen hold ended (\(reason))", force: true) }
            self?.pairingKeepAlive = nil
        }
        pairingKeepAlive = keepAlive
        keepAlive.start()
        Task { await WatchLogger.shared.log("⌚️ Untethered: keeping Trio in front for the sensor pairing", force: true) }
    }

    /// The last loop, or the session's start when that is later: a session started without the phone carries the
    /// phone's last loop over, which can be half an hour old, and the stall checks asked for a hand-back the moment
    /// it began (2026-10-22 17:21: "hasn't reached the pod for 36 min" a minute into the fallback's session).
    var loopReference: Date? {
        [data.lastLoopDate, data.session.startStatus?.date].compactMap { $0 }.max()
    }

    /// Readings arrive but no loop got through for this long: the pod link is presumed stuck.
    static let podLinkStallLimit: TimeInterval = 15 * 60
    /// The wait once two loops since the last one failed at the pod's link itself. On the first tester's flight
    /// (13 November) the pod dropped the watch's link within half a second of each connect for 20 minutes and more,
    /// while the phone reached it at once; waiting 19–25 minutes didn't bring it back.
    static let podLinkDropLimit: TimeInterval = 10 * 60
    static let podLinkDropsForEarlyHandback = 2
    /// At most one reconnect per this interval, so a pod that is really out of reach isn't hammered.
    static let podLinkResetInterval: TimeInterval = 10 * 60

    /// A loop that keeps failing to reach the pod while readings come in usually has a stuck connection, which
    /// otherwise only opening the app clears. The link is torn down and searched for afresh.
    func checkPodLink(now: Date = Date()) {
        checkBattery()
        checkSensorStall(now: now)
        checkPodLinkEarly(now: now)
        // the early notice gets a few minutes to be answered before the pump goes back, up to the longer stall limit
        if let noticeAt = podLinkEarlyNoticeAt, now.timeIntervalSince(noticeAt) < Self.podLinkEarlyGrace,
           let lastLoop = loopReference, now.timeIntervalSince(lastLoop) < Self.podLinkStallLimit
        { return }
        guard data.session.phase == .active, let pump = pumpManager,
              let lastLoop = loopReference,
              now.timeIntervalSince(lastLoop) > podLinkLimit(since: lastLoop),
              now.timeIntervalSince(lastPodLinkNotice ?? .distantPast) > Self.podLinkResetInterval,
              // without readings the sensor is what's missing, and its own alarm says so (2026-10-19 18:04)
              let newest = sensorGlucose.map(\.dateString).max(), now.timeIntervalSince(newest) < 11 * 60,
              // and only when loops had readings to run on and still didn't get through: a gap made of missed
              // readings ended with a reading that arrived a moment before its loop, and was taken for a pod
              // stall (2026-10-22 11:10: no reading at 11:00 and 11:05, the pod fine, the pump handed back).
              // Arrivals, not reading times: on 26 October at 16:03 (tester) the sensor came back after 17 minutes
              // with three readings at once, which counted as three loops that failed, and the pump was handed
              // back with the pod answering in a second. The batch arriving now hasn't had its loop yet.
              readingArrivals.filter({ $0 > lastLoop.addingTimeInterval(60) && now.timeIntervalSince($0) > 60 }).count >= 2
        else { return }
        let minutes = Int(now.timeIntervalSince(lastLoop) / 60)
        // with the phone nearby it takes the pump back; until its revoke arrives the watch keeps trying and alerting
        requestHandback(minutes: minutes, reason: .podStall, now: now)
        // Every 10 minutes while it lasts, not only once: once was easy to miss (2026-10-20, 12:25 went unnoticed),
        // and opening Trio is what cleared the stall (13:32). Removed and posted again so it alerts each time.
        lastPodLinkNotice = now
        podLinkNoticeCount += 1
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.podLinkID])
        notify(id: Self.podLinkID, title: Self.podLinkTitle, body: Self.podLinkBody(minutes: minutes))
        // from the second notice on, three strong taps a second apart, as long as the app runs to play them
        let taps = podLinkNoticeCount >= 2 ? 3 : 1
        for tap in 0 ..< taps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(tap)) { WKInterfaceDevice.current().play(.failure) }
        }
        Task { await WatchLogger.shared.log("⌚️ Untethered alarm: \(Self.podLinkTitle) after \(minutes) min", force: true) }
        reconnectPod(pump, minutes: minutes, now: now)
    }

    /// At the end of the quiet time after a hand-back request, when the phone didn't take the pod: the stall goes on,
    /// and the reconnect `checkPodLink` held back during the quiet time runs now.
    func reconnectPodIfStalled(now: Date = Date()) {
        guard data.session.phase == .active, let pump = pumpManager, let lastLoop = loopReference,
              now.timeIntervalSince(lastLoop) > podLinkLimit(since: lastLoop)
        else { return }
        reconnectPod(pump, minutes: Int(now.timeIntervalSince(lastLoop) / 60), now: now)
    }

    private func reconnectPod(_ pump: PumpManager & ExclusiveDeviceControl, minutes: Int, now: Date) {
        // The reconnect itself waits for a loop or bolus in flight; the notice above doesn't. A loop waiting on the
        // pod held on for 41 minutes (2026-10-20, 12:20 to 13:01), and nothing else ran for the stall meanwhile.
        // Not while the phone is taking the pump back: the reconnect's search held the pod's one connection, and the
        // phone found it busy (13 November, third tester). Without the phone in reach it's the watch's only way.
        guard !isLooping, !isBolusing, (podQuietUntil ?? .distantPast) <= now,
              now.timeIntervalSince(lastPodLinkReset ?? .distantPast) > Self.podLinkResetInterval
        else { return }
        lastPodLinkReset = now
        let releaseHold = Self.holdProcess(reason: "Untethered pod reconnect", upTo: Self.loopHoldLimit)
        let outcome = pump.escalateTakeControl() ?? "nothing to escalate"
        let diagnostics = pump.connectionDiagnostics() ?? ""
        Task {
            await WatchLogger.shared.log(
                "⌚️ Untethered: no loop for \(minutes) min, reconnecting the pod: \(outcome) \(diagnostics)",
                force: true
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loopHoldLimit) { releaseHold() }
    }

    /// How long loops may fail before the pump goes back to the phone: shorter once the pod's link itself failed twice
    /// since the last loop, as a link that keeps dropping rarely comes back soon. Loops that only missed readings
    /// keep the longer wait (the readings check above still applies to both).
    func podLinkLimit(since lastLoop: Date) -> TimeInterval {
        podLinkFailures.filter { $0 > lastLoop }.count >= Self.podLinkDropsForEarlyHandback
            ? Self.podLinkDropLimit
            : Self.podLinkStallLimit
    }

    /// Neither a reading nor a loop for this long: the watch's own sensor link isn't working.
    static let sensorStallLimit: TimeInterval = 20 * 60

    /// No reading and no loop: the pod check above stands back (the sensor is what's missing), but nothing else
    /// would end the session either, and the watch can't loop without readings. The phone takes the pump back,
    /// as for a pod stall (2026-10-22: a session started at 05:00 got no reading, no loop for 56 minutes).
    func checkSensorStall(now: Date = Date()) {
        // the phone's reading first: with it the sensor isn't missing
        takePendingPhoneReading(now: now)
        guard data.session.phase == .active,
              let lastLoop = loopReference,
              now.timeIntervalSince(lastLoop) > Self.sensorStallLimit
        else { return }
        let newest = sensorGlucose.map(\.dateString).max()
        guard newest.map({ now.timeIntervalSince($0) > Self.sensorStallLimit }) ?? true else { return }
        requestHandback(minutes: Int(now.timeIntervalSince(lastLoop) / 60), reason: .noReadings, now: now)
    }

    /// A loop reached the pod again: the search an escalation started ends, and so does its notice.
    func podLinkRecovered(_ pump: PumpManager & ExclusiveDeviceControl) {
        if podLinkEarlyNoticeAt != nil {
            podLinkEarlyNoticeAt = nil
            podFrontTry = nil
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.podLinkEarlyID])
        }
        guard lastPodLinkReset != nil || lastPodLinkNotice != nil || handbackRequestedAt != nil else { return }
        lastPodLinkNotice = nil
        podLinkNoticeCount = 0
        handbackRequestedAt = nil
        // a request still queued for the phone would take the pump from a session that loops again
        Self.cancelQueuedHandbackRequests()
        if lastPodLinkReset != nil {
            lastPodLinkReset = nil
            pump.endTakeEscalation()
        }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.podLinkID])
    }

    /// Drops the stall's hand-back requests still waiting in WatchConnectivity's queue, and their notice (Claude
    /// Fable's review, 14 November). The fallback's hand-back (no minutes) stays: the phone is back, and it should get
    /// the pump. Off the main thread: reading the transfer list there hung the app (see `WCTransfers`).
    static func cancelQueuedHandbackRequests() {
        guard WCSession.isSupported() else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationPrefix + "handbackRequest"])
        WCTransfers.run {
            for transfer in WCSession.default.outstandingUserInfoTransfers {
                guard let envelope = try? UntetheredEnvelope.decode(transfer.userInfo),
                      case let .handbackRequested(minutes) = envelope.message, minutes > 0
                else { continue }
                transfer.cancel()
                Task { await WatchLogger.shared.log("⌚️ Untethered: the pod is back, the queued hand-back request is withdrawn", force: true) }
            }
        }
    }

    /// The early notice comes once two loops since the last one failed at the pod's link and this long has passed.
    static let podLinkEarlyNoticeAfter: TimeInterval = 5 * 60
    /// How long the notice has before the pump goes back to the phone at the shorter stall limit.
    static let podLinkEarlyGrace: TimeInterval = 3 * 60
    static let podLinkEarlyID = "untethered.podLinkEarly"

    /// The pod keeps dropping the watch's link: the watch asks to be opened while it still has the pump. On 15 November
    /// (19:46 to 19:56) the only notice came with the hand-back request, and the phone had the pump 4 seconds later,
    /// before opening Trio could show whether it brings the pod back. Once per stall.
    func checkPodLinkEarly(now: Date = Date()) {
        guard data.session.phase == .active, pumpManager != nil, podLinkEarlyNoticeAt == nil,
              let lastLoop = loopReference, now.timeIntervalSince(lastLoop) >= Self.podLinkEarlyNoticeAfter,
              podLinkFailures.filter({ $0 > lastLoop }).count >= Self.podLinkDropsForEarlyHandback,
              (podQuietUntil ?? .distantPast) <= now, handbackRequestedAt == nil
        else { return }
        podLinkEarlyNoticeAt = now
        let minutes = Int(now.timeIntervalSince(lastLoop) / 60)
        notify(
            id: Self.podLinkEarlyID,
            title: String(localized: "Pod Link Lost"),
            body: String(
                localized: "The watch keeps losing the pod's link (no loop for \(minutes) minutes). Open Trio on the watch now and keep it open for a moment. If the pod doesn't answer there either, the watch hands the pump back to the iPhone when it is nearby."
            ),
            asksForAction: true
        )
        WKInterfaceDevice.current().play(.failure)
        Task { await WatchLogger.shared.log("⌚️ Untethered: early notice — open Trio on the watch (no loop for \(minutes) min)", force: true) }
        // already in front: try now rather than at the next reading
        if WKApplication.shared().applicationState == .active { retryPodInFront() }
    }

    /// Cuts this many, over at least `restartWatchSpan`, within `restartWatchWindow`, with no link through: a restart.
    static let restartWatchCuts = 8
    static let restartWatchSpan: TimeInterval = 4 * 60
    static let restartWatchWindow: TimeInterval = 15 * 60
    /// Said again at most this often while it goes on.
    static let restartWatchRepeat: TimeInterval = 2 * 60 * 60
    static let restartWatchID = notificationPrefix + "restartWatch"

    /// The pod's links cut from the watch's own side about a second after connecting, again and again, with Trio in
    /// the background: a state of watchOS a restart of the watch clears, not something Trio can mend (18 November:
    /// 46 of 50 such cuts in the morning, the sensor's link cut with them; none in the afternoon after the watch app
    /// was restarted; 15 November: a clean night after a restart). Said once the cuts reach over two readings with no
    /// link through, before the 14-minute hand-back.
    func noteBackgroundLinkCut(now: Date = Date()) {
        backgroundLinkCuts.append(now)
        backgroundLinkCuts.removeAll { now.timeIntervalSince($0) > Self.restartWatchWindow }
        guard data.session.phase == .active, backgroundLinkCuts.count >= Self.restartWatchCuts,
              let first = backgroundLinkCuts.first, now.timeIntervalSince(first) >= Self.restartWatchSpan,
              restartWatchNoticeAt.map({ now.timeIntervalSince($0) > Self.restartWatchRepeat }) ?? true
        else { return }
        restartWatchNoticeAt = now
        let cuts = backgroundLinkCuts.count
        Task {
            await WatchLogger.shared.log(
                "⌚️ Untethered: \(cuts) background pod links cut by the watch itself in \(Int(now.timeIntervalSince(first) / 60)) min, none through: asking for a restart of the watch",
                force: true
            )
        }
        notify(
            id: Self.restartWatchID,
            title: String(localized: "Restart the Watch"),
            body: String(
                localized: "Bluetooth on the watch keeps cutting the pod's link right after it connects, while Trio is in the background. A restart of the watch clears this: hold the side button, then Power Off, and turn it on again. Open Trio afterwards. Until then, opening Trio gets the pod through."
            ),
            asksForAction: true
        )
    }

    /// Trio came to the front after the early notice: the pod is tried at once, on the newest reading, or right after
    /// a loop in flight.
    func retryPodInFront() {
        guard podLinkEarlyNoticeAt != nil, data.session.phase == .active, !isBolusing,
              (podQuietUntil ?? .distantPast) <= Date()
        else { podFrontTry = nil; return }
        guard !isLooping else { podFrontTry = .pending; return }
        Task { await WatchLogger.shared.log("⌚️ Untethered: Trio in front after the early notice, trying the pod", force: true) }
        podFrontTry = .running
        runLoop(.podBack)
        // the loop didn't start (`runLoop`'s own checks): nothing is being tried
        if !isLooping { podFrontTry = nil }
    }

    static let podLinkID = "untethered.podLink"
    private static var podLinkTitle: String { String(localized: "Pod Not Reachable") }
    private static func podLinkBody(minutes: Int) -> String {
        String(
            localized: "The watch hasn't reached the pod for \(minutes) minutes. Open Trio on the watch: it reconnects there."
        )
    }

    func cgmManager(_: CGMManager, hasNew readingResult: CGMReadingResult) {
        // outside a session the link only stays warm; the phone reads the same sensor
        guard isActive, case let .newData(samples) = readingResult, !samples.isEmpty else { return }
        Self.trace("reading in: \(samples.count) sample(s), newest from \(samples.map(\.date).max()?.formatted(date: .omitted, time: .standard) ?? "-")")
        sensorPairingDone()
        takeReadings(samples.filter { !$0.wasUserEntered }.map {
            SessionReading(
                date: $0.date,
                mgdl: Int($0.quantity.doubleValue(for: .milligramsPerDeciliter)),
                direction: .untethered($0.trend)
            )
        })
    }

    struct SessionReading {
        let date: Date
        let mgdl: Int
        let direction: BloodGlucose.Direction
    }

    /// A phone reading older than this is no use to the loop.
    static let phoneReadingMaxAge: TimeInterval = 6 * 60
    /// The watch's own reading comes within some 40 s of the sensor's burst: the phone's waits this long behind it.
    static let ownReadingFirst: TimeInterval = 75

    /// The phone's own reading, sent after each one while the watch has the pump: a session whose own sensor link
    /// failed loops on it instead of handing the pump back (5 November, 02:53 to 03:18: the phone read every
    /// 5 minutes, the watch got nothing, and after 25 minutes without a loop gave the pump back). The watch's own
    /// reading stays first; without the phone in reach nothing comes and nothing changes.
    func receivePhoneReading(_ payload: [String: Any]) {
        guard let at = payload["date"] as? TimeInterval,
              let mgdl = (payload["mgdl"] as? NSNumber)?.intValue, mgdl > 0
        else { return }
        let reading = SessionReading(
            date: Date(timeIntervalSince1970: at),
            mgdl: mgdl,
            direction: BloodGlucose.Direction(rawValue: payload["direction"] as? String ?? "") ?? .none
        )
        DispatchQueue.main.async {
            // the phone's own reading: the hand-back to a phone that reads again goes by it (`phoneCanLoop`)
            WatchG7Reader.shared.notePhoneOwnReading(reading.date)
            guard reading.date > (self.pendingPhoneReading?.date ?? .distantPast) else { return }
            self.pendingPhoneReading = reading
            self.takePendingPhoneReading()
        }
    }

    /// Takes the phone's held reading once the watch's own for that cycle is overdue, if it still has none.
    func takePendingPhoneReading(now: Date = Date()) {
        guard let reading = pendingPhoneReading else { return }
        let newestOwn = sensorGlucose.map(\.dateString).max() ?? .distantPast
        // too old, no session, or the watch has this cycle's reading itself
        guard isActive, now.timeIntervalSince(reading.date) < Self.phoneReadingMaxAge,
              reading.date.addingTimeInterval(-3.5 * 60) > newestOwn
        else {
            pendingPhoneReading = nil
            return
        }
        let wait = reading.date.addingTimeInterval(Self.ownReadingFirst).timeIntervalSince(now)
        guard wait <= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.takePendingPhoneReading() }
            return
        }
        pendingPhoneReading = nil
        let since = newestOwn == .distantPast ? "none" : newestOwn.formatted(date: .omitted, time: .shortened)
        Task {
            await WatchLogger.shared.log(
                "⌚️ Untethered: no reading of its own since \(since), the iPhone's from \(reading.date.formatted(date: .omitted, time: .shortened)) (\(reading.mgdl) mg/dL) into the session",
                force: true
            )
        }
        takeReadings([reading], fromPhone: true)
    }

    static let ownReadingAtKey = "untethered.ownReadingAt"
    /// The newest reading the watch read from the sensor itself in this session, or the session's start.
    var ownReadingAt: Date? { UserDefaults.standard.object(forKey: Self.ownReadingAtKey) as? Date }
    /// No reading of its own for this long while looping on the phone's: the watch's sensor link is broken, and
    /// without the phone there would be no readings at all.
    static let ownReadingWarnAfter: TimeInterval = 20 * 60
    static let ownSensorID = notificationPrefix + "ownSensor"

    /// A reading from the sensor itself, also one a phone reading already stands for: the watch's link works.
    private func noteOwnReading(_ date: Date) {
        if date > (ownReadingAt ?? .distantPast) { UserDefaults.standard.set(date, forKey: Self.ownReadingAtKey) }
        guard readingsFromPhoneSince != nil else { return }
        readingsFromPhoneSince = nil
        Self.lastAlarm["ownSensor"] = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.ownSensorID])
        Task { await WatchLogger.shared.log("⌚️ Untethered: the watch reads the sensor itself again", force: true) }
    }

    /// The watch's own G7 reader's readings since the phone's newest, into a session the fallback started: it took
    /// over because the reader had them, and without them the session began with the phone's last reading. On
    /// 22 October at 17:22, a minute in, it sounded "no glucose reading for 31 minutes" and waited for its own sensor
    /// link's next burst before it could loop.
    func seedFallbackReadings() {
        guard isActive, isFallbackSession else { return }
        let since = max(
            sensorGlucose.map(\.dateString).max() ?? .distantPast,
            Date().addingTimeInterval(-60 * 60)
        )
        let readings = WatchG7Reader.shared.history.filter { $0.date > since.addingTimeInterval(60) }
        guard !readings.isEmpty else { return }
        Task {
            await WatchLogger.shared.log(
                "⌚️ Untethered: fallback — \(readings.count) of the watch reader's readings into the session",
                force: true
            )
        }
        takeReadings(readings.map {
            SessionReading(
                date: $0.date,
                mgdl: $0.glucose,
                direction: BloodGlucose.Direction(rawValue: $0.trendName ?? "") ?? .none
            )
        })
    }

    func takeReadings(_ readings: [SessionReading], fromPhone: Bool = false) {
        guard isActive, !readings.isEmpty else { return }
        if !fromPhone, let newest = readings.map(\.date).max() { noteOwnReading(newest) }
        let known = Set(sensorGlucose.map { Int($0.dateString.timeIntervalSince1970 / 30) })
        // as `GlucoseStorage.filterTooFrequentGlucose`: a new reading within 3.5 min of the previous one is
        // dropped; older readings are backfill and only need to be new (a manual BG doesn't count)
        var lastDate = sensorGlucose.map(\.dateString).max() ?? .distantPast
        var fresh: [SessionReading] = []
        for sample in readings.sorted(by: { $0.date < $1.date })
            where !known.contains(Int(sample.date.timeIntervalSince1970 / 30))
        {
            if sample.date > lastDate {
                guard sample.date.addingTimeInterval(-3.5 * 60) > lastDate else { continue }
                lastDate = sample.date
            }
            fresh.append(sample)
        }
        guard !fresh.isEmpty else { return }
        if fromPhone, readingsFromPhoneSince == nil { readingsFromPhoneSince = Date() }
        let epoch = data.session.epoch
        for sample in fresh {
            let value = sample.mgdl
            let glucose = BloodGlucose(
                id: UUID().uuidString,
                sgv: value,
                direction: sample.direction,
                // Int64: on a watch with 32-bit Int (arm64_32: Apple Watch SE, Series 4 to 8) milliseconds since 1970
                // overflow Int, and the app crashed at every reading (third tester, 3 and 4 November, Watch6,10)
                date: Decimal(Int64(sample.date.timeIntervalSince1970 * 1000)),
                dateString: sample.date,
                unfiltered: Decimal(value),
                glucose: value,
                type: "sgv"
            )
            store.update { $0.glucose.append(glucose) }
            store.record(
                UntetheredRecord(key: UntetheredRecord.glucoseKey(sample.date), date: sample.date, kind: .glucose(glucose)),
                epoch: epoch
            )
        }
        Self.trace("stored \(fresh.count) reading(s) in the session")
        smoothGlucose()
        refresh()
        checkAlarms()
        scheduleNoReadingsAlert(from: lastDate)
        scheduleSessionRefresh()
        publishToWatchState()
        checkPodLink()
        readingArrivals.append(Date())
        if readingArrivals.count > 24 { readingArrivals.removeFirst(readingArrivals.count - 24) }
        Self.trace("reading handled, loop next")
        runLoop(.newGlucose)
    }

    /// Steps along a reading's way to the pod, in the watch's log file at once (5 November, third tester: twice
    /// watchOS ended the app within seconds of a reading, with no report; these show the step it was in).
    static func trace(_ step: String) {
        Task { await WatchLogger.shared.log("⌚️ Untethered trace: \(step)") }
    }

    func cgmManager(_: CGMManager, hasNew _: [PersistedCgmEvent]) {}

    func cgmManagerWantsDeletion(_: CGMManager) {}

    func cgmManagerDidUpdateState(_: CGMManager) {
        saveCGMState()
    }

    func credentialStoragePrefix(for _: CGMManager) -> String { "untethered" }

    func cgmManager(_: CGMManager, didUpdate _: CGMManagerStatus) {}
}

private extension BloodGlucose.Direction {
    static func untethered(_ trend: LoopKit.GlucoseTrend?) -> BloodGlucose.Direction {
        switch trend {
        case .upUpUp: return .doubleUp
        case .upUp: return .singleUp
        case .up: return .fortyFiveUp
        case .flat: return .flat
        case .down: return .fortyFiveDown
        case .downDown: return .singleDown
        case .downDownDown: return .doubleDown
        default: return .none
        }
    }
}

// MARK: - Alarms and the screens

extension UntetheredWatchManager {
    private static var lastAlarm: [String: Date] = [:]

    /// The watch is the only device watching glucose: low, high and a stalled loop sound here.
    /// Run on every reading and every wake: the loop and sensor alarms are for exactly the times no reading comes.
    func checkAlarms() {
        WatchG7Reader.shared.refreshSensorWarning()
        guard isActive, let grant = data.grant else { return }
        let now = Date()
        let latest = data.glucose.max(by: { $0.dateString < $1.dateString })
        // a reading old enough to be stale doesn't sound as low or high again
        // Trio: the thresholds of the phone's glucose alarms, as the watch's own reader uses them (urgent low
        // included), in the units shown; the glucose range only when the phone has no such alarm turned on.
        if let latest, let value = latest.glucose ?? latest.sgv, now.timeIntervalSince(latest.dateString) < 12 * 60 {
            let reader = WatchG7Reader.shared
            let mgdl = Double(value)
            let low = reader.lowMgDL ?? NSDecimalNumber(decimal: grant.lowGlucose).doubleValue
            let high = reader.highMgDL ?? NSDecimalNumber(decimal: grant.highGlucose).doubleValue
            let body = "\(reader.format(mgdl)) \(reader.units) \(reader.arrow(for: latest.direction?.rawValue))"
                .trimmingCharacters(in: .whitespaces)
            if mgdl <= reader.urgentLowMgDL {
                alarm("urgentLow", title: String(localized: "Urgent Low"), body: body, every: 5 * 60)
            } else if mgdl <= low {
                alarm("low", title: String(localized: "Low Glucose"), body: body, every: 15 * 60)
            } else if mgdl >= high {
                alarm("high", title: String(localized: "High Glucose"), body: body, every: 60 * 60)
            }
        }
        // two missed readings on the sensor's 5-minute grid
        // the sensor's readings only: a fingerstick doesn't hide a silent sensor (`sensorGlucose`)
        if let newest = sensorGlucose.map(\.dateString).max(), now.timeIntervalSince(newest) > Self.noReadingsAfter {
            let minutes = Int(now.timeIntervalSince(newest) / 60)
            // the sensor's own reason when it gives one: the watch reaches it, the sensor sends nothing usable
            switch watchCGMSensorProblem(cgmManager, now: now) {
            case .temporaryIssue:
                alarm(
                    "sensor",
                    title: String(localized: "Sensor Issue"),
                    body: String(
                        localized: "The sensor reports a temporary issue and has sent no usable reading for \(minutes) minutes. The watch is in contact with it; readings come back when the sensor recovers."
                    ),
                    every: 30 * 60
                )
            case .failed:
                alarm(
                    "sensor",
                    title: String(localized: "Sensor Failed"),
                    body: String(
                        localized: "The sensor reports that it has failed and sends no more glucose (no reading for \(minutes) minutes). Replace the sensor."
                    ),
                    every: 30 * 60
                )
            case .warmup:
                alarm(
                    "sensor",
                    title: String(localized: "Sensor Warming Up"),
                    body: String(localized: "The sensor is warming up and sends no glucose yet (no reading for \(minutes) minutes)."),
                    every: 30 * 60
                )
            case nil:
                alarm("sensor", title: Self.noReadingsTitle, body: Self.noReadingsBody(minutes: minutes), every: 30 * 60)
            }
        }
        if !data.podEnded, let lastLoop = loopReference,
           now.timeIntervalSince(lastLoop) > Self.notLoopingAfter
        {
            alarm(
                "loop",
                title: Self.notLoopingTitle,
                body: Self.notLoopingBody(minutes: Int(now.timeIntervalSince(lastLoop) / 60)),
                every: 30 * 60
            )
        }
        // looping on the phone's readings hides a broken link of the watch's own: said after 20 minutes
        if readingsFromPhoneSince != nil, let own = ownReadingAt, now.timeIntervalSince(own) > Self.ownReadingWarnAfter {
            let minutes = Int(now.timeIntervalSince(own) / 60)
            alarm(
                "ownSensor",
                title: String(localized: "Watch Not Reading the Sensor"),
                body: String(
                    localized: "The watch has had no sensor reading of its own for \(minutes) minutes and loops on the iPhone's. Without the iPhone it would have none: keep the watch near the sensor, or open Trio on the watch to reconnect."
                ),
                every: 30 * 60
            )
        }
    }

    /// The pod as the Devices page shows it, for the phone's home screen while the watch has the pump. One key, so
    /// only the newest goes home.
    func recordPumpStatus() {
        guard isActive else { return }
        publishToWatchState()
        var isSuspended = false
        if case .suspended = pumpManager?.status.basalDeliveryState { isSuspended = true }
        let now = Date()
        let status = UntetheredPumpStatus(
            date: now,
            // this fork has no Devices page in the watch state: straight from the pod
            reservoir: watchPumpReservoir(pumpManager) ?? data.reservoir,
            expiresAt: watchPumpExpiresAt(pumpManager),
            isSuspended: isSuspended
        )
        store.record(
            UntetheredRecord(key: UntetheredRecord.pumpStatusKey, date: now, kind: .pumpStatus(status)),
            epoch: data.session.epoch
        )
    }

    /// The sensor alarm's own identifier, so the booked one and the one `checkAlarms` raises are one notification.
    static let noReadingsID = "untethered.sensor"
    /// Two readings missed on the sensor's 5-minute grid.
    private static let noReadingsAfter: TimeInterval = 11 * 60
    private static var noReadingsTitle: String { String(localized: "No Sensor Readings") }
    private static func noReadingsBody(minutes: Int) -> String {
        String(
            localized: "The watch has had no glucose reading for \(minutes) minutes. Keep it near the sensor; it keeps trying."
        )
    }

    /// Booked after every new reading, and at the takeover: it sounds when nothing wakes the watch app any more, as
    /// when a lost Bluetooth callback leaves no connect standing; opening the app is what puts that right.
    func scheduleNoReadingsAlert(from lastReading: Date) {
        notify(
            id: Self.noReadingsID,
            title: Self.noReadingsTitle,
            body: Self.noReadingsBody(minutes: Int(Self.noReadingsAfter / 60)),
            after: lastReading.addingTimeInterval(Self.noReadingsAfter).timeIntervalSinceNow
        )
    }

    static let notLoopingID = "untethered.loop"
    private static let notLoopingAfter: TimeInterval = 20 * 60
    /// The same alarm again this long after the first, booked with it: a watch app that froze, crashed or is being
    /// updated can't sound anything itself, so only what is booked ahead reaches the wrist (18 November: the watch
    /// app stuck in an update, the phone not dosing, nothing heard from the watch for 70 minutes).
    private static let notLoopingRepeats: [TimeInterval] = [15 * 60, 30 * 60]
    /// The first alarm and its repeats, for taking them all back.
    static var notLoopingIDs: [String] {
        [notLoopingID] + notLoopingRepeats.indices.map { notLoopingID + ".again\($0 + 1)" }
    }

    private static var notLoopingTitle: String { String(localized: "Not Looping") }
    private static func notLoopingBody(minutes: Int) -> String {
        String(
            localized: "The watch hasn't looped for \(minutes) minutes. Open Trio on the watch. If it doesn't open or still doesn't loop, take the pump back on the iPhone."
        )
    }

    /// Booked 20 minutes ahead after every loop, and at the takeover, with its repeats 35 and 50 minutes ahead: they
    /// sound even when nothing wakes the watch app to check, or the app can't run at all. The next loop books them
    /// again; a hand-back or a pod ended on the watch takes them back.
    func scheduleNotLoopingAlert(from lastLoop: Date) {
        notify(
            id: Self.notLoopingID,
            title: Self.notLoopingTitle,
            body: Self.notLoopingBody(minutes: Int(Self.notLoopingAfter / 60)),
            after: lastLoop.addingTimeInterval(Self.notLoopingAfter).timeIntervalSinceNow
        )
        for (index, extra) in Self.notLoopingRepeats.enumerated() {
            let after = Self.notLoopingAfter + extra
            // a repeat already past isn't sounded at once: the first, or the running app's own alarm, has said it
            guard lastLoop.addingTimeInterval(after) > Date() else { continue }
            notify(
                id: Self.notLoopingID + ".again\(index + 1)",
                title: Self.notLoopingTitle,
                body: Self.notLoopingBody(minutes: Int(after / 60)),
                after: lastLoop.addingTimeInterval(after).timeIntervalSinceNow
            )
        }
    }

    /// Every untethered notification's identifier starts with it, so they show with Trio open on the wrist too.
    static let notificationPrefix = "untethered."

    private func alarm(_ kind: String, title: String, body: String, every interval: TimeInterval) {
        guard (Self.lastAlarm[kind] ?? .distantPast).addingTimeInterval(interval) < Date() else { return }
        Self.lastAlarm[kind] = Date()
        notify(id: Self.notificationPrefix + kind, title: title, body: body)
        // felt at once while the app runs, as the watch's G7 reader alerts; the notification may wait for the screen
        WKInterfaceDevice.current().play(kind == "high" ? .notification : .failure)
        Task { await WatchLogger.shared.log("⌚️ Untethered alarm: \(title) \(body)", force: true) }
    }

    /// The alarms that mean nobody is looping or the user is in danger: critical with Settings › Notifications ›
    /// Critical Alerts on, so they get through Silent Mode and Focus on the wrist without the phone too.
    static let criticalAlarmIDs: Set<String> = [
        notificationPrefix + "urgentLow", notLoopingID, notLoopingID + ".again1", notLoopingID + ".again2", noReadingsID,
        podLinkID
    ]
    /// Who doses changed: through Focus and kept on the screen, and the log says it was booked (7 November: two
    /// takeovers, and neither "Watch Took Over" was noticed).
    static let takeoverNoticeIDs: Set<String> = [tookOverID]

    /// - Parameter asksForAction: the user has to do something (open Trio, pair the sensor): felt at once and asked
    ///   again (`ActionNotice`)
    func notify(id: String, title: String, body: String, after delay: TimeInterval? = nil, asksForAction: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let critical = Self.criticalAlarmIDs.contains(id)
            && UserDefaults.standard.bool(forKey: WatchMessageKeys.useCriticalAlertsWatch)
        content.sound = critical ? .defaultCritical : .default
        // Time-sensitive for what asks for action and for the safety alarms that can't be critical: they get through
        // Focus and stay on the screen (31 October: "Watch Took Over" went by as news). A critical sound is critical.
        if !critical, asksForAction || Self.criticalAlarmIDs.contains(id) || Self.takeoverNoticeIDs.contains(id) {
            content.interruptionLevel = .timeSensitive
        }
        let trigger = delay.flatMap { $0 > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) : nil }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else {
                if Self.takeoverNoticeIDs.contains(id) {
                    Task { await WatchLogger.shared.log("⌚️ Untethered: notification \(id) booked", force: true) }
                }
                return
            }
            Task {
                await WatchLogger.shared.log("⌚️ Untethered: notification \(id) failed: \(error.localizedDescription)", force: true)
            }
        }
        if asksForAction, delay == nil { ActionNotice.ask(id: id, content: content) }
    }

    /// What the pump delivers now, for the status page: the running temp, else the scheduled rate. A loop that keeps
    /// the running temp sets no rate of its own, so its determination can't say.
    var deliveredBasalRate: Decimal? {
        guard let pump = pumpManager, let grant = data.grant else { return nil }
        switch pump.status.basalDeliveryState {
        case let .tempBasal(dose): return Decimal(dose.unitsPerHour)
        case .active: return BolusCalculator.scheduleValue(grant.basalProfile.map { ($0.start, $0.rate) }, at: Date())
        default: return nil
        }
    }

    /// The main screens read `WatchState`; while untethered it shows the watch's own data.
    func publishToWatchState() {
        guard isActive, let grant = data.grant else { return }
        let state = WatchState.shared
        // in the background nobody sees the screens: the forecast, markers, presets and devices wait for the app to
        // come forward (`refresh`), the complication's values don't
        let inFront = WKApplication.shared().applicationState == .active
        let units = grant.units
        func display(_ mgdl: Int) -> Double {
            units == .mgdL ? Double(mgdl) : NSDecimalNumber(decimal: Decimal(mgdl).asMmolL).doubleValue
        }
        // as `BaseWatchManager.setupWatchState`: the dynamic scheme ramps between fixed ends around the target
        let scheme = GlucoseColorScheme(rawValue: grant.glucoseColorScheme) ?? .staticColor
        let isDynamic = scheme == .dynamicColor
        let target = BolusCalculator.scheduleValue(grant.bgTargets.targets.map { ($0.start, $0.low) }, at: Date())
        func color(_ mgdl: Int) -> Color {
            getDynamicGlucoseColor(
                glucoseValue: Decimal(mgdl),
                highGlucoseColorValue: isDynamic ? 220 : grant.highGlucose,
                lowGlucoseColorValue: isDynamic ? 55 : grant.lowGlucose,
                targetGlucose: target,
                glucoseColorScheme: scheme
            )
        }
        func updateComplication() {
            ComplicationStore.update(
                from: state,
                isMmol: units != .mgdL,
                lowMgDL: NSDecimalNumber(decimal: grant.lowGlucose).doubleValue,
                highMgDL: NSDecimalNumber(decimal: grant.highGlucose).doubleValue,
                colorScheme: grant.glucoseColorScheme,
                targetMgDL: NSDecimalNumber(decimal: target).doubleValue
            )
        }
        let readings = data.glucose.sorted { $0.dateString < $1.dateString }
            .compactMap { reading in (reading.glucose ?? reading.sgv).map { (reading.dateString, $0) } }
        state.glucoseValues = readings.map { (date: $0.0, glucose: display($0.1), color: color($0.1)) }
        if let latest = readings.last {
            state.currentGlucose = units == .mgdL ? "\(latest.1)" : Decimal(latest.1).formatted(for: .mmolL)
            let inRange = Decimal(latest.1) > grant.lowGlucose && Decimal(latest.1) < grant.highGlucose
            state
                .currentGlucoseColorString = inRange ? "#ffffff" : color(latest.1).toHexString()
            state.trend = data.glucose.max(by: { $0.dateString < $1.dateString })?.direction?.rawValue
            if readings.count >= 2 {
                let delta = display(latest.1) - display(readings[readings.count - 2].1)
                let formatted = units == .mgdL ? String(format: "%.0f", delta) : String(format: "%.1f", delta)
                state.delta = delta < 0 ? formatted : "+" + formatted
            }
        }
        if let determination = data.lastDetermination {
            state.iob = determination.iob.map { String(format: "%.2f", NSDecimalNumber(decimal: $0).doubleValue) }
            state.cob = determination.cob.map { $0.formatted(.number.precision(.fractionLength(0))) }
            // each loop's IOB and COB for the chart's scrub line, as the phone keeps them
            if let date = determination.deliverAt ?? determination.timestamp,
               state.ownIobCob.last.map({ $0.date < date }) ?? true
            {
                state.ownIobCob.append(WatchIobCobPoint(
                    date: date,
                    iob: determination.iob.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0,
                    cob: determination.cob.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
                ))
                state.ownIobCob.removeAll { $0.date < Date().addingTimeInterval(-24 * 60 * 60) }
            }
        }
        if let lastLoop = data.lastLoopDate {
            // the phone's own rounding, so the ring turns as it does there
            let minutes = Int((Date().timeIntervalSince(lastLoop) - 30) / 60) + 1
            state.lastLoopTime = minutes > 1440 ? "--" : "\(minutes) min"
        }
        state.lastWatchStateUpdate = Date().timeIntervalSince1970
        guard inFront else {
            updateComplication()
            return
        }
        if let determination = data.lastDetermination {
            // as `AppleWatchManager`: two hours of each line, or the cone between them
            let series = [
                "iob": determination.predictions?.iob, "cob": determination.predictions?.cob,
                "uam": determination.predictions?.uam, "zt": determination.predictions?.zt
            ].compactMapValues { $0.map { Array($0.prefix(24)) } }.filter { !$0.value.isEmpty }
            state.forecastStartDate = series.isEmpty ? nil : determination.deliverAt ?? determination.timestamp
            if state.isForecastCone {
                let count = series.values.map(\.count).min() ?? 0
                state.forecastConeMin = (0 ..< count).map { index in display(series.values.map { $0[index] }.min() ?? 0) }
                state.forecastConeMax = (0 ..< count).map { index in display(series.values.map { $0[index] }.max() ?? 0) }
                state.forecastLines = [:]
            } else {
                state.forecastLines = series.mapValues { $0.map(display) }
                state.forecastConeMin = []
                state.forecastConeMax = []
            }
        }
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        let boluses = data.pumpHistory.filter { [.bolus, .smb].contains($0.type) && $0.timestamp >= dayAgo }
            .map { event in
                WatchTreatmentMarker(
                    id: event.id,
                    date: event.timestamp,
                    kind: event.type == .smb || event.isSMB == true ? .smb : .bolus
                )
            }
        let carbs = data.carbs.filter { ($0.actualDate ?? $0.createdAt) >= dayAgo && !($0.isFPU ?? false) && $0.carbs > 0 }
            .map { entry in
                let date = entry.actualDate ?? entry.createdAt
                return WatchTreatmentMarker(id: entry.id ?? "\(date.timeIntervalSince1970)", date: date, kind: .carbs)
            }
        state.treatmentMarkers = boluses + carbs
        state.showSyncingAnimation = false
        let activeOverrideID = activeOverride(at: Date())?.id
        state.overridePresets = grant.overridePresets
            .map { OverridePresetWatch(name: $0.name, isEnabled: $0.id == activeOverrideID) }
        let activeTempTargetID = activeTempTarget(at: Date())?.id
        state.tempTargetPresets = grant.tempTargetPresets.map {
            TempTargetPresetWatch(name: $0.name ?? "", isEnabled: $0.id == activeTempTargetID)
        }
        state.maxBolus = grant.maxBolus
        state.maxCarbs = grant.maxCarbs
        updateComplication()
    }
}

/// Keeps Trio in front for a sensor pairing: a self-care extended runtime session (WKBackgroundModes self-care, at
/// most 10 minutes), started while the app is active. watchOS then returns to Trio, not the clock, when the wrist
/// comes up, so the Bluetooth pairing request can show.
final class SensorPairingKeepAlive: NSObject, WKExtendedRuntimeSessionDelegate {
    private let session = WKExtendedRuntimeSession()
    private let onEnd: (String) -> Void

    init(onEnd: @escaping (String) -> Void) {
        self.onEnd = onEnd
        super.init()
        session.delegate = self
    }

    var isRunning: Bool { session.state == .running || session.state == .notStarted }

    func start() { session.start() }

    func stop() {
        if session.state == .running { session.invalidate() }
    }

    func extendedRuntimeSessionDidStart(_: WKExtendedRuntimeSession) {}

    func extendedRuntimeSessionWillExpire(_: WKExtendedRuntimeSession) {}

    func extendedRuntimeSession(
        _: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        let text = error.map { "\(reason.rawValue): \($0.localizedDescription)" } ?? "\(reason.rawValue)"
        DispatchQueue.main.async { self.onEnd(text) }
    }
}

/// Extended Untethered Mode: a workout session (WKBackgroundModes workout-processing) keeps Trio running for the whole
/// untethered session, where watchOS otherwise suspends it between sensor bursts and now and then misses one (2026-10-23
/// 11:50 and 12:05, the connect standing). Its builder collects the heart rate alone, for the minimal screen, and the
/// workout is discarded at the end: nothing is saved to Health or counts for the activity rings. Starting needs
/// permission to share workouts, asked once with Trio in front; after a relaunch the running workout is taken back.
final class UntetheredWorkoutKeepAlive: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    private static let heartRate = HKQuantityType(.heartRate)
    private static let beatsPerMinute = HKUnit.count().unitDivided(by: .minute())

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private let onChange: (_ isRunning: Bool, _ note: String) -> Void
    private let onHeartRate: (Double) -> Void

    init(onChange: @escaping (_ isRunning: Bool, _ note: String) -> Void, onHeartRate: @escaping (Double) -> Void) {
        self.onChange = onChange
        self.onHeartRate = onHeartRate
        super.init()
    }

    /// Each step goes to the log: on 30 October from 19:59 three starts were never answered, and the log showed no
    /// step after the request.
    private static func note(_ text: String) {
        Task { await WatchLogger.shared.log("⌚️ Untethered: workout — \(text)", force: true) }
    }

    private static func name(_ state: HKWorkoutSessionState) -> String {
        switch state {
        case .notStarted: return "not started"
        case .prepared: return "prepared"
        case .running: return "running"
        case .paused: return "paused"
        case .stopped: return "stopped"
        case .ended: return "ended"
        @unknown default: return "state \(state.rawValue)"
        }
    }

    func start() {
        Self.note("start requested")
        healthStore.recoverActiveWorkoutSession { recovered, error in
            DispatchQueue.main.async {
                guard self.session == nil else { return }
                // let go meanwhile: nothing of this attempt may keep running
                guard !self.isStopped else {
                    recovered?.end()
                    return
                }
                if let recovered, recovered.state == .running {
                    self.run(recovered)
                    self.onChange(true, "taken back after a relaunch")
                } else if let recovered {
                    // One left over, not running: ended first, and the new one a moment later. Started at once, the
                    // new one may find HealthKit's one workout still taken by the old.
                    Self.note("one left over (\(Self.name(recovered.state))), ending it before the new one")
                    recovered.end()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        guard self.session == nil, !self.isStopped else { return }
                        self.startNew()
                    }
                } else {
                    if let error { Self.note("nothing to take back (\(error.localizedDescription))") }
                    self.startNew()
                }
            }
        }
    }

    /// Stopped before it ran: a start still on its way doesn't go on.
    private var isStopped = false

    func stop() {
        isStopped = true
        guard let session else { return }
        session.end()
    }

    private func startNew() {
        guard HKHealthStore.isHealthDataAvailable() else { return onChange(false, "Health unavailable") }
        healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [Self.heartRate]) { _, error in
            DispatchQueue.main.async {
                guard self.session == nil, !self.isStopped else { return }
                let status = self.healthStore.authorizationStatus(for: .workoutType())
                guard status == .sharingAuthorized else {
                    // not asked yet: the iPhone shows the request (`applicationShouldRequestHealthAuthorization`)
                    let state = status == .notDetermined ? "not asked yet, see the iPhone" : "turned off in Health"
                    return self.onChange(
                        false,
                        "no permission to use workouts (\(state))" + (error.map { ": \($0.localizedDescription)" } ?? "")
                    )
                }
                let configuration = HKWorkoutConfiguration()
                configuration.activityType = .other
                configuration.locationType = .indoor
                do {
                    let session = try HKWorkoutSession(healthStore: self.healthStore, configuration: configuration)
                    self.run(session)
                    let start = Date()
                    Self.note("permission there, starting a new one")
                    session.startActivity(with: start)
                    session.associatedWorkoutBuilder().beginCollection(withStart: start) { _, _ in }
                } catch {
                    self.onChange(false, "could not start: \(error.localizedDescription)")
                }
            }
        }
    }

    private func run(_ session: HKWorkoutSession) {
        session.delegate = self
        self.session = session
        let builder = session.associatedWorkoutBuilder()
        if builder.dataSource == nil {
            let source = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: session.workoutConfiguration)
            // the heart rate only: no energy or distance for the activity rings
            for type in source.typesToCollect where type != Self.heartRate {
                source.disableCollection(for: type)
            }
            source.enableCollection(for: Self.heartRate, predicate: nil)
            builder.dataSource = source
        }
        builder.delegate = self
        self.builder = builder
    }

    private func ended(_ session: HKWorkoutSession, _ note: String) {
        let builder = session.associatedWorkoutBuilder()
        builder.endCollection(withEnd: Date()) { _, _ in builder.discardWorkout() }
        DispatchQueue.main.async {
            guard self.session === session else { return }
            self.session = nil
            self.builder = nil
            self.onChange(false, note)
        }
    }

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date _: Date
    ) {
        Self.note("\(Self.name(fromState)) → \(Self.name(toState))")
        switch toState {
        case .running:
            DispatchQueue.main.async { self.onChange(true, "running") }
        case .stopped:
            // stopped by the system: ended, so nothing is left waiting to be saved
            workoutSession.end()
        case .ended:
            ended(workoutSession, "ended")
        default:
            break
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        ended(workoutSession, "failed: \(error.localizedDescription)")
    }

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard collectedTypes.contains(Self.heartRate),
              let bpm = workoutBuilder.statistics(for: Self.heartRate)?.mostRecentQuantity()?.doubleValue(for: Self.beatsPerMinute)
        else { return }
        DispatchQueue.main.async { self.onHeartRate(bpm) }
    }

    func workoutBuilderDidCollectEvent(_: HKLiveWorkoutBuilder) {}
}

/// Notifications that ask the user to do something (open Trio, pair the sensor, start a session by hand). A plain
/// notification taps the wrist once and reads like news (31 October: "Watch Took Over" wasn't taken as "open Trio").
/// These are felt twice at once while Trio runs, and asked again after 2 and 5 minutes unless Trio comes to the front
/// meanwhile (`clearReminders`).
enum ActionNotice {
    static let reminderDelays: [TimeInterval] = [2 * 60, 5 * 60]
    private static let reminderMark = ".again"

    static func ask(id: String, content: UNNotificationContent) {
        let center = UNUserNotificationCenter.current()
        for (index, delay) in reminderDelays.enumerated() {
            center.add(UNNotificationRequest(
                identifier: id + reminderMark + "\(index + 1)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            ))
        }
        DispatchQueue.main.async {
            // the notification's own tap may wait for the screen; these come while Trio still runs
            WKInterfaceDevice.current().play(.notification)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { WKInterfaceDevice.current().play(.notification) }
        }
        Task { await WatchLogger.shared.log("⌚️ Notice asking for action: \(content.title)", force: true) }
    }

    /// Trio came to the front: what the notices asked for can be done now, so they aren't asked again.
    static func clearReminders() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.contains(reminderMark) }
            guard !ids.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}

extension UntetheredWatchManager {
    /// A failed loop's reading stays worth looping on until the next one is due.
    static let podRetryWindow: TimeInterval = 4.5 * 60

    /// The pod link came back after a loop failed to reach the pod: loop again on that reading now (5 November,
    /// 22:32: the pod was reached again 4 min after the failed loop, and the watch waited for the next reading;
    /// asked for by the first tester).
    func loopAgainIfPodBack(now: Date = Date()) {
        guard let pending = podRetryPending else { return }
        let newestGlucose = data.glucose.map(\.dateString).max() ?? .distantPast
        // too late, or a newer reading loops anyway
        guard now.timeIntervalSince(pending.failedAt) < Self.podRetryWindow, newestGlucose <= pending.glucose,
              isActive, !isLooping, !isBolusing
        else {
            if now.timeIntervalSince(pending.failedAt) >= Self.podRetryWindow || newestGlucose > pending.glucose {
                podRetryPending = nil
            }
            return
        }
        podRetryPending = nil
        Task {
            await WatchLogger.shared.log(
                "⌚️ Untethered: the pod is back, looping again on the reading from \(pending.glucose.formatted(date: .omitted, time: .shortened))",
                force: true
            )
        }
        runLoop(.podBack)
    }
}
