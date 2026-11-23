import Foundation

/// The pure oref steps of a loop cycle. Shared by the phone (`OpenAPS`) and the untethered watch,
/// so both dose from the same code.
enum OrefPipeline {
    struct TDDSummary: Codable, Equatable {
        var currentTDD: Decimal
        var averageLastTenDays: Decimal
        var averageLastTwoHours: Decimal
    }

    /// `entries` oldest first, totals above 0, from the last ten days.
    static func tddSummary(_ entries: [(date: Date, total: Decimal)], now: Date) -> TDDSummary {
        let twoHoursAgo = now.addingTimeInterval(-2.hoursToSeconds)
        let recent = entries.filter { $0.date >= twoHoursAgo }
        return TDDSummary(
            currentTDD: entries.last?.total ?? 0,
            averageLastTenDays: entries.map(\.total).reduce(0, +) / Decimal(max(entries.count, 1)),
            averageLastTwoHours: recent.map(\.total).reduce(0, +) / Decimal(max(recent.count, 1))
        )
    }

    static func customOrefVariables(
        override: Override?,
        tdd: TDDSummary,
        preferences: Preferences?,
        now: Date
    ) -> TrioCustomOrefVariables {
        let weightPercentage = preferences?.weightPercentage ?? 1.0
        let maxSMBBasalMinutes = preferences?.maxSMBBasalMinutes ?? 30
        let maxUAMBasalMinutes = preferences?.maxUAMSMBBasalMinutes ?? 30
        let weightedTDD = weightPercentage * tdd.averageLastTwoHours + (1 - weightPercentage) * tdd.averageLastTenDays
        let hasTDD = tdd.currentTDD > 0

        return TrioCustomOrefVariables(
            average_total_data: hasTDD ? tdd.averageLastTenDays : 0,
            weightedAverage: hasTDD ? weightedTDD : 1,
            currentTDD: tdd.currentTDD,
            past2hoursAverage: hasTDD ? tdd.averageLastTwoHours : 0,
            date: now,
            overridePercentage: Decimal(override?.percentage ?? 100),
            useOverride: override?.enabled ?? false,
            duration: override?.duration ?? 0,
            unlimited: override?.indefinite ?? true,
            overrideTarget: override?.target ?? 0,
            smbIsOff: override?.smbIsOff ?? false,
            advancedSettings: override?.advancedSettings ?? false,
            isfAndCr: override?.isfAndCr ?? false,
            isf: override?.isf ?? false,
            cr: override?.cr ?? false,
            smbIsScheduledOff: override?.smbIsScheduledOff ?? false,
            start: override?.start ?? 0,
            end: override?.end ?? 0,
            smbMinutes: override?.smbMinutes ?? maxSMBBasalMinutes,
            uamMinutes: override?.uamMinutes ?? maxUAMBasalMinutes
        )
    }

    /// The preferences the profile is generated from: an active temp target's half-basal target, and
    /// no low-TT sensitivity without room in autosensMax. Clamp for the dosing mode after this.
    static func profilePreferences(
        _ preferences: Preferences,
        activeTempTarget: (target: Decimal, halfBasalTarget: Decimal?)?
    ) -> Preferences {
        var adjusted = preferences
        if let activeTempTarget,
           let effectiveHBT = TempTargetCalculations.computeEffectiveHBT(
               tempTargetHalfBasalTarget: activeTempTarget.halfBasalTarget,
               settingHalfBasalTarget: preferences.halfBasalExerciseTarget,
               target: activeTempTarget.target,
               autosensMax: preferences.autosensMax
           ),
           effectiveHBT != preferences.halfBasalExerciseTarget
        {
            adjusted.halfBasalExerciseTarget = effectiveHBT
        }
        if preferences.lowTemptargetLowersSensitivity, preferences.autosensMax <= 1 {
            adjusted.lowTemptargetLowersSensitivity = false
        }
        return adjusted
    }

    /// The preferences determineBasal runs with: clamped for the dosing mode, and no dynamic formula without
    /// enough TDD for it.
    static func determinationPreferences(
        _ preferences: Preferences,
        dosingMode: DosingMode,
        hasSufficientTDD: Bool
    ) -> Preferences {
        var adjusted = preferences.clamped(for: dosingMode)
        if !hasSufficientTDD, adjusted.useNewFormula || (adjusted.useNewFormula && adjusted.sigmoid) {
            adjusted.useNewFormula = false
            adjusted.sigmoid = false
        }
        return adjusted
    }

