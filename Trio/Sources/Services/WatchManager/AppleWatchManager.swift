import Combine
import CoreData
import CryptoKit
import Foundation
import G7SensorKit
import LoopKit
import LoopKitUI
import Swinject
import UIKit
import WatchConnectivity

/// Protocol defining the base functionality for Watch communication
protocol WatchManager {
    func setupWatchState() async -> WatchState?
}

/// Main implementation of the Watch communication manager
/// Handles bidirectional communication between iPhone and Apple Watch
final class BaseWatchManager: NSObject, WCSessionDelegate, Injectable, WatchManager {
    private var session: WCSession?
    private var lastComplicationTransfer = Date.distantPast
    private static let complicationTransferInterval: TimeInterval = 28 * 60
    static let complicationRangeLowKey = "complicationRangeLowMgDL"
    static let complicationRangeHighKey = "complicationRangeHighMgDL"
    static let complicationColorSchemeKey = "complicationColorScheme"
    static let complicationTargetKey = "complicationTargetMgDL"

    @Injected() var broadcaster: Broadcaster!
    @Injected() private var apsManager: APSManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var keychain: Keychain!
    @Injected() private var fileStorage: FileStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var determinationStorage: DeterminationStorage!
    @Injected() private var overrideStorage: OverrideStorage!
    @Injected() private var tempTargetStorage: TempTargetsStorage!
    @Injected() private var adjustmentManager: AdjustmentManager!
    @Injected() private var bolusCalculationManager: BolusCalculationManager!
    @Injected() private var iobService: IOBService!
    @Injected() private var notificationsManager: UserNotificationsManager!
    @Injected() private var fetchGlucoseManager: FetchGlucoseManager!
    @Injected() private var untethered: UntetheredPhoneManager!
    @Injected() private var mealTimeReminderService: MealTimeReminderService!

    private var units: GlucoseUnits = .mgdL
    private var glucoseColorScheme: GlucoseColorScheme = .staticColor
    private var lowGlucose: Decimal = 70.0
    private var highGlucose: Decimal = 180.0
    private var activeBolusAmount: Double = 0.0

    // Queue for handling Core Data change notifications
    private let queue = DispatchQueue(label: "BaseWatchManagerManager.queue", qos: .utility)
    private var coreDataPublisher: AnyPublisher<Set<NSManagedObjectID>, Never>?
    private var subscriptions = Set<AnyCancellable>()

    /// Longest wait for a running loop before a state goes out (dev #1598).
    private static let maxLoopWait: TimeInterval = 30

    typealias PumpEvent = PumpEventStored.EventType

    let viewContext = CoreDataStack.shared.persistentContainer.viewContext

    init(resolver: Resolver) {
        super.init()
        injectServices(resolver)
        setupWatchSession()

        units = settingsManager.settings.units
        glucoseColorScheme = settingsManager.settings.glucoseColorScheme
        lowGlucose = settingsManager.settings.low
        highGlucose = settingsManager.settings.high
        broadcaster.register(SettingsObserver.self, observer: self)
        broadcaster.register(PumpSettingsObserver.self, observer: self)
        broadcaster.register(SnoozeObserver.self, observer: self)

        // Observer for OrefDetermination and adjustments
        coreDataPublisher =
            CoreDataStack.shared.contentChangePublisher
                .receive(on: queue)
                .share()
                .eraseToAnyPublisher()

        // Observer for glucose and manual glucose
        glucoseStorage.updatePublisher
            .receive(on: DispatchQueue.global(qos: .background))
            .sink { [weak self] _ in
                guard let self = self else { return }
                // Skip if no watch is paired or app not installed
                guard let session = self.session, self.watchNeedsState(session) else { return }
                self.pushWatchState()
            }
            .store(in: &subscriptions)

        // the meal-time reminder was set or cleared: its countdown on the watch follows at once
        Foundation.NotificationCenter.default.publisher(for: .mealTimeReminderDidChange)
            .receive(on: DispatchQueue.global(qos: .background))
            .sink { [weak self] _ in
                guard let self = self, let session = self.session, self.watchNeedsState(session) else { return }
                self.pushWatchState()
            }
            .store(in: &subscriptions)

        iobService.iobPublisher
            .receive(on: DispatchQueue.global(qos: .background))
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.pushWatchState()
            }
            .store(in: &subscriptions)

