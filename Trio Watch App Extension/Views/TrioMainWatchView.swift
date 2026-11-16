import Charts
import SwiftUI
import WatchKit

struct TrioMainWatchView: View {
    @Environment(\.scenePhase) private var scenePhase
    /// Extended Untethered Mode shows its minimal screen on each wrist raise until tapped.
    @State private var showsFullApp = false
    /// Since when Trio is inactive (wrist turned, a notification); 20 s of it bring the minimal screen back.
    @State private var glanceInactiveSince: Date?
    @Environment(\.scenePhase) private var glanceScenePhase
    @State private var state = WatchState.shared
    @State private var untethered = UntetheredWatchManager.shared

    // Pages in order: bubble, chart, devices (pump and sensor lifetime), alarm snooze, untethered mode's status page
    // (start, hand back, history, the log), the watch's own G7 reader (its switch), and last, while it loops, the
    // watch's own loop status.
    private let devicesPage = 2
    private let snoozePage = 3
    /// Untethered mode off on the phone: no status page, but a session still running keeps it.
    private var showsUntethered: Bool { state.untetheredMode || untethered.isActive }
    private var statusPage: Int { snoozePage + 1 }
    /// The watch's own loop status, while it loops.
    private var watchSensorPage: Int { (showsUntethered ? statusPage : snoozePage) + 1 }
    /// Last, while it loops.
    private var loopPage: Int? { untethered.isActive ? watchSensorPage + 1 : nil }
    private var lastPage: Int { loopPage ?? watchSensorPage }

    /// While the watch runs the pod and the sensor, the Devices page shows them as the watch sees them.
    private var ownDevices: WatchOwnDevices? {
        guard untethered.isActive else { return nil }
        return WatchOwnDevices(
            reservoir: watchPumpReservoir(untethered.pumpManager) ?? untethered.data.reservoir,
            expiresAt: watchPumpExpiresAt(untethered.pumpManager),
            activatedAt: watchPumpActivatedAt(untethered.pumpManager),
            sensorExpiresAt: watchCGMExpiresAt(untethered.cgmManager)
        )
    }

    // misc
    @State private var currentPage: Int = 0
    /// Scrubbing the chart with the crown (see GlucoseChartView).
    @State private var isScrubbingChart = false
    @State private var chartScrubSteps = 0.0
    @State private var rotationDegrees: Double = 0.0
    @State private var showingTempTargetSheet = false

    // view visbility
    @State private var showingTreatmentMenuSheet: Bool = false
    @State private var showingOverrideSheet: Bool = false
    // navigation flag for meal bolus combo
    @State private var continueToBolus = false
    @State private var navigationPath = NavigationPath()

    // treatments
    @State private var selectedTreatment: TreatmentOption?

    /// Ticks so staleness shows without new data.
    @State private var now = Date()
    private static let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// The bubble goes stale by reading age.
    private var isReadingDated: Bool {
        guard let newestReading = state.glucoseValues.last?.date else { return isWatchStateDated }
        return now.timeIntervalSince(newestReading) > 6 * 60
    }

    var isWatchStateDated: Bool {
        // If `lastWatchStateUpdate` is nil, treat as "dated"
        guard let lastUpdateTimestamp = state.lastWatchStateUpdate else { return true }
        // Return true if last update older than 5 min, so 1 loop cycle
        return now.timeIntervalSince1970 - lastUpdateTimestamp > 5 * 60
    }

    /// Treatments and IOB/COB rely on the phone's data, unless the watch runs the loop itself.
    private var isPhoneDataUnusable: Bool {
        !untethered.isActive && (isWatchStateDated || isSessionUnreachable)
    }

    var isSessionUnreachable: Bool {
        guard let session = state.session else {
            return true // No session at all => unreachable
        }
        // Return true if not .activated OR not reachable
        return session.activationState != .activated
    }

    // Active adjustment indicator
    private func isAdjustmentActive<T>(for presets: [T], predicate: (T) -> Bool) -> Bool {
        let sortedPresets = presets.sorted { predicate($0) && !predicate($1) }
        return !sortedPresets.isEmpty && sortedPresets.first(where: predicate) != nil
    }

    private var isTempTargetActive: Bool {
        isAdjustmentActive(for: state.tempTargetPresets) { $0.isEnabled }
    }

    private var isOverrideActive: Bool {
        isAdjustmentActive(for: state.overridePresets) { $0.isEnabled }
    }