    /// Pump capability and the dosing mode, injected into the profile rather than persisted.
    static func prepareForDosing(_ profile: inout Profile, supportedBasalRates: [Decimal], dosingMode: DosingMode) {
        profile.supportedBasalRates = supportedBasalRates
        profile.suspendOnly = dosingMode.automation == .hypoSuspendOnly
    }

    /// The glucose determineBasal reads: the longest meal absorption plus half an hour.
    static func glucoseHours(_ preferences: Preferences) -> Decimal {
        preferences.maxMealAbsorptionTime + 0.5
    }

    /// Autosens runs again once its last result is half an hour old.
    static func autosensIsCurrent(_ autosens: Autosens?, now: Date) -> Bool {
        (autosens?.timestamp ?? .distantPast).addingTimeInterval(30 * 60) > now
    }

    static func iob(
        pumpHistory: [PumpHistoryEvent],
        profile: Profile,
        clock: Date,
        autosens: Autosens?
    ) throws -> [IobResult] {
        // FIXME: For now we'll just remove duplicate suspends here (ISSUE-399)
        try IobGenerator.generate(
            history: pumpHistory.removingDuplicateSuspendResumeEvents(),
            profile: profile,
            clock: clock,
            autosens: autosens
        )
    }

    static func meal(
        pumpHistory: [PumpHistoryEvent],
        profile: Profile,
        basalProfile: [BasalProfileEntry],
        clock: Date,
        carbs: [CarbsEntry],
        glucose: [BloodGlucose]
    ) throws -> ComputedCarbs? {
        try MealGenerator.generate(
            pumpHistory: pumpHistory,
            profile: profile,
            basalProfile: basalProfile,
            clock: clock,
            carbHistory: carbs,
            glucoseHistory: glucose
        )
    }

    /// The lower of the 8 h and 24 h ratios, as prepare/autosens.js does.
    static func autosens(
        glucose: [BloodGlucose],
        pumpHistory: [PumpHistoryEvent],
        basalProfile: [BasalProfileEntry],
        profile: Profile,
        carbs: [CarbsEntry],
        tempTargets: [TempTarget],
        clock: Date
    ) throws -> Autosens {
        // both runs use identical inputs, so compute the treatments once;
        // gated on the same count as the generate early return
        let precomputedTreatments = glucose.count >= 72 ? try IobHistory.calcTempTreatments(
            history: pumpHistory.map { $0.computedEvent() },
            profile: profile,
            clock: clock,
            autosens: nil,
            zeroTempDuration: nil
        ) : nil

        let ratio8h = try AutosensGenerator.generate(
            glucose: glucose,
            pumpHistory: pumpHistory,
            basalProfile: basalProfile,
            profile: profile,
            carbs: carbs,
            tempTargets: tempTargets,
            maxDeviations: 96,
            clock: clock,
            precomputedTreatments: precomputedTreatments
        )

        let ratio24h = try AutosensGenerator.generate(
            glucose: glucose,
            pumpHistory: pumpHistory,
            basalProfile: basalProfile,
            profile: profile,
            carbs: carbs,
            tempTargets: tempTargets,
            maxDeviations: 288,
            clock: clock,
            precomputedTreatments: precomputedTreatments
        )

        return ratio8h.ratio < ratio24h.ratio ? ratio8h : ratio24h
    }

    static func determineBasal(
        glucose: [BloodGlucose],
        currentTemp: TempBasal,
        iob: [IobResult],
        profile: Profile,
        autosens: Autosens?,
        meal: ComputedCarbs?,
        microBolusAllowed: Bool,
        preferences: Preferences,
        trioCustomOrefVariables: TrioCustomOrefVariables,
        clock: Date
    ) throws -> Determination? {
        guard let meal = meal, let autosens = autosens else {
            throw DeterminationError.missingInputs
        }

        return try DeterminationGenerator.generate(
            profile: profile,
            preferences: preferences,
            currentTemp: currentTemp,
            iobData: iob,
            mealData: meal,
            autosensData: autosens,
            glucose: glucose,
            microBolusAllowed: microBolusAllowed,
            trioCustomOrefVariables: trioCustomOrefVariables,
            currentTime: clock
        )
    }
}
