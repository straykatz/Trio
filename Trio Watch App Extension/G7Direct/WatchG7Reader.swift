import Foundation
import Observation
import UserNotifications
import WatchKit

/// Reads the G7 directly from the watch, in the watch's own display slot, so
/// glucose keeps arriving (and lows and highs still alert) when the iPhone is
/// out of reach. Display and alerts only: nothing here doses.
///
/// The phone supplies what the watch cannot find out itself: which sensor,
/// its pairing code, the alarm thresholds and the display units. They arrive
/// with every watch state update and are kept, so the watch can carry on
/// alone afterwards.
@Observable final class WatchG7Reader: WatchG7SessionDelegate {
    static let shared = WatchG7Reader()

    // MARK: - Settings and phone-supplied values (persisted)

    /// The user's switch on the watch. Off by default: nothing touches
    /// Bluetooth until it is turned on.
    private(set) var isEnabled: Bool
    private(set) var sensorName: String?
    private(set) var pairingCode: String?
    /// False once the phone has said it is not reading a G7 directly.
    private(set) var phoneUsesG7Direct: Bool?
    private(set) var units: String
    private(set) var urgentLowMgDL: Double
    private(set) var lowMgDL: Double?
    private(set) var highMgDL: Double?

    /// The watch's own key for the sensor, from its own pairing.
    private(set) var hasWatchKey: Bool

    // MARK: - Live state

    /// The watch's own readings, oldest first, kept for 12 hours.
    private(set) var history: [WatchG7Reading]
    private(set) var isConnected = false
    private(set) var isSearching = false
    /// Untethered mode holds the sensor (same watch display slot): the reader lets go until it ends.
    private(set) var isStandingAside = false
    /// Back from untethered mode, until the first reading arrives.
    private(set) var isReconnecting = false
    /// The sensor's state when it last answered without a usable reading (warm-up, failed, ...).
    private(set) var sensorProblem: String? = nil
    /// The same as a few words for the first page, so a missing reading is put down to the sensor, not the watch.
    private(set) var sensorProblemLabel: String? = nil
    /// Answers in a row with a temporary sensor issue; the second raises "Sensor Issue".
    @ObservationIgnored private var temporaryIssueCount = 0
    private(set) var logLines: [String] = []
    /// When the last watch state update from the phone was made.
    private(set) var lastPhoneContact: Date?
    /// The newest glucose the phone has. The phone can still reach the watch
    /// while it has lost the sensor (flight mode keeps the watch link), so
    /// this, not the contact, says whether the phone's glucose is current.
    private(set) var phoneGlucoseDate: Date?
    /// When the phone last enacted a temp basal or bolus, from its state. Nil from a phone build without it.
    private(set) var phoneDoseDate: Date?

    /// The newest sign that the phone loops: its own newest reading or its last dose, whichever is newer. Contact
    /// alone isn't one (22 October: a phone in a metal pot got through for 5 s with only an old reading), nor are its
    /// status reads of the pod (8 November: a phone without a sensor kept reaching the pod and couldn't loop).
    var phoneLoopSign: Date? {
        [phoneGlucoseDate, phoneDoseDate].compactMap { $0 }.max()
    }

    /// The phone took the pump back from an untethered session: it doses from now on, as its next state will say,
    /// often minutes late (11 November, 10:51: the fallback looked at the pod 5 minutes after a hand-back, and the
    /// look cost the phone its next loop). Counts as its newest dose until the state brings a newer one.
    func notePhoneTookPump(at date: Date = Date()) {
        guard date > (phoneDoseDate ?? .distantPast) else { return }
        phoneDoseDate = date
        defaults.set(date, forKey: Key.phoneDoseDate)
    }

    /// The phone's own newest reading as its wake carries it (`untetheredWake`), ahead of the state that brings it
    /// too: the hand-back to a phone that reads again goes by this date.
    func notePhoneOwnReading(_ date: Date) {
        guard date > (phoneGlucoseDate ?? .distantPast) else { return }
        phoneGlucoseDate = date
        defaults.set(date, forKey: Key.phoneGlucoseDate)
    }

    // MARK: - Private

    @ObservationIgnored private var session: WatchG7Session?
    @ObservationIgnored private var sharedKey: Data?
    @ObservationIgnored private var peripheralIdentifier: UUID?
    private let defaults = UserDefaults.standard
    @ObservationIgnored private var heldBluetoothTask: WKRefreshBackgroundTask?
    @ObservationIgnored private var completedBluetoothTasks: [WKRefreshBackgroundTask] = []

    private static let historyDuration = TimeInterval(hours: 12)
    /// A reading this old still shows on the watch face.
    static let freshReadingAge = TimeInterval(minutes: 11)
    /// The phone counts as gone once its last update is this old.
    static let phoneQuietAfter = TimeInterval(minutes: 10)

    private enum Key {
        static let enabled = "watchG7.enabled"
        static let sensorName = "watchG7.sensorName"
        static let pairingCode = "watchG7.pairingCode"
        static let phoneUsesG7Direct = "watchG7.phoneUsesG7Direct"
        static let units = "watchG7.units"
        static let urgentLow = "watchG7.urgentLowMgDL"
        static let low = "watchG7.lowMgDL"
        static let high = "watchG7.highMgDL"
        static let sharedKey = "watchG7.sharedKey"
        static let peripheralIdentifier = "watchG7.peripheralIdentifier"
        static let history = "watchG7.history"
        static let log = "watchG7.log"
        static let lastAlert = "watchG7.lastAlert."
        static let lastPhoneContact = "watchG7.lastPhoneContact"
        static let phoneGlucoseDate = "watchG7.phoneGlucoseDate"
        static let phoneDoseDate = "watchG7.phoneDoseDate"
        static let liveReadings = "watchG7.liveReadings"
        static let asideSpans = "watchG7.asideSpans"
    }

