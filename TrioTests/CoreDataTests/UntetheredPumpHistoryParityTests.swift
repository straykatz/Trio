import CoreData
import Foundation
import Swinject
import Testing

@testable import LoopKit
@testable import Trio

/// The pump's events as the phone stores and reads them (`PumpHistoryStorage.storePumpEvents`, then
/// `OpenAPS.nativePumpHistory` for oref and `getPumpHistory` for the TDD) against the watch's
/// `UntetheredAlgorithm.historyEvents` and `tddEvent` on the same events. The ids differ by design: the phone
/// numbers its rows, the watch keys them by the pump's sync identifier.
@Suite("Untethered pump history parity with the phone", .serialized) struct UntetheredPumpHistoryParityTests: Injectable {
    @Injected() var storage: PumpHistoryStorage!
    @Injected() var settingsManager: SettingsManager!
    let resolver: Resolver
    var coreDataStack: CoreDataStack!
    var testContext: NSManagedObjectContext!

    init() async throws {
        coreDataStack = try await CoreDataStack.createForTests()
        testContext = coreDataStack.newTaskContext()
        let assembler = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: testContext)
        ])
        resolver = assembler.resolver
        injectServices(resolver)
    }

    /// A finished day's mix: meal, SMB and external boluses with odd amounts, a full and a cancelled temp basal, a
    /// suspension and the schedule in between.
    static func events(from start: Date) -> [NewPumpEvent] {
        func event(_ minutes: Double, _ type: PumpEventType, _ dose: DoseEntry) -> NewPumpEvent {
            NewPumpEvent(
                date: start + minutes * 60, dose: dose, raw: Data(dose.syncIdentifier!.utf8), title: "\(type)", type: type
            )
        }
        func bolus(_ minutes: Double, _ id: String, _ units: Double, automatic: Bool, external: Bool = false) -> NewPumpEvent {
            event(minutes, .bolus, DoseEntry(
                type: .bolus, startDate: start + minutes * 60, endDate: start + minutes * 60 + 40, value: units,
                unit: .units, deliveredUnits: units, syncIdentifier: id, insulinType: .novolog, automatic: automatic,
                manuallyEntered: external
            ))
        }
        func temp(_ minutes: Double, _ id: String, _ rate: Double, for length: Double, delivered: Double?) -> NewPumpEvent {
            event(minutes, .tempBasal, DoseEntry(
                type: .tempBasal, startDate: start + minutes * 60, endDate: start + (minutes + length) * 60, value: rate,
                unit: .unitsPerHour, deliveredUnits: delivered, syncIdentifier: id, insulinType: .novolog, automatic: true
            ))
        }
        return [
            bolus(0, "b-meal", 4.37, automatic: false),
            bolus(20, "b-smb", 0.35, automatic: true),
            bolus(25, "b-odd", 0.88, automatic: false),
            bolus(30, "b-external", 1.0, automatic: false, external: true),
            temp(35, "t-full", 0.85, for: 30, delivered: 0.45),
            temp(65, "t-cancelled", 2.35, for: 12.5, delivered: 0.5),
            event(80, .basal, DoseEntry(
                type: .basal, startDate: start + 80 * 60, endDate: start + 110 * 60, value: 0.8, unit: .unitsPerHour,
                deliveredUnits: 0.4, syncIdentifier: "s-schedule", insulinType: .novolog
            )),
            event(110, .suspend, DoseEntry(
                type: .suspend, startDate: start + 110 * 60, value: 0, unit: .units, syncIdentifier: "p-suspend"
            )),
            event(140, .resume, DoseEntry(
                type: .resume, startDate: start + 140 * 60, value: 0, unit: .units, syncIdentifier: "p-resume"
            ))
        ]
    }

    /// Every field but the id, oldest first.
    static func withoutID(_ events: [PumpHistoryEvent]) -> [PumpHistoryEvent] {
        events.map { event in
            PumpHistoryEvent(
                id: "", type: event.type, timestamp: event.timestamp, amount: event.amount, duration: event.duration,
                durationMin: event.durationMin, rate: event.rate, temp: event.temp, carbInput: event.carbInput,
                fatInput: event.fatInput, proteinInput: event.proteinInput, note: event.note, isSMB: event.isSMB,
                isExternal: event.isExternal, isExternalInsulin: event.isExternalInsulin,
                isScheduledBasal: event.isScheduledBasal, deliveredUnits: event.deliveredUnits,
                programmedAmount: event.programmedAmount, insulinType: event.insulinType
            )
        }.sorted { ($0.timestamp, $0.type.rawValue) < ($1.timestamp, $1.type.rawValue) }
    }

    /// What `TDDCalculator` reads, oldest first: the watch's bolus row carries the algorithm's flags on top.
    static func asTDDReads(_ events: [PumpHistoryEvent]) -> [PumpHistoryEvent] {
        withoutID(events).map { event in
            event.type == .tempBasal
                ? PumpHistoryEvent(
                    id: "", type: event.type, timestamp: event.timestamp, amount: event.amount, duration: event.duration,
                    isScheduledBasal: event.isScheduledBasal, deliveredUnits: event.deliveredUnits
                )
                : PumpHistoryEvent(id: "", type: event.type, timestamp: event.timestamp, amount: event.amount)
        }
    }

    @Test("oref's history: the watch reads the pump's events as the phone does") func algorithmHistory() async throws {
        let events = Self.events(from: Date().addingTimeInterval(-4 * 3600))
        try await storage.storePumpEvents(events, replacePendingEvents: false)
        let ids = try await coreDataStack.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: testContext,
            predicate: NSPredicate.pumpHistoryLast1440Minutes,
            key: "timestamp",
            ascending: false
        ) as? [PumpEventStored] ?? []
        let phone = await testContext.perform {
            OpenAPS.nativePumpHistory(ids.map(\.objectID), orphanedResumes: [], from: self.testContext)
        }

        let increment = settingsManager.preferences.bolusIncrement
        let watch = events.flatMap { event in
            UntetheredAlgorithm.historyEvents(event, id: event.dose?.syncIdentifier ?? "", bolusIncrement: increment)
        }
        #expect(Self.withoutID(watch) == Self.withoutID(phone))
    }

    @Test("TDD's history: the watch keeps what the phone's TDD reads") func tddHistory() async throws {
        let events = Self.events(from: Date().addingTimeInterval(-4 * 3600))
        try await storage.storePumpEvents(events, replacePendingEvents: false)
        let phone = try await storage.getPumpHistory()

        let increment = settingsManager.preferences.bolusIncrement
        let watch = events.compactMap { event in
            UntetheredAlgorithm.tddEvent(event, id: event.dose?.syncIdentifier ?? "", bolusIncrement: increment)
        }
        #expect(Self.asTDDReads(watch) == Self.asTDDReads(phone))
        let basalProfile = [BasalProfileEntry(start: "00:00", minutes: 0, rate: 0.8)]
        let now = Date()
        let phoneTotal = TDDCalculator.calculate(
            pumpHistory: phone, basalProfile: basalProfile, now: now, roundToSupportedBasalRate: { $0 }
        )
        let watchTotal = TDDCalculator.calculate(
            pumpHistory: watch.sorted { $0.timestamp > $1.timestamp }, basalProfile: basalProfile, now: now,
            roundToSupportedBasalRate: { $0 }
        )
        #expect(watchTotal == phoneTotal)
    }

    @Test("start without the phone: the phone's bolus after the watch's copy survives the take-back")
    func keepsInFlight() async throws {
        let start = Date().addingTimeInterval(-3600)
        func bolus(_ minutes: Double, _ id: String) -> NewPumpEvent {
            NewPumpEvent(
                date: start + minutes * 60,
                dose: DoseEntry(
                    type: .bolus, startDate: start + minutes * 60, endDate: start + minutes * 60 + 266, value: 6.65,
                    unit: .units, syncIdentifier: id, automatic: false, isMutable: true
                ),
                raw: Data(id.utf8),
                title: "bolus",
                type: .bolus
            )
        }
        // one the copy held, which the watch reports, and one after it, which nobody does
        try await storage.storePumpEvents([bolus(0, "in-copy"), bolus(10, "after-copy")], replacePendingEvents: false)
        #expect(try await storage.keepInFlightDoses(startedAfter: start + 5 * 60) == 1)
        // the take-back's pending report asserts neither
        try await storage.storePumpEvents([], replacePendingEvents: true)
        let kept = try await storage.getPumpHistory().filter { $0.type == .bolus }
        #expect(kept.count == 1)
        // as programmed, to the bolus increment
        #expect(abs(NSDecimalNumber(decimal: (kept.first?.amount ?? 0) - 6.65).doubleValue) <= 0.1)
    }
}
