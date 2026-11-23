enum WatchMessageKeys {
    // Request/Response Keys
    static let date = "date"
    static let units = "units"
    /// Carb entries of the last 24 hours, as times (seconds since 1970), for the watch chart's markers.
    static let chartCarbs = "chartCarbs"
    /// Boluses of the last 24 hours: `["date": seconds since 1970, "smb": Bool]`, for the watch chart's markers.
    static let chartBoluses = "chartBoluses"
    /// IOB and COB at each loop of the last 24 hours: `["date": seconds since 1970, "iob": U, "cob": g]`, for the
    /// watch chart's scrub line, as the phone's chart shows them.
    static let chartIobCob = "chartIobCob"
    static let requestWatchUpdate = "requestWatchUpdate"
    static let watchState = "watchState"
    static let acknowledged = "acknowledged"
    static let ackCode = "ackCode"
    static let message = "message"

    // Treatment Keys
    static let bolus = "bolus"
    static let carbs = "carbs"
    static let cancelBolus = "cancelBolus"
    static let bolusCanceled = "bolusCanceled"
    static let bolusProgress = "bolusProgress"
    static let activeBolusAmount = "activeBolusAmount"
    static let deliveredAmount = "deliveredAmount"
    static let bolusProgressTimestamp = "bolusProgressTimestamp"

    // Recommendation Keys
    static let requestBolusRecommendation = "requestBolusRecommendation"
    static let recommendedBolus = "recommendedBolus"

    // Override Keys
    static let cancelOverride = "cancelOverride"
    static let activateOverride = "activateOverride"

    // Temp Target Keys
    static let cancelTempTarget = "cancelTempTarget"
    static let activateTempTarget = "activateTempTarget"

    // Watch State Data Keys
    static let currentGlucose = "currentGlucose"
    static let currentGlucoseColorString = "currentGlucoseColorString"
    static let trend = "trend"
    static let delta = "delta"
    static let iob = "iob"
    static let cob = "cob"
    static let lastLoopTime = "lastLoopTime"
    static let glucoseValues = "glucoseValues"
    static let minYAxisValue = "minYAxisValue"
    static let maxYAxisValue = "maxYAxisValue"
    static let overridePresets = "overridePresets"
    static let tempTargetPresets = "tempTargetPresets"

    // Limits and Settings Keys
    static let maxBolus = "maxBolus"
    static let maxCarbs = "maxCarbs"
    static let maxFat = "maxFat"
    static let maxProtein = "maxProtein"
    static let bolusIncrement = "bolusIncrement"
    static let confirmBolusFaster = "confirmBolusFaster"
    /// Settings › Bolus Calculator › Enable Reduced Bolus Option / Enable Super Bolus Option, for the watch's calculator.
    static let reducedBolusOption = "reducedBolusOption"
    static let superBolusOption = "superBolusOption"
    /// A bolus recommendation asked for with a reduced or a super bolus.
    static let useReducedBolus = "useReducedBolus"
    static let useSuperBolus = "useSuperBolus"
    /// Settings › Bolus Calculator › Meal-Time Reminder: on, and its presets in minutes.
    static let mealTimeReminderEnabled = "mealTimeReminderEnabled"
    static let mealTimeReminderPresets = "mealTimeReminderPresets"
    /// With a bolus or carbs from the watch: remind to eat this many minutes after the bolus has been delivered.
    static let mealTimeReminderMinutes = "mealTimeReminderMinutes"
    /// The phone's pending meal-time reminder, for the countdown on the watch's first page: when it rings, 0 none.
    static let mealTimeReminderAt = "mealTimeReminderAt"
    /// From the watch: cancel the pending meal-time reminder (its countdown was tapped); the value is when the
    /// reminder the watch showed rings, so a late cancel leaves a newer one alone.
    static let cancelMealTimeReminder = "cancelMealTimeReminder"
    static let mealTimeReminderCarbs = "mealTimeReminderCarbs"

    // Notification Actions
    static let snoozeDuration = "snoozeDuration"
    static let snoozeUntilDate = "snoozeUntilDate"
    /// The newest reading the phone's own CGM delivered; the glucose values may also hold the watch's own.
    static let phoneOwnGlucoseDate = "phoneOwnGlucoseDate"
    /// When the phone last enacted a temp basal or bolus: with its own readings, what tells the watch the phone loops.
    static let phoneLastDoseDate = "phoneLastDoseDate"
    /// While the watch has the pump: the phone's own newest reading (date, mg/dL, direction), for a session whose
    /// own sensor link failed.
    static let untetheredPhoneReading = "untetheredPhoneReading"
    /// The watch app's push token, from the watch: the phone uploads it with its own so a remote command can also go
    /// straight to the watch while it has the pump.
    static let watchPushToken = "watchPushToken"
    /// Remote control's shared secret, for the watch to open those commands; empty when remote control or untethered
    /// mode is off, and the watch forgets it.
    static let remoteControlSecret = "remoteControlSecret"

    // Devices page: pump and CGM lifetime (from EJM0/Trio's PeripheralsView, Elias Maurer)
    /// Sub-dictionary wrapping every device field, mirroring `forecastData`.
    static let peripheralData = "peripheralData"
    static let pumpName = "pumpName"
    static let pumpReservoir = "pumpReservoir"
    static let pumpBatteryPercent = "pumpBatteryPercent"
    /// What a start without the iPhone needs, as the watch sees it (`readinessReport`), sent when it changes.
    static let watchReadiness = "watchReadiness"
    static let pumpExpiresAt = "pumpExpiresAt"
    static let pumpActivatedAt = "pumpActivatedAt"
    static let pumpStatusMessage = "pumpStatusMessage"
    static let cgmName = "cgmName"
    static let cgmSensorExpiresAt = "cgmSensorExpiresAt"
    static let cgmProgressPercent = "cgmProgressPercent"
    static let cgmProgressState = "cgmProgressState"
    static let cgmStatusMessage = "cgmStatusMessage"

    // Watch reads the G7 itself (step 1 of watch independence: display and alerts only)
    /// The G7 the phone reads directly ("DXCMxx"); empty when it reads none.
    static let g7DirectSensorName = "g7DirectSensorName"
    /// That sensor's 4-digit pairing code, so the watch can pair in its own slot.
    static let g7DirectPairingCode = "g7DirectPairingCode"
    /// Thresholds for the watch's own alerts in mg/dL; 0 = no such alarm.
    static let watchAlertUrgentLowMgDL = "watchAlertUrgentLowMgDL"
    static let watchAlertLowMgDL = "watchAlertLowMgDL"
    static let watchAlertHighMgDL = "watchAlertHighMgDL"
    /// The user's glucose units, sent with every update, also when the rest of the state is empty.
    static let watchDisplayUnits = "watchDisplayUnits"
    /// The phone's application context while the watch has the pump: only wakes the watch app.
    static let untetheredWake = "untetheredWake"
    /// Settings › Apple Watch › Allow Start Without iPhone, with every watch state.
    static let allowUntetheredStartWithoutPhoneWatch = "allowUntetheredStartWithoutPhoneWatch"
    /// The watch starts untethered mode by itself when the phone is gone (Settings › Apple Watch).
    static let fallbackLoopWatch = "fallbackLoopWatch"
    /// The Nightscout address and API secret hash for the untethered watch's own upload
    /// (`UntetheredNightscoutCredentials.dictionary`); an empty dictionary when it doesn't upload.
    static let nightscoutWatch = "nightscoutWatch"
    static let untetheredWorkoutWatch = "untetheredWorkoutWatch"
    static let watchGlanceLayout = "watchGlanceLayout"
    static let watchGlanceEnabled = "watchGlanceEnabled"
    /// Settings › Notifications › Critical Alerts, with every watch state: the watch's own safety alarms follow it.
    static let useCriticalAlertsWatch = "useCriticalAlertsWatch"

    // Forecast
    static let showForecastWatch = "showForecastWatch"
    static let untetheredModeWatch = "untetheredModeWatch"
    /// The phone app's version and build (`UntetheredVersion.current`), with every watch state.
    static let phoneAppVersion = "phoneAppVersion"
    static let isForecastCone = "isForecastCone"
    static let forecastData = "forecastData"
    static let forecastStartDate = "forecastStartDate"
    static let forecastConeMin = "forecastConeMin"
    static let forecastConeMax = "forecastConeMax"
    static let forecastLines = "forecastLines"
}