    private var trioBackgroundColor = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        Group {
            if untethered.isKeptAwake, state.glanceEnabled, !showsFullApp {
                UntetheredGlanceView(state: state, manager: untethered) {
                    // The pages change while the minimal screen shows (a session's loop page comes and goes), and the
                    // full app's own corrections only run while it is on screen: a page that no longer existed opened
                    // as an empty screen with no way out (25 October, second user). A tap opens the untethered page,
                    // with the hand-back, which is what it is usually for.
                    currentPage = showsUntethered ? statusPage : 0
                    showsFullApp = true
                }
            } else {
                fullApp
            }
        }
        .onChange(of: glanceScenePhase) { _, phase in
            // back to the minimal screen once the app has been away for a while, not at every brief inactive moment
            // (a turned wrist, a notification): the way to the hand-back button must not close behind you
            if phase == .background { showsFullApp = false }
            if phase == .active { glanceInactiveSince = nil }
            if phase == .inactive {
                let since = Date()
                glanceInactiveSince = since
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                    if glanceInactiveSince == since { showsFullApp = false }
                }
            }
        }
    }

    private var fullApp: some View {
        NavigationStack(path: $navigationPath) {
            TabView(selection: $currentPage) {
                // Page 1: Current glucose trend in "BG bobble"
                ZStack {
                    // Re-evaluated every 15 s: "stale" and "the watch has a newer
                    // reading" depend on the clock, not only on new data, so the
                    // bubble switches as soon as the reading ages out. Stale by the reading's age, not the
                    // state's: a state the phone sends without a new reading doesn't make an old one fresh.
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        GlucoseTrendView(
                            state: state,
                            rotationDegrees: rotationDegrees,
                            isWatchStateDated: isReadingDated || isSessionUnreachable
                        )
                    }

                    // a pending meal-time reminder: a small alarm clock right of the bubble; a tap shows the time left
                    // and offers to cancel it
                    if state.pendingMealReminderAt != nil {
                        MealReminderButton(state: state)
                            .position(
                                x: WKInterfaceDevice.current().screenBounds.width - 20,
                                y: (WKInterfaceDevice.current().screenBounds.height / 4) - 7 // level with the syncing sign on the left
                            )
                    }

                    if state.showSyncingAnimation {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.primary, Color.tabBar, Color.clear)
                            .symbolEffect(
                                .variableColor.iterative,
                                options: .repeating,
                                value: state.showSyncingAnimation
                            )
                            .position(
                                x: 20,
                                y: (WKInterfaceDevice.current().screenBounds.height / 4) -
                                    7 // Font .body == 14, so half of default size for the SF Symbol image
                            )
                    }
                }.tag(0)

                // Page 2: Glucose chart
                GlucoseChartView(
                    state: state,
                    glucoseValues: state.glucoseValues,
                    isScrubbing: $isScrubbingChart,
                    scrubSteps: $chartScrubSteps
                )
                .tag(1)

                // Page 3: pump and sensor lifetime (EJM0/Trio's Devices page, Elias Maurer)
                PeripheralsView(
                    state: state,
                    isWatchStateDated: isWatchStateDated || isSessionUnreachable,
                    own: ownDevices
                )
                .tag(devicesPage)

                // Page 4: alarm snooze (nightscout/Trio#1576, t1dude)
                AlarmSnoozeView(state: state)
                    .tag(snoozePage)

                if showsUntethered {
                    UntetheredStatusView(manager: untethered).tag(statusPage)
                }
                // the watch reading the G7 itself, its switch and log
                WatchG7View()
                    .tag(watchSensorPage)

                // Last, while it loops: the watch's own loop status
                if let loopPage {
                    UntetheredLoopStatusView(manager: untethered).tag(loopPage)
                }
            }
            .onChange(of: untethered.isActive) { _, isActive in
                // to the status page as a session starts, and from the loop page to it as the session ends
                if isActive || currentPage == watchSensorPage + 1 { currentPage = statusPage }
            }
            // the pairing note is on the status page
            .onChange(of: untethered.isPairingSensor) { _, isPairing in
                if isPairing { currentPage = statusPage }
            }
            // the loop page goes with the session; stay on the status page, not on none
            .onChange(of: lastPage) { _, _ in
                if currentPage > lastPage { currentPage = lastPage }
            }
            .onChange(of: showsUntethered) { _, _ in
                if currentPage > lastPage { currentPage = lastPage }
            }
            .onAppear {
                // a page left over from before the minimal screen, or from another set of pages, shows nothing
                if currentPage < 0 || currentPage > lastPage { currentPage = 0 }
                /// Hard reset variables when main view appears
                /// Reset `bolusAmount` and `recommendedBolus` to ensure no stale / old value is set when user opens bolus input or meal combo the next time.
                state.bolusAmount = 0
                state.recommendedBolus = 0
            }
            .background(trioBackgroundColor)
            .tabViewStyle(.verticalPage)
            .digitalCrownRotation($currentPage.doubleBinding(), from: 0, through: Double(lastPage), by: 1)
            .modifier(ChartScrubEnd(isScrubbing: $isScrubbingChart, scrubSteps: $chartScrubSteps, currentPage: currentPage))
            .onChange(of: state.trend) { _, newTrend in
                withAnimation {
                    updateRotation(for: newTrend)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    VStack {
                        Image(systemName: "syringe.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.insulin)

                        Text(isPhoneDataUnusable ? "--" : state.iob ?? "--")
                            .foregroundStyle(isWatchStateDated ? Color.secondary : Color.white)
                            .frame(alignment: .leading)
                            .minimumScaleFactor(0.5)
                    }.font(.caption2)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    VStack {
                        Image(systemName: "fork.knife")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.orange)

                        Text(isPhoneDataUnusable ? "--" : state.cob ?? "--")
                            .foregroundStyle(isPhoneDataUnusable ? Color.secondary : Color.white)
                            .frame(alignment: .trailing)
                            .minimumScaleFactor(0.5)
                    }.font(.caption2)
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    if currentPage == 0 {
                        // treatments, overrides and temp targets on the first page only; the chart gets the room
                        Button {
                            showingOverrideSheet = true
                        } label: {
                            Image(systemName: "clock.arrow.2.circlepath")
                                .foregroundStyle(Color.primary, isOverrideActive ? Color.primary : Color.purple)
                        }
                        .tint(isOverrideActive ? Color.purple : nil)
                        .disabled(isPhoneDataUnusable)

                        // while the watch's pump delivers a bolus, the button stops it
                        Button {
                            if untethered.isBolusing {
                                untethered.cancelBolus()
                            } else {
                                showingTreatmentMenuSheet = true
                            }
                        } label: {
                            Image(systemName: untethered.isBolusing ? "square.fill" : "plus")
                                .foregroundStyle(Color.bgDarkerDarkBlue)
                        }
                        .controlSize(.large)
                        .buttonStyle(WatchOSButtonStyle(deviceType: state.deviceType))
                        .overlay {
                            if untethered.isBolusing { BolusProgressRing(window: untethered.bolusWindow) }
                        }
                        .disabled(!untethered.isBolusing && isPhoneDataUnusable)

                        Button {
                            showingTempTargetSheet = true
                        } label: {
                            Image(systemName: "target")
                                .foregroundStyle(isTempTargetActive ? Color.primary : Color.loopGreen.opacity(0.75))
                        }
                        .tint(isTempTargetActive ? Color.loopGreen.opacity(0.75) : nil)
                        .disabled(isPhoneDataUnusable)
                    }
                }
            }
            .fullScreenCover(isPresented: $showingTreatmentMenuSheet) {
                TreatmentMenuView(deviceType: state.deviceType, selectedTreatment: $selectedTreatment) {
                    handleTreatmentSelection()
                }
                .onAppear {
                    // reset the conditional navigation flag when opening
                    continueToBolus = false
                }
            }
            .sheet(isPresented: $showingOverrideSheet) {
                OverridePresetsView(
                    state: state,
                    overridePresets: state.overridePresets
                ) {
                    showingOverrideSheet = false
                    navigationPath.append(NavigationDestinations.acknowledgmentPending)
                }
            }
            .sheet(isPresented: $showingTempTargetSheet) {
                TempTargetPresetsView(
                    state: state,
                    tempTargetPresets: state.tempTargetPresets
                ) {
                    showingTempTargetSheet = false
                    navigationPath.append(NavigationDestinations.acknowledgmentPending)
                }
            }
            .navigationDestination(for: NavigationDestinations.self) { destination in
                switch destination {
                case .acknowledgmentPending:
                    AcknowledgementPendingView(
                        navigationPath: $navigationPath,
                        state: state,
                        shouldNavigateToRoot: $state.shouldNavigateToRoot
                    )
                case .carbsInput:
                    CarbsInputView(
                        navigationPath: $navigationPath,
                        state: state,
                        continueToBolus: continueToBolus
                    )
                case .bolusInput:
                    BolusInputView(
                        navigationPath: $navigationPath,
                        state: state
                    )
                case .bolusConfirm:
                    BolusConfirmationView(
                        navigationPath: $navigationPath,
                        state: state,
                        bolusAmount: $state.bolusAmount,
                        confirmationProgress: $state.confirmationProgress
                    )
                }
            }
            .onChange(of: navigationPath) { _, newPath in
                if newPath.isEmpty {
                    // Reset conditional view navigation when returning to root view
                    continueToBolus = false
                    // Back on the main screen, so no entry is in progress
                    state.clearEntry()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { now = Date() }
                // An entry left for more than 2 min (wrist down, app in the background) is
                // cleared and the input screens are closed, so a stale amount can't be confirmed
                if newPhase == .active, state.expireStaleEntry() {
                    navigationPath = NavigationPath()
                }
            }
        }
        .ignoresSafeArea()
        .onReceive(Self.ticker) { now = $0 }
    }

    private func updateRotation(for trend: String?) {
        switch trend {
        case "DoubleUp",
             "SingleUp":
            rotationDegrees = -90
        case "FortyFiveUp":
            rotationDegrees = -45
        case "Flat":
            rotationDegrees = 0
        case "FortyFiveDown":
            rotationDegrees = 45
        case "DoubleDown",
             "SingleDown":
            rotationDegrees = 90
        default:
            rotationDegrees = 0
        }
    }

    private func handleTreatmentSelection() {
        showingTreatmentMenuSheet = false // Dismiss the sheet

        guard let treatment = selectedTreatment else { return }

        switch treatment {
        case .meal:
            navigationPath.append(NavigationDestinations.carbsInput)
        case .bolus:
            // Reset carbs amount when directly going to bolus input
            state.carbsAmount = 0
            navigationPath.append(NavigationDestinations.bolusInput)
        case .mealBolusCombo:
            continueToBolus = true // Explicitely set subsequent view navigation
            navigationPath.append(NavigationDestinations.carbsInput)
        }
    }
}

