import Foundation
import Testing
@testable import Trio

/// The watch's loop against the phone's: the same scenarios through `UntetheredAlgorithm.determine` and through the
/// steps `OpenAPS.createProfiles`, `APSManager.autosense` and `OpenAPS.determineBasal` take, byte for byte.
@Suite("Untethered parity with the phone") struct UntetheredParityTests {
    // MARK: Determination

    /// The phone's loop as `APSManager.loop` runs it, on the scenario's data instead of its storage.
    static func phone(
        _ scenario: ParityScenario,
        override: Override?,
        tdd: OrefPipeline.TDDSummary,
        hasSufficientTDD: Bool
    ) throws -> (Determination?, Autosens) {
        let activeTempTarget = scenario.tempTargets.last.flatMap { tempTarget in
            tempTarget.targetBottom.map { (target: $0, halfBasalTarget: tempTarget.halfBasalTarget) }
        }
        // createProfiles
        var profile = try ProfileGenerator.generate(
            pumpSettings: scenario.pumpSettings,
            bgTargets: scenario.bgTargets,
            basalProfile: scenario.basalProfile,
            isf: scenario.isf,
            preferences: OrefPipeline.profilePreferences(scenario.preferences, activeTempTarget: activeTempTarget)
                .clamped(for: .closed),
            carbRatios: scenario.carbRatios,
            tempTargets: scenario.tempTargets,
            clock: scenario.clock
        )
        // autosense, on the stored profile
        var autosens = try OrefPipeline.autosens(
            glucose: scenario.glucose,
            pumpHistory: scenario.pumpHistory,
            basalProfile: scenario.basalProfile,
            profile: profile,
            carbs: scenario.carbs,
            tempTargets: scenario.tempTargets,
            clock: scenario.clock
        )
        autosens.timestamp = scenario.clock
        // determineBasal
        OrefPipeline.prepareForDosing(&profile, supportedBasalRates: ParityInputs.supportedBasalRates(), dosingMode: .closed)
        let preferences = OrefPipeline.determinationPreferences(
            scenario.preferences,
            dosingMode: .closed,
            hasSufficientTDD: hasSufficientTDD
        )
        let hours = Double(truncating: OrefPipeline.glucoseHours(scenario.preferences) as NSNumber)
        let glucose = scenario.glucose.filter { $0.dateString >= scenario.clock.addingTimeInterval(-hours * 3600) }
        let meal = try OrefPipeline.meal(
            pumpHistory: scenario.pumpHistory,
            profile: profile,
            basalProfile: scenario.basalProfile,
            clock: scenario.clock,
            carbs: scenario.carbs,
            glucose: glucose
        )
        let iob = try OrefPipeline.iob(
            pumpHistory: scenario.pumpHistory,
            profile: profile,
            clock: scenario.clock,
            autosens: autosens
        )
        var determination = try OrefPipeline.determineBasal(
            glucose: glucose,
            currentTemp: scenario.currentTemp,
            iob: iob,
            profile: profile,
            autosens: autosens,
            meal: meal,
            microBolusAllowed: true,
            preferences: preferences,
            trioCustomOrefVariables: OrefPipeline.customOrefVariables(
                override: override,
                tdd: tdd,
                preferences: scenario.preferences,
                now: scenario.clock
            ),
            clock: scenario.clock
        )
        // without `deliverAt` `OpenAPS.determineBasal` throws "No determination data"
        guard let deliverAt = determination?.deliverAt else { return (nil, autosens) }
        determination?.timestamp = deliverAt
        return (determination, autosens)
    }