        registerHandlers()
    }

    private func registerHandlers() {
        coreDataPublisher?.filteredByEntityName("OrefDetermination").sink { [weak self] _ in
            guard let self = self else { return }
            // Skip if no watch is paired or app not installed
            guard let session = self.session, self.watchNeedsState(session) else { return }
            self.pushWatchState()
        }.store(in: &subscriptions)

        // Due to the Batch insert this only is used for observing Deletion of Glucose entries
        coreDataPublisher?.filteredByEntityName("GlucoseStored").sink { [weak self] _ in
            guard let self = self else { return }
            // Skip if no watch is paired or app not installed
            guard let session = self.session, self.watchNeedsState(session) else { return }
            self.pushWatchState()
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("PumpEventStored").sink { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.getActiveBolusAmount()
            }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("OverrideStored").sink { [weak self] _ in
            guard let self = self else { return }
            // Skip if no watch is paired or app not installed
            guard let session = self.session, self.watchNeedsState(session) else { return }
            self.pushWatchState()
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("TempTargetStored").sink { [weak self] _ in
            guard let self = self else { return }
            // Skip if no watch is paired or app not installed
            guard let session = self.session, self.watchNeedsState(session) else { return }
            self.pushWatchState()
        }.store(in: &subscriptions)
    }

    /// The watch app is open, or Trio sits on the active watch face, which shows the newest reading with the
    /// app in the background too.
    private func watchNeedsState(_ session: WCSession) -> Bool {
        session.isPaired && session.isWatchAppInstalled
            && (session.isReachable || session.isComplicationEnabled || fallbackWatchesPhone)
    }

    /// For the untethered watch's own Nightscout upload: the address and the API secret as Nightscout's upload header
    /// takes it (SHA-1), never the secret itself. Nil when the watch doesn't upload, which clears its copy.
    private func nightscoutForWatch() -> UntetheredNightscoutCredentials? {
        let settings = settingsManager.settings
        guard settings.nightscoutUploadWatch, settings.untetheredModeWatch, settings.isUploadEnabled,
              let urlString = keychain.getValue(String.self, forKey: NightscoutConfig.Config.urlKey),
              let url = URL(string: urlString), url.host != nil,
              let secret = keychain.getValue(String.self, forKey: NightscoutConfig.Config.secretKey), !secret.isEmpty
        else { return nil }
        let hash = Insecure.SHA1.hash(data: Data(secret.utf8)).map { String(format: "%02hhx", $0) }.joined()
        return UntetheredNightscoutCredentials(url: url, secretHash: hash, uploadsGlucose: settings.uploadGlucose)
    }

    /// The watch starts by itself when the phone's readings stop reaching it, and it learns of them only from the
    /// watch state: with that on, the state goes out whether the watch app is open or Trio is on the face or not.
    /// On 28 October, after iOS and watchOS updates, the phone reported no Trio complication on a face that had one,
    /// skipped every state for an hour and a half, and the watch started by itself four times beside the phone.
    private var fallbackWatchesPhone: Bool {
        let settings = settingsManager.settings
        return settings.fallbackLoopWatch && settings.untetheredModeWatch && settings.allowUntetheredStartWithoutPhoneWatch
    }

    /// Sets up the WatchConnectivity session if the device supports it
    private func setupWatchSession() {
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            self.session = session

            debug(.watch, "Watch session set up, paired: \(session.isPaired)")
        } else {
            debug(.watch, "Watch connectivity not supported on this device")
        }
    }

    /// Attempts to reestablish the Watch connection if it becomes unreachable
    private func retryConnection() {
        guard let session = session else { return }

        if !session.isReachable {
            debug(.watch, "Reactivating watch session")
            session.activate()
        }
    }

    /// Prepares the current state data to be sent to the Watch
    /// - Returns: WatchState containing current glucose readings and trends and determination infos for displaying cob and iob in the view
    func setupWatchState() async -> WatchState? {
        // Check if a watch is paired and reachable before doing expensive calculations. With Trio on the
        // active watch face the state is needed while the watch app is in the background too: otherwise the
        // face only got a reading when the app was opened.
        guard let session = session, watchNeedsState(session) else {
            debug(
                .watch,
                "Watch state skipped: paired \(session?.isPaired ?? false), app installed \(session?.isWatchAppInstalled ?? false), reachable \(session?.isReachable ?? false), Trio on the face \(session?.isComplicationEnabled ?? false)"
            )
            return nil
        }

        // Skip if watch session is not activated
        guard session.activationState == .activated else {
            debug(.watch, "Watch state skipped: session not activated")
            return nil
        }
        do {
            let context = CoreDataStack.shared.newTaskContext()
            context.name = "setupWatchState"

            // Get NSManagedObjectIDs
            let glucoseIds = try await fetchGlucose()
            let determinationIds = try await determinationStorage.fetchLastDeterminationObjectID(
                predicate: NSPredicate.predicateFor30MinAgoForDetermination
            )
            let overridePresetIds = try await overrideStorage.fetchForOverridePresets()
            let tempTargetPresetIds = try await tempTargetStorage.fetchForTempTargetPresets()
            // Per build: the target follows the time.
            let currentGlucoseTarget = await getCurrentGlucoseTarget() ?? Decimal(100)

            // Get NSManagedObjects
            let glucoseObjects: [GlucoseStored] = try await CoreDataStack.shared
                .getNSManagedObject(with: glucoseIds, context: context)
            let determinationObjects: [OrefDetermination] = try await CoreDataStack.shared
                .getNSManagedObject(with: determinationIds, context: context)
            let overridePresetObjects: [OverrideStored] = try await CoreDataStack.shared
                .getNSManagedObject(with: overridePresetIds, context: context)
            let tempTargetPresetObjects: [TempTargetStored] = try await CoreDataStack.shared
                .getNSManagedObject(with: tempTargetPresetIds, context: context)

            let watchState: WatchState = await context.perform {
                var watchState = WatchState(date: Date())
                watchState.snoozeUntilDate = UserDefaults.standard
                    .object(forKey: "UserNotificationsManager.snoozeUntilDate") as? Date ?? .distantPast

                // Set lastLoopDate
                let lastLoopMinutes = Int((Date().timeIntervalSince(self.apsManager.lastLoopDate) - 30) / 60) + 1
                if lastLoopMinutes > 1440 {
                    watchState.lastLoopTime = "--"
                } else {
                    watchState.lastLoopTime = "\(lastLoopMinutes) min"
                }

                // Set IOB and COB from latest determination
                let iob = self.iobService.currentIOB ?? 0
                watchState.iob = Formatter.decimalFormatterWithTwoFractionDigits.string(from: iob as NSNumber)

                if let latestDetermination = determinationObjects.first {
                    let cob = NSNumber(value: latestDetermination.cob)
                    watchState.cob = Formatter.integerFormatter.string(from: cob)
                }

                // Set override presets with their enabled status
                watchState.overridePresets = overridePresetObjects.map { override in
                    OverridePresetWatch(
                        name: override.name ?? "",
                        isEnabled: override.enabled
                    )
                }

                guard let latestGlucose = glucoseObjects.first else {
                    return watchState
                }

                // Assign currentGlucose and its color
                /// Set current glucose with proper formatting
                watchState.currentGlucose = Decimal(latestGlucose.glucose).formatted(for: self.units)

                /// Calculate latest color
                let hardCodedLow = Decimal(55)
                let hardCodedHigh = Decimal(220)
                let isDynamicColorScheme = self.glucoseColorScheme == .dynamicColor

                let highGlucoseValue = isDynamicColorScheme ? hardCodedHigh : self.highGlucose
                let lowGlucoseValue = isDynamicColorScheme ? hardCodedLow : self.lowGlucose
                let highGlucoseColorValue = highGlucoseValue
                let lowGlucoseColorValue = lowGlucoseValue
                let targetGlucose = currentGlucoseTarget

                let currentGlucoseColor = Trio.getDynamicGlucoseColor(
                    glucoseValue: Decimal(latestGlucose.glucose),
                    highGlucoseColorValue: highGlucoseColorValue,
                    lowGlucoseColorValue: lowGlucoseColorValue,
                    targetGlucose: targetGlucose,
                    glucoseColorScheme: self.glucoseColorScheme
                )

                if Decimal(latestGlucose.glucose) <= self.lowGlucose || Decimal(latestGlucose.glucose) >= self.highGlucose {
                    watchState.currentGlucoseColorString = currentGlucoseColor.toHexString()
                } else {
                    watchState.currentGlucoseColorString = "#ffffff" // white when in range; colored when out of range
                }

                // Map glucose values
                watchState.glucoseValues = glucoseObjects.compactMap { glucose in
                    let glucoseValue = self.units == .mgdL
                        ? Double(glucose.glucose)
                        : Double(truncating: Decimal(glucose.glucose).asMmolL as NSNumber)

                    let glucoseColor = Trio.getDynamicGlucoseColor(
                        glucoseValue: Decimal(glucose.glucose),
                        highGlucoseColorValue: highGlucoseColorValue,
                        lowGlucoseColorValue: lowGlucoseColorValue,
                        targetGlucose: targetGlucose,
                        glucoseColorScheme: self.glucoseColorScheme
                    )

                    return WatchGlucoseObject(
                        date: glucose.date ?? Date(),
                        glucose: glucoseValue,
                        color: glucoseColor.toHexString()
                    )
                }
                .sorted { $0.date < $1.date }

                // Set axis domain: min and max Y-axis values
                // Apply unit parsing conditionally, if user uses mmol/L
                let maxGlucoseValue = Decimal(glucoseObjects.map { Int($0.glucose) }.max() ?? 200)
                var maxYValue = Decimal(200)

                if maxGlucoseValue > maxYValue, maxGlucoseValue <= 225 {
                    maxYValue = Decimal(250)
                } else if maxGlucoseValue > 225, maxGlucoseValue <= 275 {
                    maxYValue = Decimal(300)
                } else if maxGlucoseValue > 275, maxGlucoseValue <= 325 {
                    maxYValue = Decimal(350)
                } else if maxGlucoseValue > 325 {
                    maxYValue = Decimal(400)
                }

                if self.units == .mmolL {
                    maxYValue = Double(truncating: maxYValue as NSNumber).asMmolL
                }
                watchState.maxYAxisValue = maxYValue

                if self.units == .mmolL {
                    let minYValue = Double(truncating: watchState.minYAxisValue as NSNumber).asMmolL
                    watchState.minYAxisValue = minYValue
                }

                // Convert direction to trend string
                watchState.trend = latestGlucose.direction

                // Calculate delta if we have at least 2 readings
                if glucoseObjects.count >= 2 {
                    let glucoseLast = Decimal(glucoseObjects[0].glucose)
                    let glucoseSecondLast = Decimal(glucoseObjects[1].glucose)
                    watchState.delta = (glucoseLast - glucoseSecondLast).formattedDelta(for: self.units)
                }

                // Set temp target presets with their enabled status
                watchState.tempTargetPresets = tempTargetPresetObjects.map { tempTarget in
                    TempTargetPresetWatch(
                        name: tempTarget.name ?? "",
                        isEnabled: tempTarget.enabled
                    )
                }

                // Set units
                watchState.units = self.units

                // Add limits and pump specific dosing increment settings values
                watchState.maxBolus = self.settingsManager.pumpSettings.maxBolus
                watchState.maxCarbs = self.settingsManager.settings.maxCarbs
                watchState.maxFat = self.settingsManager.settings.maxFat
                watchState.maxProtein = self.settingsManager.settings.maxProtein
                watchState.bolusIncrement = self.settingsManager.preferences.bolusIncrement
                watchState.confirmBolusFaster = self.settingsManager.settings.confirmBolusFaster
                watchState.reducedBolusOption = self.settingsManager.settings.fattyMeals
                watchState.superBolusOption = self.settingsManager.settings.sweetMeals
                watchState.mealTimeReminderEnabled = self.settingsManager.settings.mealTimeReminderEnabled
                watchState.mealTimeReminderPresets = self.settingsManager.settings.mealTimeReminderPresets

                watchState.showForecast = self.settingsManager.settings.showForecastWatch
                watchState.isForecastCone = self.settingsManager.settings.forecastDisplayType == .cone

                // Forecast data comes from OrefDetermination's `forecasts` CoreData
                // relationship (Set<Forecast>), NOT a `.predictions` property.
                if let latestDetermination = determinationObjects.first,
                   let forecastsSet = latestDetermination.forecasts,
                   !forecastsSet.isEmpty
                {
                    let anchorDate = latestDetermination.deliverAt ?? latestDetermination.timestamp ?? Date()
                    watchState.forecastStartDate = anchorDate

                    // Rebuild a [type: [Int]] dictionary from the CoreData relationship.
                    // Strictly cap to 24 points (2 hours of 5-minute forecasts)
                    var rawPredictions: [String: [Int]] = [:]
                    for forecast in forecastsSet {
                        guard let type = forecast.type else { continue }
                        let values = Array(forecast.forecastValuesArray.map { Int($0.value) }.prefix(24))
                        guard !values.isEmpty else { continue }
                        rawPredictions[type] = values
                    }

                    func convert(_ values: [Int]?) -> [Double] {
                        guard let values = values else { return [] }
                        return values.map { raw in
                            self.units == .mgdL ? Double(raw) : Double(truncating: Decimal(raw).asMmolL as NSNumber)
                        }
                    }

                    if watchState.isForecastCone {
                        let allSeries: [[Int]] = [
                            rawPredictions["iob"],
                            rawPredictions["zt"],
                            rawPredictions["cob"],
                            rawPredictions["uam"]
                        ].compactMap { $0 }

                        // Change .max() to .min() so the shortest prediction line cuts off the cone
                        let count = allSeries.map(\.count).min() ?? 0

                        var coneMin: [Double] = []
                        var coneMax: [Double] = []
                        for i in 0 ..< count {
                            let valuesAtIndex = allSeries.compactMap { $0.indices.contains(i) ? $0[i] : nil }
                            guard let minRaw = valuesAtIndex.min(), let maxRaw = valuesAtIndex.max() else { continue }
                            coneMin.append(convert([minRaw])[0])
                            coneMax.append(convert([maxRaw])[0])
                        }
                        watchState.forecastConeMin = coneMin
                        watchState.forecastConeMax = coneMax
                        watchState.forecastLines = [:]
                    } else {
                        var lines: [String: [Double]] = [:]
                        if let iob = rawPredictions["iob"] { lines["iob"] = convert(iob) }
                        if let cob = rawPredictions["cob"] { lines["cob"] = convert(cob) }
                        if let uam = rawPredictions["uam"] { lines["uam"] = convert(uam) }
                        if let zt = rawPredictions["zt"] { lines["zt"] = convert(zt) }
                        watchState.forecastLines = lines
                        watchState.forecastConeMin = []
                        watchState.forecastConeMax = []
                    }
                } else {
                    watchState.forecastStartDate = nil
                    watchState.forecastConeMin = []
                    watchState.forecastConeMax = []
                    watchState.forecastLines = [:]
                }

                debug(
                    .watch,
                    "Watch state built: glucose \(watchState.currentGlucose ?? "none"), trend \(watchState.trend ?? "none"), delta \(watchState.delta ?? "none"), \(watchState.glucoseValues.count) readings"
                )

                return watchState
            }

            return watchState
        } catch {
            warning(.watch, "Building watch state failed", error: error)
            return nil
        }
    }

    /// Fetches recent glucose readings from CoreData
    /// - Returns: Array of NSManagedObjectIDs for glucose readings
    private func fetchGlucose() async throws -> [NSManagedObjectID] {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "fetchGlucose"
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.glucose,
            key: "date",
            ascending: false
        )

        return try await context.perform {
            guard let fetchedResults = results as? [GlucoseStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return fetchedResults.map(\.objectID)
        }
    }

    /// Carb entries (without fat and protein equivalents) and boluses of the last 24 hours, for the watch chart.
    private func chartTreatments() async -> (carbs: [TimeInterval], boluses: [[String: Any]], iobCob: [[String: Double]]) {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "watchChartTreatments"
        let since = Date.oneDayAgo
        return await context.perform {
            let carbRequest = NSFetchRequest<CarbEntryStored>(entityName: "CarbEntryStored")
            carbRequest.predicate = NSPredicate.carbsForChart(since: since)
            let carbs = ((try? context.fetch(carbRequest)) ?? []).compactMap { $0.date?.timeIntervalSince1970 }
            let bolusRequest = NSFetchRequest<PumpEventStored>(entityName: "PumpEventStored")
            bolusRequest.predicate = NSPredicate(format: "timestamp >= %@ AND bolus != nil", since as NSDate)
            let boluses: [[String: Any]] = ((try? context.fetch(bolusRequest)) ?? []).compactMap { event in
                guard let date = event.timestamp, let bolus = event.bolus else { return nil }
                return ["date": date.timeIntervalSince1970, "smb": bolus.isSMB]
            }
            // the loops' IOB and COB, as the phone's chart shows them under its scrub line
            let determinationRequest = NSFetchRequest<OrefDetermination>(entityName: "OrefDetermination")
            determinationRequest.predicate = NSPredicate.determinationsForCobIobCharts(since: since)
            let iobCob: [[String: Double]] = ((try? context.fetch(determinationRequest)) ?? []).compactMap { determination in
                guard let date = determination.deliverAt else { return nil }
                return [
                    "date": date.timeIntervalSince1970,
                    "iob": determination.iob?.doubleValue ?? 0,
                    "cob": Double(determination.cob)
                ]
            }
            return (carbs, boluses, iobCob)
        }
    }

    /// Fetches last pump event that is a non-external bolus from CoreData
    /// - Returns: NSManagedObjectIDs for last bolus
    func fetchLastBolus() async throws -> NSManagedObjectID? {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "fetchLastBolus"
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: context,
            predicate: NSPredicate.lastPumpBolus,
            key: "timestamp",
            ascending: false,
            fetchLimit: 1,
            relationshipKeyPathsForPrefetching: ["bolus"]
        )

        return try await context.perform {
            guard let fetchedResults = results as? [PumpEventStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return fetchedResults.map(\.objectID).first
        }
    }

    /// Gets the active bolus amount by fetching last (active) bolus.
    @MainActor func getActiveBolusAmount() async {
        do {
            if let lastBolusObjectId = try await fetchLastBolus() {
                let lastBolusObject: [PumpEventStored] = try await CoreDataStack.shared
                    .getNSManagedObject(with: [lastBolusObjectId], context: viewContext)

                activeBolusAmount = lastBolusObject.first?.bolus?.amount?.doubleValue ?? 0.0
            }
        } catch {
            warning(.watch, "Fetching active bolus amount failed", error: error)
        }
    }

    // MARK: - Send to Watch

    func watchStateToDictionary(from state: WatchState) -> [String: Any] {
        var dictionary: [String: Any] = [
            WatchMessageKeys.date: state.date.timeIntervalSince1970,
            WatchMessageKeys.currentGlucose: state.currentGlucose ?? "--",
            WatchMessageKeys.currentGlucoseColorString: state.currentGlucoseColorString ?? "#ffffff",
            WatchMessageKeys.trend: state.trend ?? "",
            WatchMessageKeys.delta: state.delta ?? "",
            WatchMessageKeys.iob: state.iob ?? "",
            WatchMessageKeys.cob: state.cob ?? "",
            WatchMessageKeys.lastLoopTime: state.lastLoopTime ?? "",
            WatchMessageKeys.glucoseValues: state.glucoseValues.map { value in
                [
                    "glucose": value.glucose,
                    "date": value.date.timeIntervalSince1970,
                    "color": value.color
                ]
            },
            WatchMessageKeys.minYAxisValue: state.minYAxisValue,
            WatchMessageKeys.maxYAxisValue: state.maxYAxisValue,
            WatchMessageKeys.overridePresets: state.overridePresets.map { preset in
                [
                    "name": preset.name,
                    "isEnabled": preset.isEnabled
                ]
            },
            WatchMessageKeys.tempTargetPresets: state.tempTargetPresets.map { preset in
                [
                    "name": preset.name,
                    "isEnabled": preset.isEnabled
                ]
            },
            WatchMessageKeys.maxBolus: state.maxBolus,
            WatchMessageKeys.maxCarbs: state.maxCarbs,
            WatchMessageKeys.maxFat: state.maxFat,
            WatchMessageKeys.maxProtein: state.maxProtein,
            WatchMessageKeys.bolusIncrement: state.bolusIncrement,
            WatchMessageKeys.confirmBolusFaster: state.confirmBolusFaster,
            WatchMessageKeys.reducedBolusOption: state.reducedBolusOption,
            WatchMessageKeys.superBolusOption: state.superBolusOption,
            WatchMessageKeys.mealTimeReminderEnabled: state.mealTimeReminderEnabled,
            WatchMessageKeys.mealTimeReminderPresets: state.mealTimeReminderPresets.map { NSDecimalNumber(decimal: $0).intValue },
            WatchMessageKeys.units: state.units.rawValue,
            WatchMessageKeys.showForecastWatch: state.showForecast,
            WatchMessageKeys.isForecastCone: state.isForecastCone,
            WatchMessageKeys.snoozeUntilDate: state.snoozeUntilDate.timeIntervalSince1970
        ]
        // the readings above include the watch's own the phone stored; this says when the phone itself last read one
        if let own = PhoneOwnGlucose.newest {
            dictionary[WatchMessageKeys.phoneOwnGlucoseDate] = own.timeIntervalSince1970
        }
        if let dose = PhoneLastDose.date {
            dictionary[WatchMessageKeys.phoneLastDoseDate] = dose.timeIntervalSince1970
        }
        dictionary[WatchMessageKeys.remoteControlSecret] = Self.remoteControlSecretForWatch(settingsManager.settings)

        var forecastData: [String: Any] = [
            WatchMessageKeys.forecastConeMin: state.forecastConeMin,
            WatchMessageKeys.forecastConeMax: state.forecastConeMax,
            WatchMessageKeys.forecastLines: state.forecastLines
        ]

        if let start = state.forecastStartDate?.timeIntervalSince1970 {
            forecastData[WatchMessageKeys.forecastStartDate] = start
        }

        dictionary[WatchMessageKeys.forecastData] = forecastData
        dictionary.merge(watchG7Details()) { _, new in new }
        dictionary[WatchMessageKeys.peripheralData] = peripheralDetails()
        return dictionary
    }

    /// The watch's Devices page: pump and sensor lifetime, as the phone's home header shows them (after
    /// EJM0/Trio's `gatherPeripherals`, Elias Maurer). A field the hardware can't report is left out, and the
    /// watch draws nothing for it: patch pumps have no battery, several CGMs report no expiry.
    private func peripheralDetails() -> [String: Any] {
        var details: [String: Any] = [:]
        let pumpName = apsManager.pumpName.value
        if !pumpName.isEmpty { details[WatchMessageKeys.pumpName] = pumpName }
        if let expiresAt = apsManager.pumpExpiresAtDate.value {
            details[WatchMessageKeys.pumpExpiresAt] = expiresAt.timeIntervalSince1970
        }
        if let activatedAt = apsManager.pumpActivatedAtDate.value {
            details[WatchMessageKeys.pumpActivatedAt] = activatedAt.timeIntervalSince1970
        }
        if let message = apsManager.pumpManager?.pumpStatusHighlight?.localizedMessage {
            details[WatchMessageKeys.pumpStatusMessage] = message
        }
        // as the home header; Omnipod's "50+ U" marker (0xDEAD_BEEF) passes through and the watch shows it so
        if let reservoir = apsManager.pumpManager?.currentReservoir {
            details[WatchMessageKeys.pumpReservoir] = reservoir
        }

        let cgmManager = fetchGlucoseManager?.cgmManager
        if let name = cgmManager?.localizedTitle { details[WatchMessageKeys.cgmName] = name }
        if let expiresAt = Home.StateModel.resolveSensorExpiresAt(
            manager: cgmManager,
            glucoseSource: fetchGlucoseManager?.glucoseSource
        ) {
            details[WatchMessageKeys.cgmSensorExpiresAt] = expiresAt.timeIntervalSince1970
        }
        if let progress = fetchGlucoseManager?.cgmProgressHighlight.value {
            details[WatchMessageKeys.cgmProgressPercent] = progress.percentComplete
            details[WatchMessageKeys.cgmProgressState] = progress.progressState.rawValue
        }
        if let message = fetchGlucoseManager?.cgmDisplayState.value?.localizedMessage {
            details[WatchMessageKeys.cgmStatusMessage] = message
        }
        return details
    }

    /// What the watch needs to read the G7 itself while the phone is away:
    /// the sensor, its pairing code, and the thresholds for its own alerts.
    /// The watch only uses them when the user turns the feature on there.
    private func watchG7Details() -> [String: Any] {
        var details: [String: Any] = [WatchMessageKeys.watchDisplayUnits: settingsManager.settings.units.rawValue]

        if let g7 = fetchGlucoseManager?.cgmManager as? G7CGMManager,
           g7.state.sessionMode == .direct,
           let sensorName = g7.state.sensorID
        {
            details[WatchMessageKeys.g7DirectSensorName] = sensorName
            details[WatchMessageKeys.g7DirectPairingCode] = g7.state.pairingCode ?? ""
        } else {
            details[WatchMessageKeys.g7DirectSensorName] = ""
        }

        // The most cautious of the enabled alarms: the highest low, the lowest high.
        let alerts = GlucoseAlertsStore.shared.alerts
        func thresholds(_ type: GlucoseAlertType) -> [Double] {
            alerts
                .filter { $0.type == type && $0.shouldEvaluate }
                .map { NSDecimalNumber(decimal: $0.thresholdMgDL).doubleValue }
        }
        details[WatchMessageKeys.watchAlertUrgentLowMgDL] = thresholds(.urgentLow).min() ?? 54.0
        details[WatchMessageKeys.watchAlertLowMgDL] = thresholds(.low).max() ?? 0.0
        details[WatchMessageKeys.watchAlertHighMgDL] = thresholds(.high).min() ?? 0.0

        return details
    }

    // MARK: - One update at a time

    /// The update on its way, whether something changed meanwhile, and when the last one went.
    @MainActor private var pushTask: Task<Void, Never>?
    @MainActor private var pushAgain = false
    @MainActor private var lastPushAt = Date.distantPast
    /// Each update is a full state, tens of kilobytes. A burst of changes (a loop, a pod read, the watch's history
    /// coming in) now sends one, the newest, instead of one each: on 24 October 73 went in 4 minutes while the
    /// watch was starting, and the watch's own messages timed out behind them.
    private static let pushGap: TimeInterval = 3

    /// Sends the current state soon: at once after a quiet moment, otherwise once the burst is over.
    func pushWatchState() {
        Task { @MainActor [weak self] in self?.schedulePush() }
    }

    @MainActor private func schedulePush() {
        guard pushTask == nil else {
            pushAgain = true
            return
        }
        pushTask = Task { @MainActor [weak self] in
            while let self {
                self.pushAgain = false
                let notBefore = max(
                    self.lastPushAt.addingTimeInterval(Self.pushGap),
                    UntetheredPhoneManager.historyBusyUntil
                )
                let wait = notBefore.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                // still taking in the watch's history: wait for it to settle
                if UntetheredPhoneManager.historyBusyUntil > Date() { continue }
                // a loop running now brings its results in a moment: they go with this update (dev #1598), but no
                // update waits longer than `maxLoopWait`
                let loopWaitStart = Date()
                while self.apsManager.isLooping.value, Date().timeIntervalSince(loopWaitStart) < Self.maxLoopWait {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                if let state = await self.setupWatchState() {
                    await self.sendDataToWatch(state)
                }
                self.lastPushAt = Date()
                guard self.pushAgain else {
                    self.pushTask = nil
                    return
                }
            }
        }
    }

    /// Sends the state of type WatchState to the connected Watch
    /// - Parameter state: Current WatchState containing glucose data to be sent
    @MainActor func sendDataToWatch(_ state: WatchState) async {
        guard let session = session else { return }
        // an untethered watch shows its own data
        guard UntetheredGate.state.session.isIdle else { return }
        guard let message = await buildWatchStatePayload(state) else { return }

        // if session is reachable, it means watch App is in the foreground -> send watchState as message
        // if session is not reachable, it means it's in background -> send watchState as userInfo
        if session.isReachable {
            session.sendMessage([WatchMessageKeys.watchState: message], replyHandler: nil) { error in
                warning(.watch, "Sending watch state failed", error: error)
            }
        } else if session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0,
                  Date().timeIntervalSince(lastComplicationTransfer) >= Self.complicationTransferInterval
        {
            // With Trio on the active watch face this wakes the watch app at once so the face shows the new
            // reading; watchOS allows about 50 a day, so at most one every 28 minutes, the rest as userInfo.
            session.transferCurrentComplicationUserInfo([WatchMessageKeys.watchState: message])
            lastComplicationTransfer = Date()
            debug(
                .watch,
                "📤 Transferred new WatchState snapshot for the complication (\(session.remainingComplicationUserInfoTransfers) left today)"
            )
        } else {
            // only the newest state matters: drop older ones still queued, so a returning watch gets one
            for transfer in session.outstandingUserInfoTransfers
                where !transfer.isCurrentComplicationInfo && transfer.userInfo[WatchMessageKeys.watchState] != nil
            {
                transfer.cancel()
            }
            session.transferUserInfo([WatchMessageKeys.watchState: message])
            debug(.watch, "Watch state queued for background transfer")
        }
    }

    /// The state as the watch takes it, stamped with the send time: for a push, and for the answer to the watch's
    /// request (dev #1598), which carries the same as a push. Nil when there is no watch to send it to.
    @MainActor private func buildWatchStatePayload(_ state: WatchState) async -> [String: Any]? {
        guard let session = session else { return nil }

        guard session.isPaired else {
            debug(.watch, "No watch paired")
            return nil
        }

        guard session.isWatchAppInstalled else {
            debug(.watch, "Trio watch app not installed")
            return nil
        }

        guard session.activationState == .activated else {
            debug(.watch, "Watch session not activated (state \(session.activationState.rawValue)), reactivating")
            session.activate()
            return nil
        }

        // While the watch is out of reach, `setupWatchState` returns an empty default
        // state (no glucose, mg/dL). Sending it would blank the watch's display and
        // switch its units, so only states with data go out.
        let isEmptyDefault = state.currentGlucose == nil && state.glucoseValues.isEmpty
            && state.iob == nil && state.cob == nil && state.lastLoopTime == nil
        guard !isEmptyDefault else {
            debug(.watch, "⌚️ Skipping empty WatchState")
            return nil
        }

        // Stamp the snapshot with send time. Each push gets a strictly newer
        // `date` than the previous one, which is what the watch's monotonicity
        // dedup relies on — including watch-requested re-pushes when no CGM
        // tick has bumped the build-time date.
        var state = state
        state.date = Date()

        var message: [String: Any] = watchStateToDictionary(from: state)
        // the target range the watch-face graph shades, as the Live Activity does
        message[Self.complicationRangeLowKey] = NSDecimalNumber(decimal: lowGlucose).doubleValue
        message[Self.complicationRangeHighKey] = NSDecimalNumber(decimal: highGlucose).doubleValue
        // and colors the watch's own readings by the same scheme as the phone's
        message[Self.complicationColorSchemeKey] = glucoseColorScheme.rawValue
        let currentGlucoseTarget = await getCurrentGlucoseTarget() ?? Decimal(100)
        message[Self.complicationTargetKey] = NSDecimalNumber(decimal: currentGlucoseTarget).doubleValue
        message[WatchMessageKeys.allowUntetheredStartWithoutPhoneWatch] = settingsManager.settings
            .allowUntetheredStartWithoutPhoneWatch
        message[WatchMessageKeys.untetheredModeWatch] = settingsManager.settings.untetheredModeWatch
        message[WatchMessageKeys.fallbackLoopWatch] = settingsManager.settings.fallbackLoopWatch
        message[WatchMessageKeys.nightscoutWatch] = nightscoutForWatch()?.dictionary ?? [String: Any]()
        message[WatchMessageKeys.untetheredWorkoutWatch] = settingsManager.settings.untetheredWorkoutWatch
        message[WatchMessageKeys.watchGlanceLayout] = settingsManager.settings.watchGlanceLayout.strings
        message[WatchMessageKeys.watchGlanceEnabled] = settingsManager.settings.watchGlanceEnabled
        message[WatchMessageKeys.useCriticalAlertsWatch] = settingsManager.settings.useCriticalAlerts
        // the countdown on the watch's first page; 0 clears it there
        message[WatchMessageKeys.mealTimeReminderAt] = mealTimeReminderService.pendingReminder?.fireDate.timeIntervalSince1970 ?? 0
        message[WatchMessageKeys.phoneAppVersion] = UntetheredVersion.current
        // carbs and boluses as markers on the watch chart: times only, the values would crowd a watch screen
        let treatments = await chartTreatments()
        message[WatchMessageKeys.chartCarbs] = treatments.carbs
        message[WatchMessageKeys.chartBoluses] = treatments.boluses
        message[WatchMessageKeys.chartIobCob] = treatments.iobCob

        return message
        }
    }

    func sendAcknowledgment(toWatch success: Bool, message: String = "", ackCode: AcknowledgmentCode) {
        guard let session = session, session.isReachable else {
            debug(.watch, "Watch not reachable, acknowledgment not sent")
            return
        }

        let ackMessage: [String: Any] = [
            WatchMessageKeys.acknowledged: success,
            WatchMessageKeys.message: message,
            WatchMessageKeys.ackCode: ackCode.rawValue
        ]

        session.sendMessage(ackMessage, replyHandler: nil) { error in
            warning(.watch, "Sending acknowledgment to watch failed", error: error)
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            warning(.watch, "Watch session activation failed", error: error)
            return
        }

        info(.watch, "Watch session activated, state \(activationState.rawValue), reachable: \(session.isReachable)")
        // a relaunch with the watch already in reach brings no reachability change: ask for the history here too
        Task { @MainActor [untethered] in untethered?.reachabilityChanged() }

        // Try to send initial data after activation
        self.pushWatchState()
    }

    /// Untethered mode's interactive messages from the watch; every path must call `replyHandler`,
    /// or the watch only finds out through a delivery timeout.
    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        if message[UntetheredEnvelope.key] != nil {
            untethered.receive(message, replyHandler: replyHandler)
            return
        }
        // the watch asks for the state and takes the answer at once (dev #1598): the same as a push, or nothing while
        // the watch runs untethered and shows its own data
        if message[WatchMessageKeys.requestWatchUpdate] as? String == WatchMessageKeys.watchState {
            debug(.watch, "Watch requested a state update")
            Task { @MainActor [weak self] in
                guard let self, UntetheredGate.state.session.isIdle,
                      let state = await self.setupWatchState(),
                      let payload = await self.buildWatchStatePayload(state)
                else {
                    replyHandler([:])
                    return
                }
                replyHandler([WatchMessageKeys.watchState: payload])
            }
            return
        }
        if message[UntetheredChunks.key] != nil {
            untethered.receiveChunk(message, replyHandler: replyHandler)
            return
        }
        // a part of the plain watch log: the answer is the watch's confirmation, after which it deletes the part
        if message["watchLogs"] != nil {
            let id = WatchLogIngest.acceptLegacy(message)
            replyHandler(id.map { ["watchLogsAck": [$0]] } ?? [:])
            if message.count <= 2 { return }
            var rest = message
            rest["watchLogs"] = nil
            rest["watchLogsID"] = nil
            self.session(session, didReceiveMessage: rest)
            return
        }
        replyHandler([:])
        self.session(session, didReceiveMessage: message)
    }

    func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        if message[UntetheredEnvelope.key] != nil {
            untethered.receive(message, replyHandler: nil)
            return
        }
        // Handle logs first - doesn't need self, so it can run even during teardown
        if message["watchLogs"] != nil {
            Self.confirmWatchLogs(WatchLogIngest.acceptLegacy(message))
            // logs alone are no request: answering them with a failure put an error banner on the watch
            if message.count == 1 || (message.count == 2 && message["watchLogsID"] != nil) { return }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            if let requestWatchUpdate = message[WatchMessageKeys.requestWatchUpdate] as? String,
               requestWatchUpdate == WatchMessageKeys.watchState
            {
                debug(.watch, "Watch requested a state update")
                // Skip if no watch is paired or app not installed
                guard let session = self.session, self.watchNeedsState(session) else { return }
                self.pushWatchState()
                return
            }

            if let fireAt = message[WatchMessageKeys.cancelMealTimeReminder] as? TimeInterval {
                self.cancelMealTimeReminderFromWatch(fireAt)
                return
            }

            if let snoozeMinutes = message[WatchMessageKeys.snoozeDuration] as? Int {
                info(.watch, "Watch requested alert snooze for \(snoozeMinutes) min")
                await self.notificationsManager.applySnooze(for: TimeInterval(snoozeMinutes * 60))
                return
            } else if let bolusAmount = message[WatchMessageKeys.bolus] as? Double,
                      message[WatchMessageKeys.carbs] == nil,
                      message[WatchMessageKeys.date] == nil
            {
                info(.watch, "Watch requested bolus of \(bolusAmount) U")
                self.handleBolusRequest(Decimal(bolusAmount), reminder: Self.mealTimeReminder(in: message))
            } else if let carbsAmount = message[WatchMessageKeys.carbs] as? Int,
                      let timestamp = message[WatchMessageKeys.date] as? TimeInterval,
                      message[WatchMessageKeys.bolus] == nil
            {
                let date = Date(timeIntervalSince1970: timestamp)
                info(.watch, "Watch requested \(carbsAmount) g carbs at \(date)")
                self.handleCarbsRequest(carbsAmount, date)
                // carbs without insulin and a reminder: a timer from now, as the calculator's
                if let reminder = Self.mealTimeReminder(in: message) {
                    Task {
                        await self.mealTimeReminderService.scheduleEatReminder(
                            after: reminder.leadTime,
                            carbs: reminder.carbs,
                            bolusAmount: 0
                        )
                    }
                }
            } else if let bolusAmount = message[WatchMessageKeys.bolus] as? Double,
                      let carbsAmount = message[WatchMessageKeys.carbs] as? Int,
                      let timestamp = message[WatchMessageKeys.date] as? TimeInterval
            {
                let date = Date(timeIntervalSince1970: timestamp)
                info(.watch, "Watch requested bolus of \(bolusAmount) U with \(carbsAmount) g carbs at \(date)")
                self.handleCombinedRequest(bolusAmount: Decimal(bolusAmount), carbsAmount: Decimal(carbsAmount), date: date)
            } else if message[WatchMessageKeys.cancelOverride] == nil,
                      message[WatchMessageKeys.activateOverride] == nil,
                      message[WatchMessageKeys.cancelTempTarget] == nil,
                      message[WatchMessageKeys.activateTempTarget] == nil,
                      message[WatchMessageKeys.requestBolusRecommendation] == nil
            {
                warning(
                    .watch,
                    "Invalid or incomplete message from watch, keys: \(message.keys.sorted().joined(separator: ", "))"
                )
                // Acknowledge failure
                self.sendAcknowledgment(
                    toWatch: false,
                    message: "Error! Invalid or incomplete data received from watch.",
                    ackCode: .genericFailure
                )
            }

            if message[WatchMessageKeys.cancelOverride] as? Bool == true {
                info(.watch, "Watch requested override cancel")
                self.handleCancelOverride()
            }

            if let presetName = message[WatchMessageKeys.activateOverride] as? String {
                info(.watch, "Watch requested override preset \(presetName)")
                self.handleActivateOverride(presetName)
            }

            if let presetName = message[WatchMessageKeys.activateTempTarget] as? String {
                info(.watch, "Watch requested temp target preset \(presetName)")
                self.handleActivateTempTarget(presetName)
            }

            if message[WatchMessageKeys.cancelTempTarget] as? Bool == true {
                info(.watch, "Watch requested temp target cancel")
                self.handleCancelTempTarget()
            }

            if message[WatchMessageKeys.requestBolusRecommendation] as? Bool == true {
                let carbs = message[WatchMessageKeys.carbs] as? Int ?? 0
                // the watch's reduced or super bolus, only with the option on here; reduced wins, as on the phone
                let useReducedBolus = message[WatchMessageKeys.useReducedBolus] as? Bool == true &&
                    self.settingsManager.settings.fattyMeals
                let useSuperBolus = !useReducedBolus && message[WatchMessageKeys.useSuperBolus] as? Bool == true &&
                    self.settingsManager.settings.sweetMeals

                var minPredBG: Decimal = 54

                Task { [weak self] in
                    guard let self = self else { return }

                    do {
                        let context = CoreDataStack.shared.newTaskContext()
                        context.name = "requestBolusRecommendation"
                        // Fetch determination data
                        let determinationIds = try await determinationStorage.fetchLastDeterminationObjectID(
                            predicate: NSPredicate.predicateFor30MinAgoForDetermination
                        )
                        let determinationObjects: [OrefDetermination] = try await CoreDataStack.shared.getNSManagedObject(
                            with: determinationIds,
                            context: context
                        )

                        await MainActor.run {
                            minPredBG = determinationObjects.first?.minPredBGFromReason ?? 54
                        }

                    } catch let error as CoreDataError {
                        warning(.watch, "Fetching determination for watch bolus recommendation failed", error: error)
                    } catch {
                        warning(.watch, "Fetching determination for watch bolus recommendation failed", error: error)
                    }

                    // Get recommendation from BolusCalculationManager
                    let result = await bolusCalculationManager.handleBolusCalculation(
                        carbs: Decimal(carbs),
                        useFattyMealCorrection: useReducedBolus,
                        useSuperBolus: useSuperBolus,
                        lastLoopDate: apsManager.lastLoopDate,
                        minPredBG: minPredBG,
                        simulatedCOB: nil,
                        isBackdated: false // we cannot backdate carbs via watch
                    )

                    // Send recommendation back to watch
                    let recommendationMessage: [String: Any] = [
                        WatchMessageKeys.recommendedBolus: NSDecimalNumber(decimal: result.insulinCalculated)
                    ]

                    if let session = self.session, session.isReachable {
                        debug(.watch, "Sending recommended bolus \(result.insulinCalculated) U to watch")
                        session.sendMessage(recommendationMessage, replyHandler: nil)
                    }
                }
                return
            }
        }
    }

    func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if userInfo[UntetheredEnvelope.key] != nil {
            untethered.receive(userInfo, replyHandler: nil)
            return
        }
        if let token = userInfo[WatchMessageKeys.watchPushToken] as? String {
            Self.storeWatchPushToken(token)
            return
        }
        if userInfo["watchLogs"] != nil {
            Self.confirmWatchLogs(WatchLogIngest.acceptLegacy(userInfo))
        }

        if let fireAt = userInfo[WatchMessageKeys.cancelMealTimeReminder] as? TimeInterval {
            Task { @MainActor [weak self] in self?.cancelMealTimeReminderFromWatch(fireAt) }
            return
        }

        if let snoozeMinutes = userInfo[WatchMessageKeys.snoozeDuration] as? Int {
            info(.watch, "Watch requested alert snooze for \(snoozeMinutes) min")
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.notificationsManager.applySnooze(for: TimeInterval(snoozeMinutes * 60))
            }
        }
    }

    /// The countdown on the watch was tapped. Only the reminder the watch showed goes: the message may come late
    /// (queued while the phone was off), and a newer reminder set meanwhile stays.
    @MainActor private func cancelMealTimeReminderFromWatch(_ fireAt: TimeInterval) {
        guard let pending = mealTimeReminderService.pendingReminder,
              abs(pending.fireDate.timeIntervalSince1970 - fireAt) < 2
        else {
            info(.watch, "Watch cancelled a meal-time reminder that is no longer pending")
            return
        }
        info(.watch, "Watch cancelled the meal-time reminder")
        mealTimeReminderService.cancelPendingReminders()
    }

    /// Uploaded with the phone's own token (`NightscoutManager.uploadProfiles`), so LoopFollow can send a remote
    /// command straight to the watch too while it has the pump.
    static let watchPushTokenKey = "watchDeviceToken"

    private static func storeWatchPushToken(_ token: String) {
        guard !token.isEmpty, UserDefaults.standard.string(forKey: watchPushTokenKey) != token else { return }
        UserDefaults.standard.set(token, forKey: watchPushTokenKey)
        info(.watch, "Watch push token received; uploading it with the profile")
        Task { try? await TrioApp.resolver.resolve(NightscoutManager.self)?.uploadProfiles() }
    }

    /// Only with remote control and untethered mode on: the watch needs it only to open commands while it has the pump.
    private static func remoteControlSecretForWatch(_ settings: TrioSettings) -> String {
        guard settings.untetheredModeWatch, UserDefaults.standard.bool(forKey: "isTrioRemoteControlEnabled") else { return "" }
        return UserDefaults.standard.string(forKey: "trioRemoteControlSharedSecret") ?? ""
    }

    /// The watch keeps a part of its plain log until the phone confirms it; queued, so the confirmation also reaches a
    /// watch that is out of reach right now.
    private static func confirmWatchLogs(_ id: String?) {
        guard let id else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        _ = session.transferUserInfo(["watchLogsAck": [id]])
    }

    func session(_: WCSession, didReceive file: WCSessionFile) {
        WatchLogIngest.shared.receive(file.fileURL, metadata: file.metadata)
    }

    #if os(iOS)
        func sessionDidBecomeInactive(_: WCSession) {}
        func sessionDidDeactivate(_ session: WCSession) {
            session.activate()
        }
    #endif

    func sessionReachabilityDidChange(_ session: WCSession) {
        debug(.watch, "Watch reachable: \(session.isReachable)")
        Task { @MainActor [untethered] in untethered?.reachabilityChanged() }

        if session.isReachable {
            // Try to send data when connection is established
            self.pushWatchState()
        } else {
            // Try to reconnect after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.retryConnection()
            }
        }
    }

    /// A meal-time reminder the watch set with its bolus or carbs, with the reminder on here.
    private static func mealTimeReminder(in message: [String: Any]) -> (leadTime: TimeInterval, carbs: Decimal)? {
        guard let minutes = message[WatchMessageKeys.mealTimeReminderMinutes] as? Int, minutes > 0,
              TrioApp.resolver.resolve(SettingsManager.self)?.settings.mealTimeReminderEnabled == true
        else { return nil }
        return (TimeInterval(minutes * 60), Decimal(message[WatchMessageKeys.mealTimeReminderCarbs] as? Int ?? 0))
    }

    /// Processes bolus requests received from the Watch
    /// - Parameter amount: The requested bolus amount in units
    private func handleBolusRequest(_ amount: Decimal, reminder: (leadTime: TimeInterval, carbs: Decimal)? = nil) {
        Task {
            // The watch has just handed the pump back and the phone is still reading it: the bolus waits for that, up
            // to 30 s (6 November, third tester: a 3 U meal bolus sent from the watch a few seconds after its session
            // ended came while the phone read the pump back, was refused with "The watch is in charge of the pump",
            // and was given only 17 minutes later). The watch keeps showing that it is sending until the answer.
            var waited = 0
            while untethered.state.pumpReturnPending, untethered.state.session.isIdle, waited < 30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                waited += 1
            }
            if waited > 0 {
                info(.bolus, "Watch bolus of \(amount) U waited \(waited) s for the pump to come back from the watch")
            }
            await apsManager.enactBolus(amount: Double(amount), isSMB: false) { success, message in
                // as the calculator: once the bolus command was accepted, the reminder counts from now
                if success, let reminder {
                    Task {
                        await self.mealTimeReminderService.scheduleEatReminder(
                            after: reminder.leadTime,
                            carbs: reminder.carbs,
                            bolusAmount: amount
                        )
                    }
                }
                // Acknowledge success or error of bolus
                self.sendAcknowledgment(
                    toWatch: success,
                    message: message,
                    ackCode: success == true ? .genericSuccess : .genericFailure
                )
            }
            debug(.bolus, "Watch bolus of \(amount) U handed to APS manager")
        }
    }

    /// Handles carbs entry requests received from the Watch
    /// - Parameters:
    ///   - amount: The carbs amount in grams
    ///   - date: Timestamp for the carbs entry
    private func handleCarbsRequest(_ amount: Int, _ date: Date) {
        Task {
            let context = CoreDataStack.shared.newTaskContext()

            await context.perform {
                let carbEntry = CarbEntryStored(context: context)
                carbEntry.id = UUID()
                carbEntry.carbs = Double(truncating: amount as NSNumber)
                carbEntry.date = date
                carbEntry.note = String(localized: "Via Watch", comment: "Note added to carb entry when entered via watch")
                carbEntry.isFPU = false // set this to false to ensure watch-entered carbs are displayed in main chart
                carbEntry.isUploadedToNS = false
                carbEntry.isUploadedToHealth = false
                carbEntry.isUploadedToTidepool = false

                do {
                    guard context.hasChanges else {
                        // Acknowledge failure
                        self.sendAcknowledgment(
                            toWatch: false,
                            message: "Error! Something went wrong when processing your request.",
                            ackCode: .genericFailure
                        )
                        return
                    }
                    try context.save()
                    debug(.treatments, "Saved \(amount) g carbs from watch")

                    // Acknowledge success
                    self.sendAcknowledgment(
                        toWatch: true,
                        message: String(
                            localized: "Carbs logged successfully.",
                            comment: "Success message sent to watch when carbs are logged successfully"
                        ),
                        ackCode: .carbsLogged
                    )
                } catch let saveError {
                    error(.treatments, "Saving carbs from watch failed", error: saveError)

                    // Acknowledge failure
                    self.sendAcknowledgment(toWatch: false, message: "Error logging carbs", ackCode: .genericFailure)
                }
            }
        }
    }

    /// Handles combined bolus and carbs entry requests received from the Watch.
    /// - Parameters:
    ///   - bolusAmount: The bolus amount in units
    ///   - carbsAmount: The carbs amount in grams
    ///   - date: Timestamp for the carbs entry
    private func handleCombinedRequest(bolusAmount: Decimal, carbsAmount: Decimal, date: Date) {
        Task {
            let context = CoreDataStack.shared.newTaskContext()

            do {
                // Notify Watch: "Saving carbs..."
                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Saving Carbs...",
                        comment: "Successful message sent to watch when saving carbs"
                    ),
                    ackCode: .savingCarbs
                )

                // Save carbs entry in Core Data
                try await context.perform {
                    let carbEntry = CarbEntryStored(context: context)
                    carbEntry.id = UUID()
                    carbEntry.carbs = NSDecimalNumber(decimal: carbsAmount).doubleValue
                    carbEntry.date = date
                    carbEntry.note = String(localized: "Via Watch", comment: "Note added to carb entry when entered via watch")
                    carbEntry.isFPU = false // set this to false to ensure watch-entered carbs are displayed in main chart
                    carbEntry.isUploadedToNS = false
                    carbEntry.isUploadedToHealth = false
                    carbEntry.isUploadedToTidepool = false

                    guard context.hasChanges else {
                        // Acknowledge failure
                        self.sendAcknowledgment(
                            toWatch: false,
                            message: "Error! Something went wrong when processing your request.",
                            ackCode: .genericFailure
                        )
                        return
                    }
                    try context.save()
                    debug(.treatments, "Saved \(carbsAmount) g carbs from watch")
                }

                // Notify Watch: "Enacting bolus..."
                sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Enacting bolus...",
                        comment: "Successful message sent to watch when enacting bolus"
                    ),
                    ackCode: .enactingBolus
                )

                // Enact bolus via APS Manager
                let bolusDouble = NSDecimalNumber(decimal: bolusAmount).doubleValue
                await apsManager.enactBolus(amount: bolusDouble, isSMB: false) { success, message in
                    // Acknowledge success or error of bolus
                    self.sendAcknowledgment(
                        toWatch: success,
                        message: message,
                        ackCode: success == true ? .genericSuccess : .genericFailure
                    )
                }
                debug(.bolus, "Watch bolus of \(bolusDouble) U handed to APS manager")
                // Notify Watch: "Carbs and bolus logged successfully"
                sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Carbs and Bolus logged successfully.",
                        comment: "Successful message sent to watch when logging carbs and bolus"
                    ),
                    ackCode: .comboComplete
                )

            } catch let requestError {
                error(.watch, "Logging carbs and bolus from watch failed", error: requestError)
                sendAcknowledgment(toWatch: false, message: "Failed to log carbs and bolus", ackCode: .genericFailure)
            }
        }
    }

    private func handleCancelOverride() {
        Task {
            do {
                let outcome = try await adjustmentManager.cancelOverride(source: .watch)
                debug(.treatments, "Override \"\(outcome.ended.first?.name ?? "Custom Override")\" stopped from watch")

                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Stopped Override successfully.",
                        comment: "Stopped Override successfully"
                    ),
                    ackCode: .overrideStopped
                )
            } catch {
                warning(.treatments, "Stopping override from watch failed", error: error)
                self.sendAcknowledgment(
                    toWatch: false,
                    message: (error as? AdjustmentError)?.errorDescription ?? "Error stopping Override.",
                    ackCode: .genericFailure
                )
            }
        }
    }

    private func handleActivateOverride(_ presetName: String) {
        Task {
            do {
                let outcome = try await adjustmentManager.activateOverride(.presetName(presetName), source: .watch)
                debug(.treatments, "Override \(presetName) started from watch")
                if let ended = outcome.ended.first {
                    debug(.treatments, "Recorded run for replaced override \"\(ended.name ?? "Custom Override")\"")
                }

                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Started Override \"\(presetName)\" successfully.",
                        comment: "Start override with override name"
                    ),
                    ackCode: .overrideStarted
                )
            } catch {
                warning(.treatments, "Starting override from watch failed", error: error)
                self.sendAcknowledgment(
                    toWatch: false,
                    message: (error as? AdjustmentError)?.errorDescription ?? "Error activating Override \"\(presetName)\".",
                    ackCode: .genericFailure
                )
            }
        }
    }

    private func handleActivateTempTarget(_ presetName: String) {
        Task {
            do {
                let outcome = try await adjustmentManager.activateTempTarget(.presetName(presetName), source: .watch)
                debug(.treatments, "Temp target \(presetName) started from watch")
                if let ended = outcome.ended.first {
                    debug(.treatments, "Recorded run for replaced temp target \"\(ended.name ?? "Temp Target")\"")
                }

                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Started Temp Target \"\(presetName)\" successfully.",
                        comment: "Started Temp Target successfully."
                    ),
                    ackCode: .tempTargetStarted
                )
            } catch {
                warning(.treatments, "Starting temp target from watch failed", error: error)
                self.sendAcknowledgment(
                    toWatch: false,
                    message: (error as? AdjustmentError)?.errorDescription ?? "Error activating Temp Target \"\(presetName)\".",
                    ackCode: .genericFailure
                )
            }
        }
    }

    private func handleCancelTempTarget() {
        Task {
            do {
                let outcome = try await adjustmentManager.cancelTempTarget(source: .watch)
                debug(.treatments, "Temp target \"\(outcome.ended.first?.name ?? "Temp Target")\" stopped from watch")

                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Stopped Temp Target successfully.",
                        comment: "Stopped Temp Target successfully."
                    ),
                    ackCode: .tempTargetStopped
                )
            } catch {
                warning(.treatments, "Stopping temp target from watch failed", error: error)
                self.sendAcknowledgment(
                    toWatch: false,
                    message: (error as? AdjustmentError)?.errorDescription ?? "Error stopping Temp Target.",
                    ackCode: .genericFailure
                )
            }
        }
    }
}

