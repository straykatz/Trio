import Foundation
#if canImport(LoopKit)
    import LoopKit
#endif

/// The watch's loop without its state: what it reads and how it determines, shared so the tests reach it.
enum UntetheredAlgorithm {
    struct Inputs {
        let grant: UntetheredGrant
        let pumpHistory: [PumpHistoryEvent]
        let glucose: [BloodGlucose]
        var carbs: [CarbsEntry]
        let tempTargets: [TempTarget]
        let activeTempTarget: TempTarget?
        let override: Override?
        let autosens: Autosens?
        let tdd: OrefPipeline.TDDSummary
        let hasSufficientTDD: Bool
        let currentTemp: TempBasal
        let supportedBasalRates: [Decimal]
        let now: Date
    }

    /// The phone's `OpenAPS.createProfiles`, `autosense` and `determineBasal`, on the watch's data. Nil when oref
    /// gives no determination.
    static func determine(_ inputs: Inputs) throws -> (Determination, Autosens?)? {
        let grant = inputs.grant
        let now = inputs.now
        let profilePreferences = OrefPipeline.profilePreferences(
            grant.preferences,
            activeTempTarget: inputs.activeTempTarget.flatMap { tempTarget in
                tempTarget.targetBottom.map { (target: $0, halfBasalTarget: tempTarget.halfBasalTarget) }
            }
        ).clamped(for: grant.dosingMode)

        var profile = try ProfileGenerator.generate(
            pumpSettings: grant.pumpSettings,
            bgTargets: grant.bgTargets,
            basalProfile: grant.basalProfile,
            isf: grant.insulinSensitivities,
            preferences: profilePreferences,
            carbRatios: grant.carbRatios,
            tempTargets: inputs.tempTargets,
            clock: now
        )

        var autosens = inputs.autosens
        if !OrefPipeline.autosensIsCurrent(autosens, now: now) {
            var fresh = try OrefPipeline.autosens(
                glucose: inputs.glucose,
                pumpHistory: inputs.pumpHistory,
                basalProfile: grant.basalProfile,
                profile: profile,
                carbs: inputs.carbs,
                tempTargets: inputs.tempTargets,
                clock: now
            )
            fresh.timestamp = now
            autosens = fresh
        }

        OrefPipeline.prepareForDosing(&profile, supportedBasalRates: inputs.supportedBasalRates, dosingMode: grant.dosingMode)
        let preferences = OrefPipeline.determinationPreferences(
            grant.preferences,
            dosingMode: grant.dosingMode,
            hasSufficientTDD: inputs.hasSufficientTDD
        )
        let window = Double(truncating: OrefPipeline.glucoseHours(preferences) as NSNumber) * 3600
        let glucose = inputs.glucose.filter { $0.dateString >= now.addingTimeInterval(-window) }

        let meal = try OrefPipeline.meal(
            pumpHistory: inputs.pumpHistory,
            profile: profile,
            basalProfile: grant.basalProfile,
            clock: now,
            carbs: inputs.carbs,
            glucose: glucose
        )
        let iob = try OrefPipeline.iob(pumpHistory: inputs.pumpHistory, profile: profile, clock: now, autosens: autosens)
        guard var determination = try OrefPipeline.determineBasal(
            glucose: glucose,
            currentTemp: inputs.currentTemp,
            iob: iob,
            profile: profile,
            autosens: autosens,
            meal: meal,
            microBolusAllowed: true,
            preferences: preferences,
            trioCustomOrefVariables: OrefPipeline.customOrefVariables(
                override: inputs.override,
                tdd: inputs.tdd,
                preferences: grant.preferences,
                now: now
            ),
            clock: now
        ), let deliverAt = determination.deliverAt else { return nil }
        determination.timestamp = deliverAt
        return (determination, autosens)
    }

    // MARK: Glucose

    /// As `GlucoseStorage.algorithmGlucoseValue`: a CGM reading's smoothed value when smoothing is on and one
    /// exists, otherwise the raw value. Newest first.
    static func algorithmGlucose(
        _ glucose: [BloodGlucose],
        smoothed: [String: Decimal],
        smoothing: Bool
    ) -> [BloodGlucose] {
        glucose.sorted { $0.dateString > $1.dateString }.map { reading in
            // a manual BG in the shape the phone's `mapToBloodGlucose` gives the algorithm: `glucose` only, unsmoothed
            if reading.mbg != nil {
                return BloodGlucose(
                    id: reading.id, direction: reading.direction, date: reading.date, dateString: reading.dateString,
                    glucose: reading.glucose ?? reading.mbg, type: "sgv"
                )
            }
            guard smoothing, reading.sgv != nil, let value = smoothed[reading.id], value != 0 else {
                return reading
            }
            // rounded first, as the phone does: `intValue` misreads long fractions
            let rounded = NSDecimalNumber(decimal: value.rounded(scale: 0)).intValue
            return BloodGlucose(
                id: reading.id, sgv: rounded, direction: reading.direction, date: reading.date,
                dateString: reading.dateString, unfiltered: reading.unfiltered, filtered: reading.filtered,
                noise: reading.noise, glucose: rounded, type: reading.type
            )
        }
    }