    /// The scenario as the watch holds it: the grant's settings, no autosens yet, so it runs its own.
    static func watch(
        _ scenario: ParityScenario,
        override: Override?,
        tdd: OrefPipeline.TDDSummary,
        hasSufficientTDD: Bool
    ) -> UntetheredAlgorithm.Inputs {
        let grant = UntetheredGrant(
            leaseExpiresAt: scenario.clock,
            pumpConfiguration: Data(),
            cgmConfiguration: Data(),
            pumpSettings: scenario.pumpSettings,
            bgTargets: scenario.bgTargets,
            basalProfile: scenario.basalProfile,
            insulinSensitivities: scenario.isf,
            carbRatios: scenario.carbRatios,
            preferences: scenario.preferences,
            dosingMode: .closed,
            smoothGlucose: false,
            units: .mgdL,
            tdd: tdd,
            hasSufficientTDD: hasSufficientTDD,
            tddRecentRows: [],
            tddHours: [],
            tddPumpHistory: [],
            autosens: nil,
            reservoir: 150,
            maxBolus: 10,
            maxCarbs: 100,
            bolusCalculator: UntetheredBolusCalculatorSettings(
                fraction: 0.8,
                fattyMeals: false,
                fattyMealFactor: 0.7,
                sweetMeals: false,
                sweetMealFactor: 1
            ),
            glucoseColorScheme: "staticColor",
            lastDetermination: nil,
            lastLoopDate: nil,
            lowGlucose: 70,
            highGlucose: 180,
            pumpHistory: scenario.pumpHistory,
            glucose: scenario.glucose,
            smoothedGlucose: [:],
            carbs: scenario.carbs,
            activeOverride: override,
            tempTargets: scenario.tempTargets,
            overridePresets: [],
            tempTargetPresets: [],
            linkedOverrideID: nil
        )
        return UntetheredAlgorithm.Inputs(
            grant: grant,
            pumpHistory: scenario.pumpHistory,
            glucose: scenario.glucose,
            carbs: scenario.carbs,
            tempTargets: scenario.tempTargets,
            activeTempTarget: scenario.tempTargets.last,
            override: override,
            autosens: nil,
            tdd: tdd,
            hasSufficientTDD: hasSufficientTDD,
            currentTemp: scenario.currentTemp,
            supportedBasalRates: ParityInputs.supportedBasalRates(),
            now: scenario.clock
        )
    }

    static func override(for scenario: String, at clock: Date) -> Override? {
        guard scenario == "override-active" else { return nil }
        return Override(
            name: "Sport", enabled: true, date: clock.addingTimeInterval(-30 * 60), duration: 120, indefinite: false,
            percentage: 130, smbIsOff: false, isPreset: true, id: "o-1", overrideTarget: true, target: 90,
            advancedSettings: false, isfAndCr: true, isf: true, cr: true, smbIsScheduledOff: false, start: 0, end: 0,
            smbMinutes: 30, uamMinutes: 30
        )
    }

    static func tdd(for scenario: String) -> (OrefPipeline.TDDSummary, sufficient: Bool) {
        scenario.hasPrefix("dynamic-isf")
            ? (OrefPipeline.TDDSummary(currentTDD: 38.5, averageLastTenDays: 35.8, averageLastTwoHours: 3.1), true)
            : (OrefPipeline.TDDSummary(currentTDD: 0, averageLastTenDays: 0, averageLastTwoHours: 0), false)
    }

    /// The outcome as text: the determination and autosens, or the error both sides must raise alike.
    static func outcome(_ run: () throws -> (Determination?, Autosens?)?) -> String {
        do {
            guard let result = try run() else { return "no determination" }
            let (determination, autosens) = result
            return try ParityHarness.normalizeDeterminationId(ParityHarness.canonicalJSON(determination))
                + ParityHarness.canonicalJSON(autosens)
        } catch {
            return "error: \(error)"
        }
    }

    @Test("determination: the watch doses as the phone", arguments: ParityScenarios.allNames) func determination(
        scenarioName: String
    ) {
        let scenario = ParityScenarios.build(scenarioName)
        let override = Self.override(for: scenarioName, at: scenario.clock)
        let (tdd, sufficient) = Self.tdd(for: scenarioName)
        let phone = Self.outcome {
            let (determination, autosens) = try Self.phone(scenario, override: override, tdd: tdd, hasSufficientTDD: sufficient)
            return determination.map { ($0, Optional(autosens)) }
        }
        let watch = Self.outcome {
            try UntetheredAlgorithm.determine(Self.watch(scenario, override: override, tdd: tdd, hasSufficientTDD: sufficient))
        }
        #expect(watch == phone, "\(scenarioName): the watch's outcome differs from the phone's")
        #expect(!phone.hasPrefix("error") || scenarioName == "stale-bg-error", "\(scenarioName): \(phone)")
    }