/// One element of Extended Untethered Mode's minimal watch screen, arranged on the phone like the Live Activity's
/// widgets (`WatchGlanceLayout`).
enum WatchGlanceItem: String, CaseIterable, Codable, Hashable {
    // the middle
    case glucoseLarge
    case glucoseChart
    case chart
    // the rows
    case glucose
    case loop
    case iob
    case cob
    case iobCob
    case basalIobCob
    case tempBasal
    case eventualGlucose
    case heartRate
    case reservoir
    case lastReading
    case totalDailyDose
    case clock
    /// The slot taken by the wide element left of it.
    case continuation

    static let centerItems: [WatchGlanceItem] = [.glucoseLarge, .glucoseChart, .chart]
    static var rowItems: [WatchGlanceItem] { allCases.filter { !$0.isCenter && $0 != .continuation } }

    var isCenter: Bool { Self.centerItems.contains(self) }

    /// Slots it takes in its row.
    var width: Int {
        switch self {
        case .iobCob: return 2
        case .basalIobCob: return 3
        default: return 1
        }
    }

    /// What a combined element shows, side by side.
    var parts: [WatchGlanceItem] {
        switch self {
        case .iobCob: return [.iob, .cob]
        case .basalIobCob: return [.tempBasal, .iob, .cob]
        default: return [self]
        }
    }