// TODO: - is there a better approach than setting up the watch state every time a setting has changed?
extension BaseWatchManager: SettingsObserver, PumpSettingsObserver {
    // to update maxBolus
    func pumpSettingsDidChange(_: PumpSettings) {
        // Skip if no watch is paired or app not installed
        guard let session = self.session, self.watchNeedsState(session) else { return }
        self.pushWatchState()
    }

    // to update the rest
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
        glucoseColorScheme = settingsManager.settings.glucoseColorScheme
        lowGlucose = settingsManager.settings.low
        highGlucose = settingsManager.settings.high

        // Skip if no watch is paired or app not installed
        guard let session = self.session, self.watchNeedsState(session) else { return }

        self.pushWatchState()
    }
}

extension BaseWatchManager: SnoozeObserver {
    @MainActor func snoozeDidChange(_: Date) {
        guard let session = self.session, session.isPaired, session.isReachable, session.isWatchAppInstalled else { return }
        self.pushWatchState()
    }
}

extension BaseWatchManager {
    /// Retrieves the current glucose target based on the time of day.
    private func getCurrentGlucoseTarget() async -> Decimal? {
        let now = Date()
        let calendar = Calendar.current

        let bgTargets = await fileStorage.retrieveAsync(OpenAPS.Settings.bgTargets, as: BGTargets.self)
            ?? BGTargets(from: OpenAPS.defaults(for: OpenAPS.Settings.bgTargets))
            ?? BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: [])
        let entries: [(start: String, value: Decimal)] = bgTargets.targets.map { ($0.start, $0.low) }