    /// When live readings arrived (not filled in afterwards), for the coverage line.
    private var liveReadingDates: [Date] = []
    /// Untethered mode's stretches with the sensor, [start, end], end 0 while it lasts: no gap of the reader's.
    private var asideSpans: [[TimeInterval]] = []

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Key.enabled)
        sensorName = defaults.string(forKey: Key.sensorName)
        pairingCode = defaults.string(forKey: Key.pairingCode)
        phoneUsesG7Direct = defaults.object(forKey: Key.phoneUsesG7Direct) as? Bool
        units = defaults.string(forKey: Key.units) ?? "mg/dL"
        urgentLowMgDL = defaults.object(forKey: Key.urgentLow) as? Double ?? 54
        lowMgDL = defaults.object(forKey: Key.low) as? Double
        highMgDL = defaults.object(forKey: Key.high) as? Double
        sharedKey = defaults.data(forKey: Key.sharedKey)
        hasWatchKey = defaults.data(forKey: Key.sharedKey) != nil
        peripheralIdentifier = defaults.string(forKey: Key.peripheralIdentifier).flatMap(UUID.init(uuidString:))
        lastPhoneContact = defaults.object(forKey: Key.lastPhoneContact) as? Date
        phoneGlucoseDate = defaults.object(forKey: Key.phoneGlucoseDate) as? Date
        phoneDoseDate = defaults.object(forKey: Key.phoneDoseDate) as? Date
        if let data = defaults.data(forKey: Key.history),
           let saved = try? JSONDecoder().decode([WatchG7Reading].self, from: data)
        {
            history = saved
        } else {
            history = []
        }
        // The log survives restarts, so a gap can still be looked at afterwards.
        logLines = defaults.stringArray(forKey: Key.log) ?? []
        liveReadingDates = (defaults.array(forKey: Key.liveReadings) as? [TimeInterval] ?? []).map(Date.init(timeIntervalSince1970:))
        asideSpans = defaults.array(forKey: Key.asideSpans) as? [[TimeInterval]] ?? []
    }

    private func noteLiveReading(_ date: Date) {
        let cutoff = Date().addingTimeInterval(-TimeInterval(hours: 2))
        liveReadingDates = (liveReadingDates + [date]).filter { $0 > cutoff }
        UserDefaults.standard.set(liveReadingDates.map(\.timeIntervalSince1970), forKey: Key.liveReadings)
    }

    private func noteAside(_ aside: Bool) {
        let now = Date().timeIntervalSince1970
        if aside {
            asideSpans.append([now, 0])
        } else if let last = asideSpans.indices.last, asideSpans[last].count == 2, asideSpans[last][1] == 0 {
            asideSpans[last][1] = now
        }
        let cutoff = now - 2 * 3600
        asideSpans.removeAll { $0.count != 2 || ($0[1] != 0 && $0[1] < cutoff) }
        UserDefaults.standard.set(asideSpans, forKey: Key.asideSpans)
    }

    // MARK: - Derived values for the views

    var latest: WatchG7Reading? { history.last }

    /// The newest reading if it is recent enough to show.
    var freshReading: WatchG7Reading? {
        guard let latest, Date().timeIntervalSince(latest.date) < Self.freshReadingAge else { return nil }
        return latest
    }

    /// The phone has no current glucose: it is out of reach, or it is in
    /// reach but has lost the sensor. The watch is on its own.
    var phoneGlucoseIsStale: Bool {
        guard let phoneGlucoseDate else { return true }
        return Date().timeIntervalSince(phoneGlucoseDate) > Self.phoneQuietAfter
    }

    /// The watch's own reading when it is newer than what the phone shows:
    /// the phone's data is stale, or the phone has missed a reading the watch got.
    func readingToShow(phoneDataIsDated: Bool) -> WatchG7Reading? {
        guard isEnabled, let fresh = freshReading else { return nil }
        if phoneDataIsDated { return fresh }
        guard let phoneGlucoseDate else { return fresh }
        // Readings are 5 minutes apart: anything 2.5 minutes newer is a reading the phone does not have.
        return fresh.date.timeIntervalSince(phoneGlucoseDate) > TimeInterval(minutes: 2.5) ? fresh : nil
    }

    var isMmol: Bool { units == "mmol/L" }

    func format(_ mgdl: Double) -> String {
        isMmol ? String(format: "%.1f", mgdl * 0.0555) : String(Int(mgdl.rounded()))
    }

    /// The change since the reading about five minutes earlier, formatted.
    var deltaText: String? {
        guard let latest else { return nil }
        let earlier = history.dropLast().last(where: { reading in
            let gap = latest.date.timeIntervalSince(reading.date)
            return gap >= TimeInterval(minutes: 3) && gap <= TimeInterval(minutes: 7)
        })
        guard let previous = earlier else { return nil }
        let delta = Double(latest.glucose - previous.glucose)
        if isMmol {
            return String(format: "%+.1f", delta * 0.0555)
        }
        return String(format: "%+ld", Int(delta))
    }

    /// The watch's own live readings over the last two hours: how many of the possible ones arrived, the longest
    /// stretch without one, and how many were only filled in afterwards. Untethered mode's time with the sensor is
    /// left out: the reader pauses then on purpose. (29 October: filled-in readings counted as arrived, so a 25-minute
    /// gap showed as "24/24, longest gap 5 min", and a session as a 26-minute gap.)
    var recentCoverage: (count: Int, expected: Int, longestGapMinutes: Int, filledIn: Int) {
        let now = Date()
        let window = TimeInterval(hours: 2)
        let start = now.addingTimeInterval(-window)
        let spans = asideSpans.compactMap { span -> (Date, Date)? in
            guard span.count == 2 else { return nil }
            let from = max(Date(timeIntervalSince1970: span[0]), start)
            let to = span[1] == 0 ? now : min(Date(timeIntervalSince1970: span[1]), now)
            return from < to ? (from, to) : nil
        }
        func aside(_ date: Date) -> Bool { spans.contains { $0.0 <= date && date <= $0.1 } }
        let live = liveReadingDates.filter { $0 > start && !aside($0) }
        // the gaps between live readings, each stretch with the sensor closing one and opening the next
        let events = (live.map { ($0, $0) } + spans).sorted { $0.0 < $1.0 }
        var longest: TimeInterval = 0
        var previous = start
        for (from, to) in events {
            longest = max(longest, from.timeIntervalSince(previous))
            previous = max(previous, to)
        }
        longest = max(longest, now.timeIntervalSince(previous))
        let asideTotal = spans.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
        let filledIn = history.filter { reading in
            reading.date > start && !aside(reading.date) && !live.contains { abs($0.timeIntervalSince(reading.date)) < 60 }
        }.count
        return (live.count, Int((window - asideTotal) / 300), Int(longest / 60), filledIn)
    }

    /// One line saying what the watch is doing, for the sensor page.
    var statusText: String {
        guard isEnabled else {
            return String(localized: "Off", comment: "Watch G7 status: the watch does not read the sensor")
        }
        if isStandingAside {
            return String(
                localized: "Paused: watch mode reads the sensor",
                comment: "Watch G7 status: watch mode holds the sensor"
            )
        }
        if isReconnecting, !isConnected {
            return String(
                localized: "Reconnecting to the sensor…",
                comment: "Watch G7 status: pairing again after watch mode"
            )
        }
        if phoneUsesG7Direct == false, sensorName == nil {
            return String(
                localized: "iPhone isn't on G7 direct",
                comment: "Watch G7 status: the phone is not using G7 direct"
            )
        }
        guard sensorName != nil else {
            return String(
                localized: "Waiting for the iPhone",
                comment: "Watch G7 status: nothing received from the phone yet"
            )
        }
        if pairingCode == nil, !hasWatchKey {
            return String(
                localized: "No pairing code",
                comment: "Watch G7 status: the phone has no pairing code"
            )
        }
        if isConnected {
            return String(localized: "Connected", comment: "Watch G7 status: connected")
        }
        if isSearching {
            return String(
                localized: "Searching… keep this open",
                comment: "Watch G7 status: scanning for a sensor it has not found yet"
            )
        }
        if !hasWatchKey {
            return String(
                localized: "Not paired yet. Accept a pairing prompt.",
                comment: "Watch G7 status: found but not yet paired"
            )
        }
        return String(
            localized: "Waiting for next reading",
            comment: "Watch G7 status: paired and idle between readings"
        )
    }

    // MARK: - Lifecycle

    /// At launch, including a background relaunch for Bluetooth: the central
    /// has to exist again before the system hands back the restored link.
    func bootstrap() {
        dispatchPrecondition(condition: .onQueue(.main))
        if isEnabled {
            startSessionIfPossible()
        }
    }

    /// Any wake: a lost Bluetooth callback can leave nothing waiting for the sensor.
    func noteWake() {
        flushLogIfDue()
        guard !isStandingAside else { return }
        session?.recheck()
    }

    /// The app's scene phase, for the acquisition's wait past the sensor's tail: held in the app while in front,
    /// handed to the daemon as a start delay behind (idea from xDrip4iOS 7.2.0, see G7WatchAcquisition).
    func appBecameActive() {
        ActionNotice.clearReminders()
        session?.appBecameActive()
        // a pairing is due: Trio stays in front until the first reading. Opened from a notification, Trio may count
        // as in front only a moment later, so asked again once it has settled.
        if isPairingDue {
            keepInFrontForPairing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.isPairingDue else { return }
                self.keepInFrontForPairing()
            }
        }
    }

    func appLeavingScreen() {
        // also while standing aside: the session only notes it then (see WatchG7Session.appLeavingScreen)
        session?.appLeavingScreen()
    }

    /// Tells the acquisition whether Trio is in front right now, as on resuming after untethered mode.
    private func syncForeground() {
        if WKApplication.shared().applicationState == .active {
            session?.appBecameActive()
        } else {
            session?.appNoteBackground()
        }
    }

    // MARK: - Ahead of silence

    private static let noReadingsID = "trio.watchG7.noReadings"
    /// Three readings missed on the sensor's 5-minute grid.
    private static let noReadingsAfter: TimeInterval = 16 * 60
    /// After untethered mode: the first reading of our own is due within 5 minutes.
    private static let noReadingsAfterHandBack: TimeInterval = 6.5 * 60
    /// When untethered mode gave the sensor back, until the first reading of our own.
    @ObservationIgnored private var handBackAt: Date?

    /// Booked after every reading, the watch's own or the phone's: it sounds even when nothing wakes the app any
    /// more, which is how a failing background link showed until now (2026-10-18: the third page silent for hours).
    /// Opening the app is what puts that right.
    func bookNoReadingsAlert() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.bookNoReadingsAlert() }
            return
        }
        let center = UNUserNotificationCenter.current()
        guard isEnabled, !isStandingAside, sensorName != nil else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.noReadingsID])
            return
        }
        let newest = [latest?.date, phoneGlucoseDate].compactMap { $0 }.max() ?? Date()
        var delay = newest.addingTimeInterval(Self.noReadingsAfter).timeIntervalSinceNow
        let content = UNMutableNotificationContent()
        content.title = String(localized: "No Glucose on the Watch")
        content.body = String(
            localized: "Neither the sensor nor the iPhone has sent a reading for 15 minutes. Open Trio on the watch."
        )
        // After untethered mode the watch's own reading may not come back by itself (25 October, 06:33 to 06:45, the
        // iPhone at home): said after one missed reading instead of three.
        if let handBackAt, (latest?.date ?? .distantPast) < handBackAt {
            let soon = handBackAt.addingTimeInterval(Self.noReadingsAfterHandBack).timeIntervalSinceNow
            if soon < delay {
                delay = soon
                content.body = String(
                    localized: "The watch hasn't read the sensor since watch mode ended. Open Trio on the watch: it reconnects there."
                )
            }
        }
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: Self.noReadingsID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(60, delay), repeats: false)
        ))
    }

    /// The log reaches the phone only when the app goes to the background after being open; a reader that only
    /// runs in background wakes sends it at most every 30 minutes from a wake, so a test leaves a whole log.
    private var lastLogFlush = Date()
    private func flushLogIfDue() {
        guard Date().timeIntervalSince(lastLogFlush) > 30 * 60,
              !UntetheredWatchManager.shared.holdsSensorLink
        else { return }
        lastLogFlush = Date()
        Task { await WatchLogger.shared.flushPersistedLogs(queued: true) }
    }

    /// Untethered mode takes the sensor in the same watch display slot from its first handshake on
    /// and gives it back when it is idle again. Only one of the two may talk to the sensor; afterwards
    /// the reader may have to pair again, which it does by itself with the code it has.
    func standAside(_ aside: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard aside != isStandingAside else { return }
        isStandingAside = aside
        noteAside(aside)
        if aside {
            appendLog("Paused: watch mode has the sensor")
            // untethered mode books its own "No Sensor Readings"
            bookNoReadingsAlert()
            session?.pause()
            isConnected = false
            isSearching = false
        } else {
            // The sensor keeps one key for the watch slot, and untethered mode may have paired it afresh,
            // which made the reader's own key worthless: every hand-back then cost a full pairing over two
            // sensor windows (test 17.10.: 19:22 to 19:23, and again from 19:45 to 19:55 the other way).
            // Take the slot's newest key, so the next connection authenticates at once.
            // Then connect to the sensor untethered mode just read, by its handle: the system keeps that
            // request while the app sleeps, as untethered mode's own reconnects every 5 minutes show. A scan
            // without a handle only found the sensor with the app open (test 17.10.: 4 s in front at 20:05,
            // nothing in 43 minutes in the background from 20:55).
            if pairingCode != nil {
                if let slotKey = WatchG7SlotKey.current, slotKey != sharedKey {
                    sharedKey = slotKey
                    hasWatchKey = true
                    defaults.set(slotKey, forKey: Key.sharedKey)
                }
                let handle = WatchG7SlotKey.peripheral
                setPeripheralIdentifier(handle)
                appendLog(
                    !isEnabled
                        ? "Watch mode over: the watch sensor is switched off, not reading"
                        : handle == nil
                        ? "Watch mode over: reading again, searching for the sensor"
                        : "Watch mode over: reading again, connecting to the sensor it used"
                )
                session?.update(credentials: credentials)
            } else {
                appendLog(isEnabled ? "Watch mode over: reading again" : "Watch mode over: the watch sensor is switched off, not reading")
            }
            isReconnecting = true
            // the reminder below counts from here until the first reading of our own
            handBackAt = Date()
            if isEnabled, sensorName != nil, let session {
                session.update(credentials: credentials)
                session.resumeAfterUntethered()
                syncForeground()
            } else {
                startSessionIfPossible()
            }
            bookNoReadingsAlert()
        }
    }

    /// Asks watchOS for a background wake 7 minutes on (it decides the actual timing), put off again by each
    /// reading, so it only comes when one is missing. Each wake re-checks the sensor connection, so a request the
    /// system dropped is put back without the app being opened. 7 minutes: just past the point where a missed sensor
    /// window counts as lost. At 15 minutes, and booked only at launch and on its own wake, watchOS ending Trio in
    /// the background left the watch without readings for 20 minutes (9 November, 13:16 to 13:36, relaunched only for
    /// Bluetooth). An untethered session books its own (`scheduleSessionRefresh`), which replaces this one.
    func scheduleBackgroundRefresh() {
        guard isEnabled else { return }
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(Self.backgroundRefreshDelay),
            userInfo: nil
        ) { _ in }
    }

    static let backgroundRefreshDelay: TimeInterval = 7 * 60

    func setEnabled(_ enabled: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
        if enabled {
            appendLog("Turned on")
            requestNotificationPermission()
            startSessionIfPossible()
            scheduleBackgroundRefresh()
        } else {
            appendLog("Turned off")
            bookNoReadingsAlert()
            session?.pause()
            isConnected = false
            isSearching = false
        }
    }

    /// Forgets the watch's own pairing with the sensor; the next connection pairs again.
    func resetWatchPairing() {
        dispatchPrecondition(condition: .onQueue(.main))
        appendLog("Pairing reset on the watch")
        setSharedKey(nil)
        setPeripheralIdentifier(nil)
        session?.update(credentials: credentials)
        pairingBecameDue()
        // the iPhone may have a newer sensor the watch hasn't heard of yet
        WatchState.shared.requestWatchStateUpdate()
    }

    /// "Pair sensor now" on the sensor page, while the watch has no key: asks the iPhone for the current sensor and
    /// code, looks for the sensor at once and keeps Trio in front until the first reading. A missed "Open Trio to
    /// Pair the Sensor" left only a greyed-out button behind the details (8 November, third tester: a new sensor on
    /// the phone, no pairing on the watch, and no way to start it).
    func pairNow() {
        dispatchPrecondition(condition: .onQueue(.main))
        appendLog("Pairing: started from the sensor page")
        WatchState.shared.requestWatchStateUpdate()
        lastPairingAsk = nil
        startSessionIfPossible()
        session?.recheck()
        keepInFrontForPairing()
    }

    private var credentials: WatchG7Credentials {
        WatchG7Credentials(
            sensorName: sensorName,
            pairingCode: pairingCode,
            sharedKey: sharedKey,
            peripheralIdentifier: peripheralIdentifier
        )
    }

    private func startSessionIfPossible() {
        guard isEnabled, !isStandingAside, sensorName != nil else { return }
        if let session {
            session.update(credentials: credentials)
            session.resume()
            syncForeground()
        } else {
            let session = WatchG7Session(credentials: credentials, latestReadingDate: latest?.date)
            session.delegate = self
            self.session = session
            appendLog("Starting")
            session.resume()
            syncForeground()
        }
    }

    // MARK: - From the phone

    /// Called with every watch state update the phone sends.
    func updateFromPhone(_ payload: [String: Any]) {
        dispatchPrecondition(condition: .onQueue(.main))
        // Every phone update is also a wake: re-check the sensor connection.
        noteWake()

        if let timestamp = payload[WatchMessageKeys.date] as? TimeInterval {
            let date = Date(timeIntervalSince1970: timestamp)
            if date > (lastPhoneContact ?? .distantPast) {
                lastPhoneContact = date
                defaults.set(date, forKey: Key.lastPhoneContact)
            }
        }

        if let values = payload[WatchMessageKeys.glucoseValues] as? [[String: Any]],
           let newest = values.compactMap({ $0["date"] as? TimeInterval }).max()
        {
            var date = Date(timeIntervalSince1970: newest)
            // The phone's state also carries the watch's own readings it stored: what counts is when the phone itself
            // last read one (30 October: its Bluetooth off, it kept sending the watch's readings back, and the watch
            // took that for the phone being back). A phone build without the key is taken as before.
            if let own = payload[WatchMessageKeys.phoneOwnGlucoseDate] as? TimeInterval {
                date = min(date, Date(timeIntervalSince1970: own))
            }
            phoneGlucoseDate = date
            defaults.set(date, forKey: Key.phoneGlucoseDate)
            session?.notePhoneReading(at: date)
            bookNoReadingsAlert()
        }
        if let dose = payload[WatchMessageKeys.phoneLastDoseDate] as? TimeInterval {
            let date = Date(timeIntervalSince1970: dose)
            if date > (phoneDoseDate ?? .distantPast) {
                phoneDoseDate = date
                defaults.set(date, forKey: Key.phoneDoseDate)
            }
        }

        // Units from the dedicated key; the general one only from a state with
        // glucose in it, because an empty default state says mg/dL.
        let hasGlucose = !((payload[WatchMessageKeys.glucoseValues] as? [[String: Any]])?.isEmpty ?? true)
        let sentUnits = payload[WatchMessageKeys.watchDisplayUnits] as? String
            ?? (hasGlucose ? payload[WatchMessageKeys.units] as? String : nil)
        if let units = sentUnits, units != self.units {
            self.units = units
            defaults.set(units, forKey: Key.units)
        }
        if let value = payload[WatchMessageKeys.watchAlertUrgentLowMgDL] as? Double, value > 0 {
            urgentLowMgDL = value
            defaults.set(value, forKey: Key.urgentLow)
        }
        if let value = payload[WatchMessageKeys.watchAlertLowMgDL] as? Double {
            lowMgDL = value > 0 ? value : nil
            defaults.set(lowMgDL, forKey: Key.low)
        }
        if let value = payload[WatchMessageKeys.watchAlertHighMgDL] as? Double {
            highMgDL = value > 0 ? value : nil
            defaults.set(highMgDL, forKey: Key.high)
        }

        // An empty name means the phone is not reading a G7 directly. Keep what
        // the watch already has: a brief switch on the phone should not make
        // the watch forget a sensor it can still read.
        guard let name = payload[WatchMessageKeys.g7DirectSensorName] as? String else { return }
        let usesDirect = !name.isEmpty
        if phoneUsesG7Direct != usesDirect {
            phoneUsesG7Direct = usesDirect
            defaults.set(usesDirect, forKey: Key.phoneUsesG7Direct)
        }
        guard usesDirect else { return }

        let code = (payload[WatchMessageKeys.g7DirectPairingCode] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var credentialsChanged = false
        var newSensorArrived = false

        if name.suffix(2) != sensorName?.suffix(2) {
            if sensorName != nil {
                appendLog("New sensor \(name) from the iPhone")
                lastPairingAsk = nil
                newSensorArrived = true
            }
            sensorName = name
            defaults.set(name, forKey: Key.sensorName)
            // A different sensor: the watch's key and peripheral belong to the old one.
            setSharedKey(nil)
            setPeripheralIdentifier(nil)
            history = []
            saveHistory()
            credentialsChanged = true
        }
        if let code, code != pairingCode {
            if pairingCode != nil, hasWatchKey {
                // A new code means a new sensor, even if its name ends the same.
                setSharedKey(nil)
                setPeripheralIdentifier(nil)
                lastPairingAsk = nil
                newSensorArrived = true
            }
            pairingCode = code
            defaults.set(code, forKey: Key.pairingCode)
            credentialsChanged = true
        }

        if credentialsChanged {
            startSessionIfPossible()
        }
        if newSensorArrived { pairingBecameDue() }
    }

    // MARK: - Background Bluetooth wakes

    /// A wake the system granted because the sensor's link delivered something.
    /// Held for 25 seconds so the reading can arrive, then completed exactly once.
    func hold(bluetoothTask task: WKRefreshBackgroundTask) {
        dispatchPrecondition(condition: .onQueue(.main))
        noteWake()
        if let held = heldBluetoothTask, held !== task {
            // One held per wake; the rest are completed on arrival.
            complete(task)
            return
        }
        heldBluetoothTask = task
        let since = Date()
        // the system may grant less than the hold: end the task right then (an app that overruns its background
        // time is ended and woken less), and log the grant
        task.expirationHandler = { [weak self, weak task] in
            let expire = {
                let granted = Date().timeIntervalSince(since)
                Task { await WatchLogger.shared.log(String(format: "⌚️🩸 G7: Bluetooth wake expired by the system after %.1f s", granted)) }
                if let task { self?.completeHeldBluetoothTask(task) }
            }
            if Thread.isMainThread { expire() } else { DispatchQueue.main.sync(execute: expire) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            self?.completeHeldBluetoothTask(task)
        }
    }

    private func completeHeldBluetoothTask(_ task: WKRefreshBackgroundTask) {
        guard heldBluetoothTask === task else { return }
        heldBluetoothTask = nil
        complete(task)
    }

    private func complete(_ task: WKRefreshBackgroundTask) {
        // Completing a task twice throws inside WatchKit.
        guard !completedBluetoothTasks.contains(where: { $0 === task }) else { return }
        completedBluetoothTasks.append(task)
        if completedBluetoothTasks.count > 64 {
            completedBluetoothTasks.removeFirst(16)
        }
        task.setTaskCompletedWithSnapshot(false)
    }

    // MARK: - Persistence helpers

    private func setSharedKey(_ key: Data?) {
        sharedKey = key
        hasWatchKey = key != nil
        defaults.set(key, forKey: Key.sharedKey)
        if let key { WatchG7SlotKey.record(key, peripheral: peripheralIdentifier) }
    }

    private func setPeripheralIdentifier(_ identifier: UUID?) {
        peripheralIdentifier = identifier
        defaults.set(identifier?.uuidString, forKey: Key.peripheralIdentifier)
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Key.history)
        }
    }

    private func merge(_ readings: [WatchG7Reading]) {
        var merged = history
        for reading in readings where !merged.contains(where: { abs($0.date.timeIntervalSince(reading.date)) < 60 }) {
            merged.append(reading)
        }
        let cutoff = Date().addingTimeInterval(-Self.historyDuration)
        history = merged.filter { $0.date > cutoff }.sorted { $0.date < $1.date }
        saveHistory()
    }

    private func appendLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm:ss"
        logLines.append("\(formatter.string(from: Date())) \(line)")
        if logLines.count > 200 {
            logLines.removeFirst(logLines.count - 200)
        }
        defaults.set(logLines, forKey: Key.log)
        Task {
            await WatchLogger.shared.log("⌚️🩸 G7: \(line)")
        }
    }

    // MARK: - Sensor warning (first page and watch face)

    /// Something about the sensor needs a look: it reports a problem, or untethered mode has had no reading for
    /// 11 minutes. Shown as a yellow triangle on the first page and the watch face; page 3 says what it is.
    var showsSensorWarning: Bool {
        let untethered = UntetheredWatchManager.shared
        if untethered.isActive {
            let newest = untethered.data.glucose.map(\.dateString).max() ?? .distantPast
            return Date().timeIntervalSince(newest) > 11 * 60
        }
        return isEnabled && sensorProblemLabel != nil
    }

    /// Hands the warning to the watch face when it may have changed.
    func refreshSensorWarning() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refreshSensorWarning() }
            return
        }
        ComplicationStore.setSensorWarning(showsSensorWarning)
    }

    // MARK: - Sensor state alerts

    private enum SensorAlert: String {
        case failed = "sensorFailed"
        case ended = "sensorEnded"
        case issue = "sensorIssue"

        var title: String {
            switch self {
            case .failed: return String(localized: "Sensor Failed", comment: "Watch G7 alert title: the sensor reports it has failed")
            case .ended: return String(localized: "Sensor Session Ended", comment: "Watch G7 alert title: the sensor's session is over")
            case .issue: return String(localized: "Sensor Issue", comment: "Watch G7 alert title: the sensor reports a temporary problem")
            }
        }

        var body: String {
            switch self {
            case .failed:
                return String(
                    localized: "The G7 reports that it has failed and sends no more glucose. The watch and Trio are working; replace the sensor.",
                    comment: "Watch G7 alert body: sensor failed"
                )
            case .ended:
                return String(
                    localized: "The G7 reports that its session is over and sends no more glucose. Replace the sensor.",
                    comment: "Watch G7 alert body: sensor session ended"
                )
            case .issue:
                return String(
                    localized: "The G7 reports a temporary sensor issue and sends no glucose for now. The watch and Trio are working; readings come back when the sensor recovers.",
                    comment: "Watch G7 alert body: temporary sensor issue"
                )
            }
        }
    }

    /// A G7 that answers without glucose says why. Its own state is what the wrist should hear, also with the phone
    /// nearby: a missing reading otherwise looks like the watch or Trio not updating. Warm-up only shows on the page.
    private func noteSensorState(_ state: AlgorithmState) {
        if state.sensorFailed {
            sensorProblemLabel = String(localized: "Sensor failed", comment: "Watch first page: the sensor reports it has failed")
            raiseSensorAlert(.failed)
        } else if case let .known(known) = state, [.sessionExpired, .expired, .sessionEnded, .stopped].contains(known) {
            sensorProblemLabel = String(localized: "Sensor ended", comment: "Watch first page: the sensor's session is over")
            raiseSensorAlert(.ended)
        } else if state.isInWarmup {
            sensorProblemLabel = String(localized: "Sensor warming up", comment: "Watch first page: the sensor is warming up")
        } else {
            sensorProblemLabel = String(localized: "Sensor issue", comment: "Watch first page: the sensor sends no glucose for now")
            temporaryIssueCount += 1
            if temporaryIssueCount >= 2 { raiseSensorAlert(.issue) }
        }
    }

    private func sensorStateRecovered() {
        temporaryIssueCount = 0
        // before the guard: the label doesn't survive a relaunch, the flags do, and a flag left from a failed sensor
        // would keep the next sensor's failure or end silent
        for alert in [SensorAlert.failed, .ended, .issue] {
            defaults.removeObject(forKey: Key.lastAlert + alert.rawValue)
        }
        guard sensorProblemLabel != nil else { return }
        sensorProblemLabel = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [SensorAlert.issue].map { Self.notificationIdentifierPrefix + $0.rawValue }
        )
        appendLog("Sensor sends glucose again")
    }

    /// Once per sensor problem: it is cleared by the next good reading. "Failed" is critical when Critical Alerts
    /// are on for the watch, as untethered mode's sensor alarms are.
    private func raiseSensorAlert(_ alert: SensorAlert) {
        let key = Key.lastAlert + alert.rawValue
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(Date(), forKey: key)
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        let critical = alert == .failed && defaults.bool(forKey: WatchMessageKeys.useCriticalAlertsWatch)
        content.sound = critical ? .defaultCritical : .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: Self.notificationIdentifierPrefix + alert.rawValue,
            content: content,
            trigger: nil
        ))
        WKInterfaceDevice.current().play(.failure)
        appendLog("Alert: \(alert.title)")
    }

    // MARK: - Alerts

    private enum AlertKind: String {
        case urgentLow
        case low
        case high

        var repeatInterval: TimeInterval {
            switch self {
            case .urgentLow: return TimeInterval(minutes: 5)
            case .low: return TimeInterval(minutes: 15)
            case .high: return TimeInterval(minutes: 60)
            }
        }

        var title: String {
            switch self {
            case .urgentLow: return String(localized: "Urgent Low", comment: "Watch G7 alert title")
            case .low: return String(localized: "Low Glucose", comment: "Watch G7 alert title")
            case .high: return String(localized: "High Glucose", comment: "Watch G7 alert title")
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted {
                DispatchQueue.main.async {
                    self.appendLog("Notifications are not allowed for Trio on the watch; alerts will not show")
                }
            }
        }
    }

    /// Alerts only while the phone has no current glucose: when it has, Trio's
    /// own alarms already reach the wrist.
    private func evaluateAlerts(for reading: WatchG7Reading) {
        guard phoneGlucoseIsStale, Date().timeIntervalSince(reading.date) < Self.freshReadingAge else { return }
        let glucose = Double(reading.glucose)
        let margin = 5.0

        if glucose <= urgentLowMgDL {
            fire(.urgentLow, reading: reading)
        } else if glucose > urgentLowMgDL + margin {
            clear(.urgentLow)
        }

        if let low = lowMgDL {
            if glucose <= low, glucose > urgentLowMgDL {
                fire(.low, reading: reading)
            } else if glucose > low + margin {
                clear(.low)
            }
        }

        if let high = highMgDL {
            if glucose >= high {
                fire(.high, reading: reading)
            } else if glucose < high - margin {
                clear(.high)
            }
        }
    }

    private func fire(_ kind: AlertKind, reading: WatchG7Reading) {
        let key = Key.lastAlert + kind.rawValue
        if let last = defaults.object(forKey: key) as? Date, Date().timeIntervalSince(last) < kind.repeatInterval {
            return
        }
        defaults.set(Date(), forKey: key)

        let content = UNMutableNotificationContent()
        content.title = kind.title
        let value = "\(format(Double(reading.glucose))) \(units) \(arrow(for: reading.trendName))"
        content.body = String(
            format: String(
                localized: "%@ · read by your watch. No data from the iPhone.",
                comment: "Watch G7 alert body (1: glucose with units and trend arrow)"
            ),
            value
        )
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifierPrefix + kind.rawValue,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        WKInterfaceDevice.current().play(kind == .high ? .notification : .failure)
        appendLog("Alert: \(kind.title) \(value)")
    }

    private func clear(_ kind: AlertKind) {
        let key = Key.lastAlert + kind.rawValue
        guard defaults.object(forKey: key) != nil else { return }
        defaults.removeObject(forKey: key)
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [Self.notificationIdentifierPrefix + kind.rawValue]
        )
    }

    static let notificationIdentifierPrefix = "trio.watchG7."

    func arrow(for trendName: String?) -> String {
        switch trendName {
        case "DoubleUp": return "⇈"
        case "SingleUp": return "↑"
        case "FortyFiveUp": return "↗"
        case "Flat": return "→"
        case "FortyFiveDown": return "↘"
        case "SingleDown": return "↓"
        case "DoubleDown": return "⇊"
        default: return ""
        }
    }

    // MARK: - WatchG7SessionDelegate (called on the session's queue)

    func session(_: WatchG7Session, didRead message: WatchG7GlucoseMessage, receivedAt: Date) {
        DispatchQueue.main.async {
            guard message.hasReliableGlucose, let glucose = message.glucose else {
                let problem = String(describing: message.algorithmState)
                self.sensorProblem = problem
                self.appendLog("Sensor answered without a reading (\(problem))")
                self.noteSensorState(message.algorithmState)
                self.refreshSensorWarning()
                return
            }
            self.sensorProblem = nil
            self.sensorStateRecovered()
            self.refreshSensorWarning()
            self.isReconnecting = false
            let reading = WatchG7Reading(
                date: receivedAt.addingTimeInterval(-TimeInterval(message.age)),
                glucose: Int(glucose),
                trendRate: message.trend
            )
            self.merge([reading])
            self.noteLiveReading(reading.date)
            // the backstop wake is put off: it comes only if the next reading doesn't
            if !self.isStandingAside { self.scheduleBackgroundRefresh() }
            self.handBackAt = nil
            UntetheredWatchManager.shared.checkFallback(readerReadings: self.history.map(\.date))
            UntetheredWatchManager.shared.resendOwnershipAnswerIfUnconfirmed()
            ComplicationStore.add(reading)
            self.bookNoReadingsAlert()
            self.appendLog("Reading \(self.format(Double(reading.glucose))) \(self.units) \(self.arrow(for: reading.trendName))")
            self.evaluateAlerts(for: reading)
        }
    }

    func session(_: WatchG7Session, didReadBackfill readings: [WatchG7Reading]) {
        DispatchQueue.main.async {
            self.merge(readings)
            self.appendLog("Filled in \(readings.count) missed readings")
        }
    }

    func session(_: WatchG7Session, didAuthenticateWith sharedKey: Data) {
        DispatchQueue.main.async {
            self.setSharedKey(sharedKey)
            self.appendLog("Paired with the sensor")
        }
    }

    func sessionDidInvalidateSharedKey(_: WatchG7Session) {
        DispatchQueue.main.async {
            self.setSharedKey(nil)
            // the next connection pairs again: asked for now, not only once the system's prompt appears
            self.pairingBecameDue()
        }
    }

    func session(_: WatchG7Session, didAdoptPeripheral identifier: UUID?) {
        DispatchQueue.main.async {
            self.setPeripheralIdentifier(identifier)
            if let identifier { WatchG7SlotKey.record(peripheral: identifier) }
        }
    }

    func session(_: WatchG7Session, log line: String) {
        DispatchQueue.main.async {
            self.appendLog(line)
            self.notePairingStep(line)
        }
    }

    // MARK: - Pairing in front

    @ObservationIgnored private var pairingKeepAlive: SensorPairingKeepAlive?

    /// A pairing needs Trio on the screen for the system's Bluetooth pairing request; the watch dims within seconds
    /// and the sensor drops the link a second after asking (2026-10-22: 05:00, and again until the watch was held
    /// up). As untethered mode does, Trio is kept in front for up to 10 minutes once a pairing starts while it is
    /// open, and the wrist feels the request coming. Matched on the kit's log lines, as untethered mode does.
    private func notePairingStep(_ line: String) {
        if line.contains("Running the certificate exchange")
            || line.contains("Pairing: running the key exchange")
        {
            keepInFrontForPairing()
        } else if line.contains("expect the system pairing prompt") {
            // the wrist feels the request coming only when it can show: behind the watch face the notice buzzes
            // instead (6 November, 19:16: a haptic with only the watch face to see)
            if WKApplication.shared().applicationState == .active {
                WKInterfaceDevice.current().play(.notification)
            } else {
                askToOpenForPairing()
            }
        } else if line.hasPrefix("Bonded") || line.hasPrefix("Already authenticated and bonded") || line.hasPrefix("Reading ") {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.pairingNotificationID])
            guard let keepAlive = pairingKeepAlive else { return }
            pairingKeepAlive = nil
            keepAlive.stop()
            appendLog("Paired: Trio no longer held in front")
        }
    }

    private static let pairingNotificationID = notificationIdentifierPrefix + "openForPairing"
    @ObservationIgnored private var lastPairingAsk: Date?

    /// The system's Bluetooth pairing request only shows with Trio in front. In the background a new sensor's
    /// pairing went round in circles for an hour (29 October, second tester: paired at 15:38, 15:48, 16:13, 16:23 and
    /// refused each time at the next reading) until Trio was opened at 16:33 and the bond went through at once.
    private func askToOpenForPairing(early: Bool = false) {
        guard (lastPairingAsk ?? .distantPast).addingTimeInterval(20 * 60) < Date() else { return }
        lastPairingAsk = Date()
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Open Trio to Pair the Sensor")
        content.body = early
            ? String(
                localized: "Open Trio on the watch now and keep it open until the first reading shows. The sensor pairs within about 5 minutes; accept the Bluetooth pairing request when it appears."
            )
            : String(
                localized: "The watch needs Trio on the screen to finish pairing the new sensor. Open Trio on the watch and keep it in front until the first reading shows."
            )
        content.sound = .default
        // it asks for action: through Focus, as the untethered notices that ask for something (`ActionNotice`)
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: Self.pairingNotificationID,
            content: content,
            trigger: nil
        ))
        ActionNotice.ask(id: Self.pairingNotificationID, content: content)
        appendLog("Pairing: asked to open Trio on the watch")
    }

    /// The watch has no key for the sensor while it reads it itself: the next connection pairs.
    var isPairingDue: Bool {
        isEnabled && !isStandingAside && !hasWatchKey && sensorName != nil
    }

    /// A new sensor or a pairing reset. The sensor connects within its 5-minute cycle, and the system's pairing
    /// request then shows only with Trio in front; asking at the request itself is too late (6 November, 19:11:
    /// new sensor from the iPhone, the pairing ran behind the watch face at 19:15:53, and the sensor dropped the
    /// link in the second the notice came at 19:16:05). So Trio asks now, and stays in front once opened.
    private func pairingBecameDue() {
        guard isPairingDue else { return }
        if WKApplication.shared().applicationState == .active {
            keepInFrontForPairing()
        } else {
            askToOpenForPairing(early: true)
        }
    }

    private func keepInFrontForPairing() {
        guard pairingKeepAlive?.isRunning != true, WKApplication.shared().applicationState == .active else { return }
        let keepAlive = SensorPairingKeepAlive { [weak self] reason in
            self?.appendLog("Pairing screen hold ended (\(reason))")
            self?.pairingKeepAlive = nil
        }
        pairingKeepAlive = keepAlive
        keepAlive.start()
        appendLog("Pairing: keeping Trio in front for up to 10 minutes")
    }

    func session(_: WatchG7Session, didChangeConnection connected: Bool) {
        DispatchQueue.main.async {
            self.isConnected = connected
        }
    }

    func sessionStatusDidChange(_ session: WatchG7Session) {
        let searching = session.isSearchingForSensor
        DispatchQueue.main.async { self.isSearching = searching }
    }
}

/// The sensor holds a single key for the watch display slot, which the reader and untethered mode's G7
/// manager both use. Whoever authenticates with a new key records it here, and the other takes it over
/// at the hand-over instead of pairing again (a pairing costs two sensor windows, about 5 to 10 minutes).
enum WatchG7SlotKey {
    private static let key = "watchG7.slotKey"
    private static let peripheralKey = "watchG7.slotPeripheral"

    static var current: Data? { UserDefaults.standard.data(forKey: key) }

    /// The sensor's Bluetooth handle as the last of the two to connect knew it. Both run in the same app, so
    /// the system gives them the same handle for the same sensor.
    static var peripheral: UUID? {
        UserDefaults.standard.string(forKey: peripheralKey).flatMap(UUID.init(uuidString:))
    }

    static func record(_ sharedKey: Data, peripheral: UUID? = nil) {
        if sharedKey != current { UserDefaults.standard.set(sharedKey, forKey: key) }
        if let peripheral { record(peripheral: peripheral) }
    }

    static func record(peripheral: UUID) {
        guard peripheral != self.peripheral else { return }
        UserDefaults.standard.set(peripheral.uuidString, forKey: peripheralKey)
    }
}