    var label: String {
        switch self {
        case .glucoseLarge: return String(localized: "Glucose", comment: "Watch minimal screen: large glucose")
        case .glucoseChart: return String(
                localized: "Glucose and Chart",
                comment: "Watch minimal screen: glucose above the chart"
            )
        case .chart: return String(localized: "Chart", comment: "Watch minimal screen: glucose chart with forecast")
        case .glucose: return String(localized: "BG", comment: "Watch minimal screen: small glucose")
        case .loop: return String(localized: "Loop", comment: "Watch minimal screen: loop status")
        case .iob: return String(localized: "IOB", comment: "Watch minimal screen: insulin on board")
        case .cob: return String(localized: "COB", comment: "Watch minimal screen: carbs on board")
        case .iobCob: return String(localized: "IOB and COB", comment: "Watch minimal screen: IOB and COB together")
        case .basalIobCob: return String(localized: "Temp, IOB and COB", comment: "Watch minimal screen: temp basal, IOB and COB")
        case .tempBasal: return String(localized: "Temp", comment: "Watch minimal screen: running temp basal")
        case .eventualGlucose: return String(localized: "Eventual", comment: "Watch minimal screen: eventual glucose")
        case .heartRate: return String(localized: "BPM", comment: "Watch minimal screen: heart rate")
        case .reservoir: return String(localized: "Reservoir", comment: "Watch minimal screen: pump reservoir")
        case .lastReading: return String(localized: "Updated", comment: "Watch minimal screen: age of the newest reading")
        case .totalDailyDose: return String(localized: "TDD", comment: "Watch minimal screen: total daily dose")
        case .clock: return String(localized: "Time", comment: "Watch minimal screen: current time")
        case .continuation: return ""
        }
    }
}

/// Slot 0 is the middle, 1–2 the row above it, 3–5 the row below. A wide element takes the slots right of it in its row
/// as `continuation`; each element is placed at most once.
struct WatchGlanceLayout: Codable, Hashable {
    static let center = 0
    static let rows: [Range<Int>] = [1 ..< 3, 3 ..< 6]
    static let slotCount = 6
    static let standard = WatchGlanceLayout(slots: [.glucoseLarge, .loop, .lastReading, .tempBasal, .iob, .cob])