        for (index, entry) in entries.enumerated() {
            guard let entryTime = TherapySettingsUtil.parseTime(entry.start) else {
                warning(.watch, "Skipped glucose target with invalid start time \(entry.start)")
                continue
            }

            let entryComponents = calendar.dateComponents([.hour, .minute, .second], from: entryTime)
            let entryStartTime = calendar.date(
                bySettingHour: entryComponents.hour!,
                minute: entryComponents.minute!,
                second: entryComponents.second!,
                of: now
            )!

            let entryEndTime: Date
            if index < entries.count - 1,
               let nextEntryTime = TherapySettingsUtil.parseTime(entries[index + 1].start)
            {
                let nextEntryComponents = calendar.dateComponents([.hour, .minute, .second], from: nextEntryTime)
                entryEndTime = calendar.date(
                    bySettingHour: nextEntryComponents.hour!,
                    minute: nextEntryComponents.minute!,
                    second: nextEntryComponents.second!,
                    of: now
                )!
            } else {
                entryEndTime = calendar.date(byAdding: .day, value: 1, to: entryStartTime)!
            }

            if now >= entryStartTime, now < entryEndTime {
                return entry.value
            }
        }

        return nil
    }
}

extension BaseWatchManager {
    enum AcknowledgmentCode: String, Codable {
        case savingCarbs = "saving_carbs"
        case enactingBolus = "enacting_bolus"
        case comboComplete = "combo_complete"
        case carbsLogged = "carbs_logged"
        case overrideStarted = "override_started"
        case overrideStopped = "override_stopped"
        case tempTargetStarted = "temp_target_started"
        case tempTargetStopped = "temp_target_stopped"
        case genericSuccess = "success"
        case genericFailure = "failure"
    }
}