    @Test("determination: a current autosens is kept, as the phone keeps it") func currentAutosens() throws {
        let scenario = ParityScenarios.build("autosens-resistance")
        let (tdd, sufficient) = Self.tdd(for: scenario.name)
        var stored = Autosens(ratio: 0.9, newisf: nil)
        stored.timestamp = scenario.clock.addingTimeInterval(-29 * 60)
        let base = Self.watch(scenario, override: nil, tdd: tdd, hasSufficientTDD: sufficient)
        let inputs = UntetheredAlgorithm.Inputs(
            grant: base.grant, pumpHistory: base.pumpHistory, glucose: base.glucose, carbs: base.carbs,
            tempTargets: base.tempTargets, activeTempTarget: base.activeTempTarget, override: nil, autosens: stored,
            tdd: tdd, hasSufficientTDD: sufficient, currentTemp: base.currentTemp,
            supportedBasalRates: base.supportedBasalRates, now: scenario.clock
        )
        #expect(OrefPipeline.autosensIsCurrent(stored, now: scenario.clock))
        let (_, used) = try #require(try UntetheredAlgorithm.determine(inputs))
        #expect(used == stored)
    }

    // MARK: TDD, which travels in hours

    /// Eleven days of rows every five minutes, past the ten-day edge, half a step off the clock's grid so none sits
    /// on a window's edge.
    static func rows(endingAt now: Date, total: (Int) -> Decimal) -> [UntetheredTDD] {
        (0 ..< 11 * 288).map { index in
            UntetheredTDD(
                date: now.addingTimeInterval(-Double(index) * 300 - 150),
                total: total(index),
                bolus: 0,
                tempBasal: 0,
                scheduledBasal: 0,
                weightedAverage: nil
            )
        }.reversed()
    }

    /// What the phone reads from its rows: `OpenAPS.tddSummary`, `BaseTDDStorage.calculateWeightedAverage` and
    /// `BaseTDDStorage.hasSufficientTDD`.
    static func phoneTDD(_ rows: [UntetheredTDD], weight: Decimal, now: Date)
        -> (summary: OrefPipeline.TDDSummary, weighted: Decimal, sufficient: Bool)
    {
        let tenDaysAgo = now.addingTimeInterval(-10 * 24 * 3600)
        let twoHoursAgo = now.addingTimeInterval(-2 * 3600)
        let entries = rows.filter { $0.date > tenDaysAgo && $0.total > 0 }.map { (date: $0.date, total: $0.total) }
        let recent = rows.filter { $0.date >= twoHoursAgo }
        let tenDays = rows.filter { $0.date >= tenDaysAgo }
        let weighted = TDDCalculator.weightedAverage(
            recentTotal: recent.reduce(0) { $0 + $1.total },
            recentCount: recent.count,
            tenDayTotal: tenDays.reduce(0) { $0 + $1.total },
            tenDayCount: tenDays.count,
            weight: weight
        )
        let week = rows.filter { $0.date > now.addingTimeInterval(-7 * 24 * 3600) && $0.total > 0 }.count
        return (OrefPipeline.tddSummary(entries, now: now), weighted, week >= TDDCalculator.sufficientRowCount)
    }

    /// The same rows as the watch holds them: the phone's ten days in hours, its last two hours as rows.
    static func watchTDD(_ rows: [UntetheredTDD], weight: Decimal, now: Date)
        -> (summary: OrefPipeline.TDDSummary?, weighted: Decimal, sufficient: Bool?)
    {
        let hours = UntetheredTDDHour.hours(rows)
        let recent = rows.filter { $0.date >= now.addingTimeInterval(-2 * 3600) }
        return (
            UntetheredAlgorithm.tddSummary(rows: recent, hours: hours, now: now),
            UntetheredAlgorithm.weightedAverage(rows: recent, hours: hours, weight: weight, now: now),
            UntetheredAlgorithm.hasSufficientTDD(hours: hours, now: now)
        )
    }