    // MARK: Pump history

    /// As `APSManager.fetchCurrentTempBasal` when the pump's state doesn't say: the newest pump event, if it is
    /// a temp basal, for what is left of it.
    static func historyTempBasal(_ history: [PumpHistoryEvent], now: Date) -> TempBasal {
        guard let newest = history.max(by: { $0.timestamp < $1.timestamp }),
              newest.type == .tempBasal || newest.type == .tempBasalDuration,
              let rate = history.first(where: { $0.type == .tempBasal && $0.timestamp == newest.timestamp })?.rate,
              let minutes = history.first(where: { $0.type == .tempBasalDuration && $0.timestamp == newest.timestamp })?
              .durationMin
        else { return TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: now) }
        let elapsed = Int((now.timeIntervalSince1970 - newest.timestamp.timeIntervalSince1970) / 60)
        return TempBasal(duration: max(0, minutes - elapsed), rate: rate, temp: .absolute, timestamp: now)
    }

    /// As `OpenAPS.fetchOrphanedResumes`: a resume without its suspend in the last day would end a suspension
    /// that never started, and oref would read negative IOB from it.
    static func withoutOrphanedResumes(_ history: [PumpHistoryEvent]) -> [PumpHistoryEvent] {
        let pairs = history.filter { $0.type == .pumpSuspend || $0.type == .pumpResume }.sorted { $0.timestamp < $1.timestamp }
        var orphaned = Set<String>()
        if let first = pairs.first, first.type == .pumpResume { orphaned.insert(first.id) }
        for (previous, current) in zip(pairs, pairs.dropFirst()) where current.type == .pumpResume {
            if previous.type != .pumpSuspend || current.timestamp.timeIntervalSince(previous.timestamp) > 24 * 60 * 60 {
                orphaned.insert(current.id)
            }
        }
        return orphaned.isEmpty ? history : history.filter { !orphaned.contains($0.id) }
    }

    /// The id of a temp basal's rate row; its duration row has the pump event's own.
    static func rateID(_ id: String) -> String { "_" + id }

    /// What `PumpEventStored.toPumpHistoryEvents` reads back from a stored amount or rate.
    static func algorithmValue(_ stored: Decimal) -> Decimal {
        Decimal(algorithmValue: NSDecimalNumber(decimal: stored).doubleValue)
    }

    // LoopKit's pump events: in the app and on the watch, not in the algorithm package.
    #if canImport(LoopKit)
    /// A bolus as `PumpHistoryStorage.storePumpEvents` stores it: rounded to the increment in `Double`, kept as the
    /// `Decimal` of that `Double`.
    static func storedBolus(_ dose: DoseEntry, bolusIncrement: Decimal) -> Decimal {
        let increment = NSDecimalNumber(decimal: bolusIncrement).doubleValue
        return Decimal((dose.unitsInDeliverableIncrements / increment).rounded() * increment)
    }

    /// The phone's `PumpHistoryStorage.storePumpEvents` + `PumpEventStored.toPumpHistoryEvents`, without the
    /// database, through the same `Double` and `Decimal` steps. Scheduled basal stays out, as
    /// `pumpHistoryLast1440Minutes` leaves it out.
    static func historyEvents(_ event: NewPumpEvent, id: String, bolusIncrement: Decimal) -> [PumpHistoryEvent] {
        let timestamp = min(event.date, Date())
        switch event.type {
        case .bolus:
            guard let dose = event.dose else { return [] }
            return [PumpHistoryEvent(
                id: id,
                type: .bolus,
                timestamp: timestamp,
                amount: algorithmValue(storedBolus(dose, bolusIncrement: bolusIncrement)),
                duration: 0,
                isSMB: dose.automatic ?? true,
                isExternal: dose.manuallyEntered
            )]
        case .tempBasal:
            guard let dose = event.dose else { return [] }
            return [
                PumpHistoryEvent(
                    id: id,
                    type: .tempBasalDuration,
                    timestamp: timestamp,
                    durationMin: Int((dose.endDate.timeIntervalSince(dose.startDate) / 60).rounded())
                ),
                PumpHistoryEvent(
                    id: rateID(id),
                    type: .tempBasal,
                    timestamp: timestamp,
                    rate: algorithmValue(Decimal(dose.unitsPerHour)),
                    temp: .absolute
                )
            ]
        case .suspend:
            return [PumpHistoryEvent(id: id, type: .pumpSuspend, timestamp: timestamp)]
        case .resume:
            return [PumpHistoryEvent(id: id, type: .pumpResume, timestamp: timestamp)]
        default:
            return []
        }
    }

    /// `PumpHistoryStorage.getPumpHistory`'s shape: a temp basal keeps its rate in `amount`, its minutes in
    /// `duration` and the pump's delivered total; scheduled basal rows are flagged.
    static func tddEvent(_ event: NewPumpEvent, id: String, bolusIncrement: Decimal) -> PumpHistoryEvent? {
        let timestamp = min(event.date, Date())
        switch event.type {
        case .bolus:
            // `getPumpHistory` reads the stored amount as it is
            guard let dose = event.dose else { return nil }
            return PumpHistoryEvent(
                id: id,
                type: .bolus,
                timestamp: timestamp,
                amount: storedBolus(dose, bolusIncrement: bolusIncrement),
                duration: 0,
                isSMB: dose.automatic ?? true,
                isExternal: dose.manuallyEntered
            )
        case .basal,
             .tempBasal:
            guard let dose = event.dose else { return nil }
            let isScheduledBasal = event.type == .basal
            return PumpHistoryEvent(
                id: id,
                type: .tempBasal,
                timestamp: timestamp,
                amount: Decimal(dose.unitsPerHour),
                duration: isScheduledBasal ? 0 : Int((dose.endDate.timeIntervalSince(dose.startDate) / 60).rounded()),
                isScheduledBasal: isScheduledBasal,
                deliveredUnits: dose.deliveredUnits.map { Decimal($0) }
            )
        case .suspend:
            return PumpHistoryEvent(id: id, type: .pumpSuspend, timestamp: timestamp)
        case .resume:
            return PumpHistoryEvent(id: id, type: .pumpResume, timestamp: timestamp)
        default:
            return nil
        }
    }
    #endif

    // MARK: TDD

    /// `BaseTDDStorage.calculateWeightedAverage` over the phone's rows and the watch's own: zeros count.
    static func weightedAverage(rows: [UntetheredTDD], hours: [UntetheredTDDHour], weight: Decimal, now: Date) -> Decimal {
        let recent = rows.filter { $0.date >= now.addingTimeInterval(-2 * 60 * 60) }
        let tenDays = UntetheredTDDHour.inWindow(hours, now: now)
        return TDDCalculator.weightedAverage(
            recentTotal: recent.reduce(0) { $0 + $1.total },
            recentCount: recent.count,
            tenDayTotal: tenDays.reduce(0) { $0 + $1.total },
            tenDayCount: tenDays.reduce(0) { $0 + $1.count },
            weight: weight
        )
    }

    /// `OpenAPS.tddSummary` over the phone's rows and the watch's own: only rows above 0 count.
    static func tddSummary(rows: [UntetheredTDD], hours: [UntetheredTDDHour], now: Date) -> OrefPipeline.TDDSummary? {
        let tenDays = UntetheredTDDHour.inWindow(hours, now: now)
        guard let latest = rows.last(where: { $0.total > 0 }), !tenDays.isEmpty else { return nil }
        let recent = rows.filter { $0.total > 0 && $0.date >= now.addingTimeInterval(-2 * 60 * 60) }
        let tenDayPositive = tenDays.reduce(0) { $0 + $1.positive }
        return OrefPipeline.TDDSummary(
            currentTDD: latest.total,
            averageLastTenDays: tenDays.reduce(0) { $0 + $1.total } / Decimal(max(tenDayPositive, 1)),
            averageLastTwoHours: recent.reduce(0) { $0 + $1.total } / Decimal(max(recent.count, 1))
        )
    }

    /// `BaseTDDStorage.hasSufficientTDD` over the hours: enough rows above 0 in the last seven days. Nil without
    /// hours; the grant's answer stands then.
    static func hasSufficientTDD(hours: [UntetheredTDDHour], now: Date) -> Bool? {
        guard !hours.isEmpty else { return nil }
        let weekAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let positive = hours.filter { $0.start.addingTimeInterval(30 * 60) > weekAgo }.reduce(0) { $0 + $1.positive }
        return positive >= TDDCalculator.sufficientRowCount
    }
}