    private(set) var slots: [WatchGlanceItem?]

    /// Whatever arrives (another version, a hand-edited setting) is made valid: the wrong kind in a slot, a repeat, or a
    /// continuation without its element reads as empty.
    init(slots: [WatchGlanceItem?]) {
        self.slots = Array(repeating: nil, count: Self.slotCount)
        if let middle = slots.first ?? nil, middle.isCenter { self.slots[Self.center] = middle }
        for row in Self.rows {
            for slot in row where slot < slots.count {
                guard let item = slots[slot], !item.isCenter, item != .continuation else { continue }
                _ = place(item, at: slot, keepingOthers: true)
            }
        }
    }

    /// As sent to the watch: raw values, "" for an empty slot.
    init(strings: [String]) {
        self.init(slots: strings.map { WatchGlanceItem(rawValue: $0) })
    }

    var strings: [String] { slots.map { $0?.rawValue ?? "" } }

    init(from decoder: Decoder) throws {
        self.init(slots: try decoder.singleValueContainer().decode([WatchGlanceItem?].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(slots)
    }

    /// The elements of row `index`, each with the slot it starts in; an empty slot is nil.
    func row(_ index: Int) -> [(slot: Int, item: WatchGlanceItem?)] {
        Self.rows[index].compactMap { slot in slots[slot] == .continuation ? nil : (slot, slots[slot]) }
    }

    /// The element whose slots include `slot`.
    func owner(of slot: Int) -> (slot: Int, item: WatchGlanceItem)? {
        guard let row = Self.rows.first(where: { $0.contains(slot) }) else {
            return slots[slot].map { (slot, $0) }
        }
        var start = slot
        while start > row.lowerBound, slots[start] == .continuation { start -= 1 }
        guard let item = slots[start], item != .continuation else { return nil }
        return (start, item)
    }

    /// Puts `item` at `slot`, moving it if it was placed already; a wide element shifts left to fit its row and replaces
    /// what it covers. False when it cannot go there (a middle element outside the middle, or the other way round).
    @discardableResult mutating func place(_ item: WatchGlanceItem, at slot: Int) -> Bool {
        place(item, at: slot, keepingOthers: false)
    }

    private mutating func place(_ item: WatchGlanceItem, at slot: Int, keepingOthers: Bool) -> Bool {
        guard item != .continuation, slots.indices.contains(slot) else { return false }
        if item.isCenter {
            guard slot == Self.center else { return false }
            slots[slot] = item
            return true
        }
        guard let row = Self.rows.first(where: { $0.contains(slot) }), item.width <= row.count else { return false }
        let start = min(slot, row.upperBound - item.width)
        let covered = start ..< start + item.width
        if keepingOthers {
            // building from saved slots: an element that would cover another, or repeat one, is dropped
            guard !slots.contains(item), covered.allSatisfy({ slots[$0] == nil }) else { return false }
        } else {
            remove(item)
            for slot in covered { clear(slot) }
        }
        slots[start] = item
        for slot in covered.dropFirst() { slots[slot] = .continuation }
        return true
    }

    /// Where a tap adds `item`: the middle for a middle element, else the first slots of a row it fits without replacing.
    @discardableResult mutating func placeInFirstFreeSlot(_ item: WatchGlanceItem) -> Bool {
        if item.isCenter { return place(item, at: Self.center) }
        for row in Self.rows {
            for start in row where start + item.width <= row.upperBound {
                if (start ..< start + item.width).allSatisfy({ slots[$0] == nil }) { return place(item, at: start) }
            }
        }
        return false
    }

    /// Empties the element that covers `slot`, all its slots.
    mutating func clear(_ slot: Int) {
        guard let owner = owner(of: slot) else { return }
        for covered in owner.slot ..< owner.slot + owner.item.width { slots[covered] = nil }
    }

    mutating func remove(_ item: WatchGlanceItem) {
        if let slot = slots.firstIndex(of: item) { clear(slot) }
    }
}