    /// 30 to 50 U, every seventh row 0 (a gap in the pump's data): rows above 0 and all rows count differently.
    static func varied(_ index: Int) -> Decimal { index % 7 == 3 ? 0 : 30 + Decimal(index * 13 % 21) }

    @Test("TDD: on the hour the hours hold exactly the phone's rows") func tddOnTheHour() {
        let now = Date(timeIntervalSince1970: 1_800_003_600) // a full hour
        let rows = Self.rows(endingAt: now, total: Self.varied)
        let phone = Self.phoneTDD(rows, weight: 0.65, now: now)
        let watch = Self.watchTDD(rows, weight: 0.65, now: now)
        #expect(watch.summary == phone.summary)
        #expect(watch.weighted == phone.weighted)
        #expect(watch.sufficient == phone.sufficient)
    }

    @Test(
        "TDD: between hours the ten-day edge is off by half an hour at most",
        arguments: [5, 20, 29, 31, 40, 55]
    ) func tddBetweenHours(minute: Int) throws {
        let now = Date(timeIntervalSince1970: 1_800_003_600 + Double(minute * 60))
        let rows = Self.rows(endingAt: now, total: Self.varied)
        let phone = Self.phoneTDD(rows, weight: 0.65, now: now)
        let watch = Self.watchTDD(rows, weight: 0.65, now: now)
        let summary = try #require(watch.summary)
        // the last two hours are rows on both sides
        #expect(summary.currentTDD == phone.summary.currentTDD)
        #expect(summary.averageLastTwoHours == phone.summary.averageLastTwoHours)
        // at most six rows of the oldest hour counted or left out, of some 2400 rows: six times the largest total
        // over that many
        let bound = Decimal(50 * 6) / Decimal(2400)
        #expect(abs(summary.averageLastTenDays - phone.summary.averageLastTenDays) <= bound)
        #expect(abs(watch.weighted - phone.weighted) <= bound)
    }

    @Test("TDD: enough rows for the dynamic formula, at the threshold, as the phone counts them") func tddThreshold() {
        let now = Date(timeIntervalSince1970: 1_800_003_600)
        let threshold = TDDCalculator.sufficientRowCount
        for positive in [threshold - 1, threshold] {
            // the newest `positive` rows of the week above 0, the rest 0
            let rows = Self.rows(endingAt: now) { $0 < positive ? 40 : 0 }
            let phone = Self.phoneTDD(rows, weight: 0.65, now: now).sufficient
            #expect(phone == (positive >= threshold))
            #expect(Self.watchTDD(rows, weight: 0.65, now: now).sufficient == phone)
        }
    }

    @Test("TDD: the hours slide as the phone's window does, a session's own rows included") func tddSliding() throws {
        let start = Date(timeIntervalSince1970: 1_800_003_600)
        var rows = Self.rows(endingAt: start, total: Self.varied)
        var hours = UntetheredTDDHour.hours(rows)
        // six hours of the watch's own loops, each row added as `calculateTDD` adds it
        for step in 1 ... 72 {
            let now = start.addingTimeInterval(Double(step) * 300)
            let row = UntetheredTDD(
                date: now, total: Self.varied(step), bolus: 0, tempBasal: 0, scheduledBasal: 0, weightedAverage: nil
            )
            rows.append(row)
            UntetheredTDDHour.add(row, to: &hours)
            hours = UntetheredTDDHour.inWindow(hours, now: now)
        }
        let now = start.addingTimeInterval(72 * 300)
        let recent = rows.filter { $0.date >= now.addingTimeInterval(-2 * 3600) }
        let watch = try #require(UntetheredAlgorithm.tddSummary(rows: recent, hours: hours, now: now))
        let phone = Self.phoneTDD(rows, weight: 0.65, now: now)
        // six hours on, a full hour again: the same rows
        #expect(watch == phone.summary)
        #expect(UntetheredAlgorithm.weightedAverage(rows: recent, hours: hours, weight: 0.65, now: now) == phone.weighted)
    }
}
