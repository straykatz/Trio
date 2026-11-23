import CoreData
import Foundation
import Swinject
import Testing
@testable import Trio

/// A loop may only enact the determination it saved itself, and only once.
@Suite("Determination enactment", .serialized) struct DeterminationEnactmentTests {
    private let coreDataStack: CoreDataStack
    private let openAPS: OpenAPS

    init() async throws {
        coreDataStack = try await CoreDataStack.createForTests()
        let resolver = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: coreDataStack.newTaskContext())
        ]).resolver
        openAPS = OpenAPS(
            storage: try #require(resolver.resolve(FileStorage.self)),
            tddStorage: try #require(resolver.resolve(TDDStorage.self)),
            glucoseStorage: try #require(resolver.resolve(GlucoseStorage.self)),
            carbsStorage: try #require(resolver.resolve(CarbsStorage.self))
        )
    }

    private static func makeDetermination(id: UUID, deliverAt: Date = Date()) -> Determination {
        Determination(
            id: id,
            reason: "",
            units: 0.5,
            insulinReq: nil,
            eventualBG: nil,
            sensitivityRatio: nil,
            rate: 1.5,
            duration: 30,
            iob: nil,
            cob: nil,
            predictions: nil,
            deliverAt: deliverAt,
            carbsReq: nil,
            temp: .absolute,
            bg: nil,
            reservoir: nil,
            isf: nil,
            timestamp: deliverAt,
            tdd: nil,
            current_target: nil,
            minDelta: nil,
            expectedDelta: nil,
            minGuardBG: nil,
            minPredBG: nil,
            threshold: nil,
            carbRatio: nil,
            received: nil
        )
    }

    /// Stores a recent determination with an SMB, as an earlier loop or a standalone determination left it.
    private func storeEarlierDetermination(id: UUID, minutesAgo: Double, enacted: Bool) async throws {
        let context = coreDataStack.newTaskContext()
        try await context.perform {
            let determination = OrefDetermination(context: context)
            determination.id = id
            determination.deliverAt = Date().addingTimeInterval(-minutesAgo * 60)
            determination.rate = 2
            determination.duration = 30
            determination.smbToDeliver = 1
            determination.enacted = enacted
            try context.save()
        }
    }

    private func dosingValues(of id: UUID) async throws -> (NSDecimalNumber?, TimeInterval?, NSDecimalNumber?)? {
        try await BaseAPSManager.dosingValues(ofDeterminationWithID: id, on: coreDataStack.newTaskContext())
    }

    @Test("Failed determination save throws and leaves nothing to enact") func failedSaveIsNotEnacted() async throws {
        try await storeEarlierDetermination(id: UUID(), minutesAgo: 5, enacted: true)
        try await storeEarlierDetermination(id: UUID(), minutesAgo: 1, enacted: false)

        // a read-only store makes the save fail
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: CoreDataStack.managedObjectModel)
        try coordinator.addPersistentStore(
            ofType: NSInMemoryStoreType,
            configurationName: nil,
            at: nil,
            options: [NSReadOnlyPersistentStoreOption: true]
        )
        let failingContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        failingContext.persistentStoreCoordinator = coordinator
        let id = UUID()
        let determination = Self.makeDetermination(id: id)

        await #expect(throws: Error.self) {
            try await openAPS.processDetermination(determination, on: failingContext)
        }
        #expect(try await dosingValues(of: id) == nil)
    }

    @Test("Already enacted determination is not enacted again") func enactedIsNotEnactedAgain() async throws {
        let id = UUID()
        try await storeEarlierDetermination(id: id, minutesAgo: 5, enacted: true)

        #expect(try await dosingValues(of: id) == nil)
    }

    @Test("Saved determination is enacted with its own values") func savedDeterminationIsEnacted() async throws {
        try await storeEarlierDetermination(id: UUID(), minutesAgo: 5, enacted: true)
        let id = UUID()
        let determination = Self.makeDetermination(id: id, deliverAt: Date().addingTimeInterval(-60))
        try await storeEarlierDetermination(id: UUID(), minutesAgo: 0, enacted: false)

        try await openAPS.processDetermination(determination, on: coreDataStack.newTaskContext())

        let values = try #require(try await dosingValues(of: id))
        #expect(values.0?.doubleValue == 1.5)
        #expect(abs((values.1 ?? 0) - 30 * 60) < 0.001)
        #expect(values.2?.doubleValue == 0.5)
    }
}