#Preview {
    TrioMainWatchView()
}

/// Ends the chart's scrubbing (GlucoseChartView), which then hands the crown back to the pages: by turning the
/// crown back past now, after 10 seconds without a turn, or on leaving the chart page. A tap on the chart ends it too.
struct ChartScrubEnd: ViewModifier {
    @Binding var isScrubbing: Bool
    @Binding var scrubSteps: Double
    let currentPage: Int

    func body(content: Content) -> some View {
        content
            .onChange(of: scrubSteps) { _, steps in
                if isScrubbing, steps < 0 { stop() }
            }
            .onChange(of: currentPage) { _, page in
                if page != 1, isScrubbing { stop() }
            }
            // restarts with every turn; 10 s still ends it
            .task(id: isScrubbing ? scrubSteps : -2) {
                guard isScrubbing else { return }
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled, isScrubbing { stop() }
            }
    }

    private func stop() {
        withAnimation { isScrubbing = false }
        scrubSteps = 0
    }
}

/// The pending meal-time reminder on the first page, the phone's or the watch's own: a small alarm clock right of the
/// bubble, gone once it has rung. A tap shows how long until it rings and asks whether to cancel it, so a brush of
/// the screen cancels nothing.
struct MealReminderButton: View {
    let state: WatchState
    @State private var showsReminder = false
    @State private var shownAt = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            if let fireAt = state.pendingMealReminderAt, fireAt > context.date {
                Button {
                    shownAt = Date()
                    showsReminder = true
                } label: {
                    Image(systemName: "alarm.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.orange)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(until: fireAt, now: context.date))
            }
        }
        .confirmationDialog(
            state.pendingMealReminderAt.map { label(until: $0, now: shownAt) }
                ?? String(localized: "Meal-time reminder", comment: "Watch: the pending meal-time reminder"),
            isPresented: $showsReminder,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Cancel Reminder", comment: "Watch: cancel the pending meal-time reminder"), role: .destructive) {
                state.cancelMealTimeReminder()
            }
            Button(String(localized: "Keep", comment: "Watch: keep the pending meal-time reminder"), role: .cancel) {}
        }
    }

    private func label(until fireAt: Date, now: Date) -> String {
        let minutes = Int((fireAt.timeIntervalSince(now) / 60).rounded(.up))
        return minutes <= 1
            ? String(localized: "Meal-time reminder in 1 min", comment: "Watch: meal-time reminder countdown")
            : String(localized: "Meal-time reminder in \(minutes) min", comment: "Watch: meal-time reminder countdown")
    }
}
