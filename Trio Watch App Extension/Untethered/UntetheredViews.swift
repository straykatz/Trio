import SwiftUI
import WatchConnectivity
import WatchKit

extension Color {
    /// Untethered watch mode, as on the phone.
    static let untethered = Color(red: 0x33 / 255, green: 0xE3 / 255, blue: 0xFF / 255)
}

/// The landing page while untethered: what the watch is doing, and the ways to stop it. Otherwise the
/// place to start it from the wrist.
struct UntetheredStatusView: View {
    let manager: UntetheredWatchManager
    @State private var confirmEnd = false
    /// The watch's log (the G7 reader's details), always at hand here.
    @State private var showLog = false
    @State private var confirmStartWithoutPhone = false
    @State private var phoneUnreachable = false
    @State private var confirmStop = false
    @State private var confirmDeactivate = false
    @State private var confirmDiscard = false
    @State private var confirmPairAgain = false
    @State private var isDeactivating = false
    @State private var deactivateError: String?

    private var data: UntetheredWatchData { manager.data }
    private var phase: UntetheredSession.Phase { data.session.phase }
    private var unsynced: Int { data.pending.values.reduce(0) { $0 + $1.count } }
    private var isPhoneReachable: Bool { WatchState.shared.isReachable }

    var body: some View {
        // by the second while a start is under way, so its seconds count up
        TimelineView(.periodic(from: .now, by: phase == .preparing || phase == .starting ? 1 : 30)) { context in
            ScrollView {
                VStack(spacing: 10) {
                    header(now: context.date)
                    if manager.isPairingSensor {
                        card(tint: .untethered) {
                            Label(
                                "Pairing the sensor: keep Trio open until a glucose value shows. If a Bluetooth pairing request appears, accept it.",
                                systemImage: "sensor.tag.radiowaves.forward"
                            )
                            .font(.footnote)
                        }
                    }
                    if let error = data.lastError ?? (manager.isActive ? data.lastLoopError : nil) {
                        card(tint: .orange) {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                        }
                    }
                    if manager.isActive, let since = manager.readingsFromPhoneSince {
                        card(tint: .orange) {
                            Label(
                                String(
                                    localized: "Readings from iPhone: the watch hasn't read the sensor itself since \((manager.ownReadingAt ?? since).formatted(date: .omitted, time: .shortened)). Without the iPhone there would be no readings."
                                ),
                                systemImage: "iphone"
                            )
                            .font(.footnote)
                        }
                    }
                    if manager.offersSensorPairAgain {
                        // here, not only on the sensor page: where the warning is, and Trio has to stay in front
                        // for the pairing request
                        Button(role: .destructive) { confirmPairAgain = true } label: {
                            Label("Pair Again", systemImage: "arrow.triangle.2.circlepath")
                                .font(.footnote)
                        }
                    }
                    if manager.isActive { tiles }
                    if manager.isActive {
                        // remote commands come through the phone, or as LoopFollow's copy pushed straight to the watch
                        note(
                            "Remote boluses and meals reach the watch through the iPhone while it is online, or straight from LoopFollow when it sends to the watch. The watch refuses commands sent more than 10 minutes ago."
                        )
                    }
                    if manager.isActive || unsynced > 0 { historyButton }
                    if manager.isActive, let mode = data.grant?.dosingMode { loopModePicker(mode) }
                    alerts(now: context.date)
                    actions
                    // the log, always: also before a start and after a hand-back
                    Button { showLog = true } label: {
                        Label("Log", systemImage: "doc.text")
                            .font(.footnote)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .sheet(isPresented: $showLog) {
            WatchG7DetailsView()
        }
        .confirmationDialog("Pair the watch with the sensor again?", isPresented: $confirmPairAgain) {
            Button("Pair Again", role: .destructive) { manager.pairSensorAgain() }
        }
        .confirmationDialog("Hand the pump back to the phone?", isPresented: $confirmEnd) {
            Button("Hand Back") { manager.end() }
        }
        .confirmationDialog(
            "Start from the phone's copy of \(Int((manager.standingGrantAge ?? 0) / 60)) min ago? Only if the phone is off or out of reach; it stops dosing once it hears from the watch.",
            isPresented: $confirmStartWithoutPhone
        ) {
            Button("Start Without Phone") { manager.startWithoutPhone() }
        }
        .alert("Phone Not Reachable", isPresented: $phoneUnreachable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Bring the phone close and open Trio on it, then hand back again. Use Emergency Stop if it isn't coming back.")
        }
        .confirmationDialog(
            "Stop now? The watch lets go of the pump at once, cancels the temp basal and stops looping until the phone takes over.",
            isPresented: $confirmStop
        ) {
            Button("Emergency Stop", role: .destructive) { manager.emergencyStop() }
        }
        // not a tap: a full turn of the crown, which a brush against the small screen doesn't make
        .sheet(isPresented: $confirmDeactivate) {
            CrownConfirmView(
                title: String(localized: "Deactivate Pod"),
                message: String(
                    localized: "The pod stops delivering insulin and its alarm ends. Remove it, then pair a new pod on the phone."
                ),
                prompt: String(localized: "Turn the crown to deactivate")
            ) {
                isDeactivating = true
                deactivateError = nil
                manager.deactivatePod { error in
                    isDeactivating = false
                    deactivateError = error
                }
            }
        }
        .confirmationDialog(
            "Discard the pod without reaching it? It may keep alarming until you remove it.",
            isPresented: $confirmDiscard
        ) {
            Button("Discard Pod", role: .destructive) {
                deactivateError = nil
                manager.discardPod()
            }
        }
    }

    // MARK: - Header

    private func header(now: Date) -> some View {
        let look = self.look(now: now)
        return HStack(spacing: 10) {
            Image(systemName: look.symbol)
                .font(.title3)
                .foregroundStyle(look.tint)
                .frame(width: 38, height: 38)
                .background(look.tint.opacity(0.2), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(look.title).font(.headline)
                Text(look.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// The phone didn't take the last message, or isn't in reach right now.
    private func phoneSeemsBusy(now: Date) -> Bool {
        // the cached reachability: asked of WatchConnectivity while the screen is drawn, a stall there hangs it (`WCTransfers`)
        !WatchState.shared.isReachable || manager.phoneTroubleAt.map { now.timeIntervalSince($0) < 2 * 60 } ?? false
    }

    private func look(now: Date) -> (symbol: String, tint: Color, title: LocalizedStringKey, subtitle: LocalizedStringKey) {
        switch phase {
        case .active where data.podEnded:
            return ("xmark.circle", .orange, "Pod Deactivated", "The phone pairs the next pod; hand back once it is nearby")
        case .active where manager.handbackRequestedAt.map({ now.timeIntervalSince($0) < 10 * 60 }) ?? false:
            if phoneSeemsBusy(now: now) {
                return ("hourglass", .orange, "Asked iPhone to Take Over",
                        "The iPhone hasn't taken the pump yet. Open Trio on it; the watch keeps looping meanwhile")
            }
            return ("arrow.uturn.backward.circle", .blue, "Asked iPhone to Take Over",
                    "The iPhone takes the pump back as soon as it reaches the pod")
        case .active:
            if let lastLoop = data.lastLoopDate {
                let minutes = max(0, Int(now.timeIntervalSince(lastLoop) / 60))
                return ("applewatch", .untethered, "Watch Mode", "Last loop \(minutes) min ago")
            }
            return ("applewatch", .untethered, "Watch Mode", "Looping on the watch")
        case .preparing,
             .starting:
            let waited = now.timeIntervalSince(manager.phaseSince)
            if data.session.startedWithoutPhone, waited > 30 {
                return ("applewatch.radiowaves.left.and.right", .yellow, "Looking for the Pod…",
                        "The pod hasn't answered yet. Keep the watch near it; it keeps trying")
            }
            if data.session.startedWithoutPhone {
                return ("applewatch.radiowaves.left.and.right", .yellow, "Starting…", "Looking for the pod")
            }
            // the start goes on for up to 90 s while the link comes and goes: shown as it runs, so nobody taps again
            let seconds = Int(waited)
            if waited > 20, phoneSeemsBusy(now: now) {
                return ("hourglass", .orange, "Reaching the iPhone… \(seconds) s",
                        "Keep Trio open here and on the iPhone; the start goes on by itself for up to 1½ minutes")
            }
            if phase == .preparing {
                return ("applewatch.radiowaves.left.and.right", .yellow, "Starting… \(seconds) s",
                        "Agreeing with the iPhone. Keep Trio open; the iPhone doses until the watch has the pump")
            }
            return ("applewatch.radiowaves.left.and.right", .yellow, "Starting… \(seconds) s", "Taking over the pump and sensor")
        case .ending:
            let waited = now.timeIntervalSince(manager.phaseSince)
            if unsynced > 0 {
                return ("arrow.uturn.backward.circle", .blue, "Handing Back…",
                        "Sending the history to the iPhone: \(unsynced) entries left")
            }
            if waited > 30, phoneSeemsBusy(now: now) {
                return ("hourglass", .orange, "iPhone Busy",
                        "The iPhone isn't answering. Open Trio on the iPhone; the watch keeps the pump until it takes it")
            }
            return ("arrow.uturn.backward.circle", .blue, "Handing Back…", "Waiting for the phone to take the pump")
        case .idle:
            if unsynced > 0 {
                return ("arrow.triangle.2.circlepath", .blue, "Syncing History", "\(unsynced) entries on the way to the phone")
            }
            return ("applewatch.slash", .secondary, "Phone in Charge", "The watch can take over pump and sensor")
        }
    }

    // MARK: - Figures

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            tile("Basal", systemImage: "chart.bar.fill", tint: .blue, value: (manager.deliveredBasalRate ?? data.lastDetermination?.rate).map {
                String(format: "%.2f U/h", NSDecimalNumber(decimal: $0).doubleValue)
            })
            // above 50 U the pod doesn't measure: the phone's "50+ U" marker
            tile("Reservoir", systemImage: "drop.fill", tint: .blue, value: data.reservoir.map {
                // not `NSDecimalNumber.intValue`: it misreads long fractions such as the fill-based estimate's
                "\($0.formatted(.number.precision(.fractionLength(0)))) U"
            } ?? (data.grant?.reservoir == Decimal(UInt32(0xDEAD_BEEF)) ? "50+ U" : nil))
            tile(
                "Watch Battery",
                systemImage: "battery.75percent",
                tint: (UntetheredWatchManager.batteryPercent ?? 100) < 20 ? .red : .green,
                value: UntetheredWatchManager.batteryPercent.map { "\($0) %" }
            )
        }
    }

    /// The watch's own history, on its own screen: as a page it would trap the pager in its list and shift the pages
    /// after it whenever a session starts or ends. The second row shows the number of records still to sync.
    private var historyButton: some View {
        NavigationLink { UntetheredHistoryView(manager: manager) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Label("History", systemImage: "list.bullet")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("\(unsynced)")
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func loopModePicker(_ mode: DosingMode) -> some View {
        NavigationLink {
            UntetheredLoopModeSelectionView(manager: manager)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Label("Loop Mode", systemImage: mode.icon)
                        .font(.caption2)
                        .foregroundStyle(Color.untethered)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(mode.displayName)
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(data.session.phase != .active)
    }

    private func tile(_ label: LocalizedStringKey, systemImage: String, tint: Color, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(value ?? "--")
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Alerts

    /// The pump's and the sensor's alerts while the watch holds them; scheduled ones once they are due.
    @ViewBuilder private func alerts(now: Date) -> some View {
        let due = manager.isActive ? data.pendingPumpAlerts.filter { ($0.due ?? .distantPast) <= now } : []
        ForEach(due) { alert in
            card(tint: .orange) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(alert.title, systemImage: "bell.fill").font(.footnote.bold())
                    Text(alert.body).font(.caption2).foregroundStyle(.secondary)
                    Button("Acknowledge") { manager.acknowledgePumpAlert(alert) }
                        .tint(.orange)
                }
            }
        }
    }

    // MARK: - Actions

    /// Checked at the press, not from the last reachability change, which can lag.
    private func whenPhoneReachable(_ action: () -> Void) {
        if WCSession.default.isReachable { action() } else { phoneUnreachable = true }
    }

    @ViewBuilder private var actions: some View {
        if isDeactivating {
            HStack(spacing: 8) {
                ProgressView().frame(width: 20)
                Text("Deactivating the pod…").font(.footnote)
            }
            .padding(.top, 4)
        } else if manager.isBusy {
            HStack(spacing: 8) {
                ProgressView().frame(width: 20)
                Text(phase == .ending ? "Handing back…" : "Starting…").font(.footnote)
            }
            .padding(.top, 4)
        } else if phase == .idle, manager.isMeetingPod {
            // no Start while the watch looks for a new pod: a start then made a second manager search beside it, which
            // didn't find the pod in 2 minutes (3 November, 18:04:55; the watch's own search found it in 9 s at 18:11)
            HStack(spacing: 8) {
                ProgressView().frame(width: 20)
                Text("Looking for the pod…").font(.footnote)
            }
            .padding(.top, 4)
        } else {
            switch phase {
            case .idle:
                Button { manager.requestStart() } label: {
                    Label("Start Watch Mode", systemImage: "applewatch")
                }
                .buttonStyle(.borderedProminent)
                .tint(.untethered)
                .disabled(!isPhoneReachable || manager.versionMismatch != nil)
                if let mismatch = manager.versionMismatch {
                    note(Text(mismatch))
                } else if !isPhoneReachable {
                    note("Starts with the phone nearby and Trio open on it.")
                    // without a copy the note below says why
                    if WatchState.shared.allowUntetheredStartWithoutPhone, manager.startWithoutPhoneUnavailable == nil {
                        Button { confirmStartWithoutPhone = true } label: {
                            Label("Start Without Phone", systemImage: "iphone.slash")
                        }
                        .tint(.untethered)
                    }
                }
                copyNote
            case .active where data.podEnded:
                Button { whenPhoneReachable { manager.end() } } label: {
                    Label("Hand Back", systemImage: "iphone")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                if !isPhoneReachable {
                    note("Hands back by itself once the phone is nearby.")
                }
            case .active:
                Button { whenPhoneReachable { confirmEnd = true } } label: {
                    Label("Hand Back", systemImage: "iphone")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                if manager.isBolusing {
                    note("A bolus is running. It goes on after the hand-back; to stop it, use the treatment button first.")
                }
                stopButton
                // an alarming pod goes quiet when deactivated; the phone pairs the next one
                if let deactivateError {
                    card(tint: .orange) {
                        Label(deactivateError, systemImage: "exclamationmark.triangle.fill").font(.footnote)
                    }
                    Button(role: .destructive) { confirmDiscard = true } label: {
                        Label("Discard Pod", systemImage: "trash")
                    }
                    .tint(.red)
                } else {
                    Button(role: .destructive) { confirmDeactivate = true } label: {
                        Label("Deactivate Pod", systemImage: "xmark.circle")
                    }
                    .tint(.orange)
                }
            case .ending:
                stopButton
            case .preparing,
                 .starting:
                EmptyView()
            }
        }
    }

    private var stopButton: some View {
        Button(role: .destructive) { confirmStop = true } label: {
            Label("Emergency Stop", systemImage: "stop.circle")
        }
        .tint(.red)
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        note(Text(text))
    }

    /// Whether a copy from the phone is stored to start without it, and how old, or why not.
    @ViewBuilder private var copyNote: some View {
        if WatchState.shared.allowUntetheredStartWithoutPhone {
            if manager.standingGrantAge != nil, manager.isMeetingPod {
                Label("Looking for the pod…", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if manager.standingGrantAge != nil, manager.standingGrantPodUnknown {
                Label {
                    Text("The watch doesn't know the pod yet (after a pod change, or after Trio was installed again here), so it can't take over by itself. Keep Trio open here with the iPhone nearby; it looks for the pod.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption2)
                .foregroundStyle(.orange)
            } else if let age = manager.standingGrantAge {
                Label(
                    "The iPhone's copy of \(Int(age / 60)) min ago is ready to start without it",
                    systemImage: "checkmark.circle"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Label {
                    Text("Can't start without the iPhone: \(manager.startWithoutPhoneUnavailable ?? "")")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption2)
                .foregroundStyle(.orange)
            }
        }
    }

    private func note(_ text: Text) -> some View {
        text
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private func card<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Glucose, meals and insulin of the last hours, from the watch's own records. Glucose and carbs can be
/// deleted, and a meter's BG added while untethered; both reach the phone with the rest of the history.
struct UntetheredHistoryView: View {
    let manager: UntetheredWatchManager
    /// Picked in the bottom bar.
    @State private var kind = Kind.glucose

    enum Kind: CaseIterable {
        case glucose
        case carbs
        case insulin

        var symbol: String {
            switch self {
            case .glucose: return "drop.fill"
            case .carbs: return "fork.knife"
            case .insulin: return "syringe.fill"
            }
        }

        var color: Color {
            switch self {
            case .glucose: return .green
            case .carbs: return .orange
            case .insulin: return .blue
            }
        }
    }

    private var since: Date { Date().addingTimeInterval(-6 * 60 * 60) }

    var body: some View {
        List {
            switch kind {
            case .glucose: glucoseRows
            case .carbs: carbRows
            case .insulin: insulinRows
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                ForEach(Kind.allCases, id: \.self) { kind in
                    Button { self.kind = kind } label: {
                        Image(systemName: kind.symbol)
                            .foregroundStyle(self.kind == kind ? Color.primary : kind.color)
                    }
                    .tint(self.kind == kind ? kind.color : nil)
                }
            }
        }
    }

    @ViewBuilder private var glucoseRows: some View {
        let units = manager.data.grant?.units ?? .mgdL
        let readings = manager.data.glucose.filter { $0.dateString >= since }.sorted { $0.dateString > $1.dateString }
        if manager.isActive {
            NavigationLink { ManualGlucoseEntryView(manager: manager) } label: {
                Label("Add BG", systemImage: "plus.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        if readings.isEmpty { Text("No glucose").foregroundStyle(.secondary) }
        ForEach(readings, id: \.id) { reading in
            let value = reading.glucose ?? reading.sgv ?? reading.mbg ?? 0
            let shown = Text(units == .mgdL ? "\(value)" : Decimal(value).formatted(for: .mmolL))
            // a manual BG is marked, as it isn't a sensor reading
            row(reading.dateString, reading.mbg != nil ? Text(Image(systemName: "drop.circle")) + Text(" ") + shown : shown)
                .swipeActions {
                    Button("Delete", role: .destructive) { manager.deleteGlucose(id: reading.id) }
                }
        }
    }

    @ViewBuilder private var carbRows: some View {
        let entries = manager.data.carbs.filter { ($0.actualDate ?? $0.createdAt) >= since && !($0.isFPU ?? false) }
            .sorted { ($0.actualDate ?? $0.createdAt) > ($1.actualDate ?? $1.createdAt) }
        if entries.isEmpty { Text("No carbs").foregroundStyle(.secondary) }
        ForEach(entries, id: \.self) { entry in
            row(
                entry.actualDate ?? entry.createdAt,
                Text("\(entry.carbs.formatted(.number.precision(.fractionLength(0)))) g").foregroundStyle(.orange)
            )
            .swipeActions {
                if let id = entry.id {
                    Button("Delete", role: .destructive) { manager.deleteCarbs(id: id) }
                }
            }
        }
    }

    @ViewBuilder private var insulinRows: some View {
        let events = manager.data.pumpHistory
            .filter { [.bolus, .smb, .tempBasal, .pumpSuspend, .pumpResume].contains($0.type) && $0.timestamp >= since }
            .sorted { $0.timestamp > $1.timestamp }
        if events.isEmpty { Text("No insulin").foregroundStyle(.secondary) }
        ForEach(events, id: \.id) { event in
            row(event.timestamp, Text(describe(event)).foregroundStyle(.blue))
        }
    }

    private func row(_ date: Date, _ value: Text) -> some View {
        HStack {
            Text(date, style: .time).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            value
        }
    }

    private func describe(_ event: PumpHistoryEvent) -> String {
        switch event.type {
        case .bolus,
             .smb:
            let units = String(format: "%.2f U", NSDecimalNumber(decimal: event.amount ?? 0).doubleValue)
            return (event.isSMB ?? false) ? "SMB " + units : "Bolus " + units
        case .tempBasal:
            return String(format: "Temp %.2f U/h", NSDecimalNumber(decimal: event.rate ?? 0).doubleValue)
        case .pumpSuspend: return String(localized: "Suspended")
        case .pumpResume: return String(localized: "Resumed")
        default: return event.type.rawValue
        }
    }
}

/// The running bolus as an edge around the treatment button that fills as it is delivered; by the clock, as the
/// pump itself counts a bolus done.
struct BolusProgressRing: View {
    let window: DateInterval?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let progress = window.map { min(1, max(0, context.date.timeIntervalSince($0.start) / max($0.duration, 1))) } ?? 0
            ZStack {
                Circle().stroke(Color.tabBar.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.tabBar, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)
            }
            .padding(-5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Loop status

private struct UntetheredLoopModeSelectionView: View {
    let manager: UntetheredWatchManager
    @Environment(\.dismiss) private var dismiss

    private var currentMode: DosingMode? { manager.data.grant?.dosingMode }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Loop Mode")
                    .font(.headline)
                    .padding(.bottom, 2)
                ForEach(DosingMode.userSelectable) { mode in
                    Button {
                        manager.setDosingMode(mode)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Label(mode.displayName, systemImage: mode.icon)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.untethered)
                                Spacer(minLength: 0)
                                if mode == currentMode {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(Color.untethered)
                                }
                            }
                            Text(mode.miniHint)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(8)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.data.session.phase != .active)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Loop Mode")
    }
}

/// The phone's Loop Status sheet, from the watch's own loop: how recent it is, oref's values in
/// pills, and its reasoning.
struct UntetheredLoopStatusView: View {
    let manager: UntetheredWatchManager

    private var data: UntetheredWatchData { manager.data }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current Loop Status").font(.headline)
                    let status = status(now: context.date)
                    Text(status.title)
                        .font(.footnote.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(status.color == .secondary ? Color.white : Color.bgDarkerDarkBlue)
                        .background(status.color, in: Capsule())
                    if let error = data.lastLoopError {
                        Text(error).font(.caption2).foregroundStyle(Color.loopRed)
                    }
                    if let determination = data.lastDetermination {
                        Text("Latest Raw Algorithm Output").font(.footnote.bold()).padding(.top, 6)
                        PillFlow(spacing: 4) {
                            ForEach(tags(determination), id: \.self) { AlgorithmPill(tag: $0) }
                        }
                        Text("Current Algorithm Reasoning").font(.footnote.bold()).padding(.top, 6)
                        Text(determination.reasonConclusion.prefix(1).uppercased() + determination.reasonConclusion.dropFirst())
                            .font(.caption2)
                    } else {
                        Text("No recent oref algorithm determination.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
        }
    }

    /// As the phone's sheet: enacted within 5 minutes green, within 10 yellow, then red.
    private func status(now: Date) -> (title: String, color: Color) {
        guard let deliverAt = data.lastDetermination?.deliverAt else {
            return (String(localized: "Not looping."), .secondary)
        }
        let isOpenLoop = data.grant?.dosingMode.automation == .off
        let age = now.timeIntervalSince(data.lastLoopDate ?? deliverAt) - 30
        let color: Color = age <= 5 * 60 ? .loopGreen : age <= 10 * 60 ? .loopYellow : .loopRed
        guard deliverAt >= now.addingTimeInterval(-5 * 60) else {
            let minutes = Int((now.timeIntervalSince(deliverAt) / 60).rounded())
            return (
                isOpenLoop
                    ? String(localized: "Trio has not run in \(minutes) minutes.")
                    : String(localized: "Trio has not looped in \(minutes) minutes."),
                color
            )
        }
        let time = deliverAt.formatted(date: .omitted, time: .shortened)
        return (isOpenLoop ? String(localized: "Determined at \(time)") : String(localized: "Enacted at \(time)"), color)
    }

    private func tags(_ determination: Determination) -> [String] {
        let isMmolL = data.grant?.units == .mmolL
        var tags = determination.reasonParts.map { AlgorithmPill.formatted($0, isMmolL: isMmolL) }
        if data.grant?.smoothGlucose == true { tags.append("Smoothing: On") }
        if let tdd = data.tddRows.max(by: { $0.date < $1.date })?.total ?? data.grant?.tdd.currentTDD, tdd != 0 {
            tags
                .append(
                    "TDD: \(NSDecimalNumber(decimal: tdd).doubleValue.formatted(.number.precision(.fractionLength(0 ... 1))))"
                )
        }
        return tags
    }
}

/// One of the phone's `TagCloudView` pills, in its colors.
private struct AlgorithmPill: View {
    let tag: String

    private var color: Color {
        if tag.contains("SMB Delivery Ratio:") { return .UAM }
        if tag.contains("Bolus") { return .green }
        if [
            "TDD:",
            "tdd_factor",
            "Sigmoid function",
            "Logarithmic formula",
            "AF:",
            "Autosens/Dynamic Limit:",
            "Dynamic ISF/CR",
            "Basal ratio",
            "SMB Ratio"
        ].contains(where: tag.contains) { return .ZT }
        if tag.contains("Middleware:") { return .red }
        if tag.contains("Smoothing: On") { return .gray }
        return .insulin
    }

    var body: some View {
        Text(tag)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1.5))
    }

    private static let glucoseNames = [
        "ISF",
        "Target",
        "Dev",
        "BGI",
        "minPredBG",
        "minGuardBG",
        "IOBpredBG",
        "COBpredBG",
        "UAMpredBG"
    ]

    /// As `TagCloudView.formatGlucoseTags`: "minPredBG 150" reads "minPredBG: 150", and glucose values go to mmol/L.
    static func formatted(_ tag: String, isMmolL: Bool) -> String {
        guard let name = glucoseNames.first(where: { tag.hasPrefix($0 + ":") || tag.hasPrefix($0 + " ") }) else { return tag }
        var values = String(tag.dropFirst(name.count)).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        if isMmolL, let regex = try? NSRegularExpression(pattern: "-?\\d+\\.?\\d*") {
            for match in regex.matches(in: values, range: NSRange(values.startIndex..., in: values)).reversed() {
                guard let range = Range(match.range, in: values),
                      let mgdl = Decimal(string: String(values[range])) else { continue }
                values.replaceSubrange(range, with: mgdl.asMmolL.description)
            }
        }
        return "\(name): \(values)"
    }
}

/// Lays its pills out in rows, wrapping like the phone's tag cloud.
private struct PillFlow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map { $0.map(\.height).max() ?? 0 }.reduce(0) { $0 + $1 } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map { $0.reduce(0) { $0 + $1.width } }.max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var index = 0
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for size in row {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += (row.map(\.height).max() ?? 0) + spacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [[CGSize]] {
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(size)
            x += size.width + spacing
        }
        return rows
    }
}

/// Extended Untethered Mode's screen: raising the wrist returns to Trio while its workout runs, so it shows this, dark
/// and calm, after the glance of Jeremy Barnum's Sport Mode for Loop (LoopKit/Loop#2545). The phone arranges it (`WatchGlanceLayout`): a row above, the middle, a row
/// below. A tap opens the full app.
struct UntetheredGlanceView: View {
    let state: WatchState
    let manager: UntetheredWatchManager
    let onOpen: () -> Void

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private static let dim = Color(white: 0.55)

    var body: some View {
        // A button over the whole screen rather than a tap gesture on the stack: on 25 October taps on the minimal
        // screen did nothing, and the hand-back had to come from the phone. A long press opens it too, and the hint
        // at the bottom says how.
        // The button sized its content to fit, not to the screen: the middle got no more than its smallest size, and
        // the chart showed as a flat strip with a third of the screen empty below (17 November, screenshot). The
        // screen's size, given outright, lets the middle take the room left.
        GeometryReader { screen in
            Button(action: open) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(spacing: 4) {
                        row(0, now: context.date)
                        middle(now: context.date, height: middleHeight(screen: screen.size.height))
                        row(1, now: context.date)
                        if !isLuminanceReduced {
                            Text("Tap for Trio", comment: "Hint at the bottom of Extended Watch Mode's minimal screen")
                                .font(.system(size: 10))
                                .foregroundStyle(Self.dim)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 2)
                }
                .frame(width: screen.size.width, height: screen.size.height)
                .background(Color.black)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in open() })
            .opacity(isLuminanceReduced ? 0.75 : 1)
        }
    }

    private func open() {
        Task { await WatchLogger.shared.log("⌚️ Untethered: minimal screen tapped, opening the full app", force: true) }
        onOpen()
    }

    // MARK: - Layout

    private static let rowHeight: CGFloat = 28
    private static let hintHeight: CGFloat = 12
    /// The large glucose with its time and delta, above the chart.
    private static let glucoseHeaderHeight: CGFloat = 32

    private func rowHeight(_ index: Int) -> CGFloat {
        state.glanceLayout.row(index).allSatisfy { $0.item == nil } ? 0 : Self.rowHeight
    }

    /// Rows, header and hint kept small: the room goes to the chart (22 November).
    /// The middle's height worked out from the screen's, not left to the layout: given only the room left, the chart
    /// still came out as a thin strip (17 and 22 November, Extended Mode).
    private func middleHeight(screen: CGFloat) -> CGFloat {
        let hint = isLuminanceReduced ? 0 : Self.hintHeight
        let gaps: CGFloat = isLuminanceReduced ? 2 : 3
        return max(40, screen - rowHeight(0) - rowHeight(1) - hint - gaps * 4 - 2)
    }

    /// Each element as wide as its slots.
    private func row(_ index: Int, now: Date) -> some View {
        let elements = state.glanceLayout.row(index)
        let slots = WatchGlanceLayout.rows[index].count
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(elements, id: \.slot) { element in
                    let width = geometry.size.width * CGFloat(element.item?.width ?? 1) / CGFloat(slots)
                    Group {
                        if let item = element.item { cell(item, now: now) } else { Color.clear }
                    }
                    .frame(width: width)
                }
            }
        }
        .frame(height: rowHeight(index))
    }

    @ViewBuilder private func middle(now: Date, height: CGFloat) -> some View {
        switch state.glanceLayout.slots[WatchGlanceLayout.center] {
        case .glucoseLarge:
            glucose(size: 58, now: now)
                .frame(height: height)
        case .glucoseChart:
            VStack(spacing: 0) {
                glucose(size: 24, now: now)
                    .frame(height: Self.glucoseHeaderHeight)
                chart
                    .frame(height: max(30, height - Self.glucoseHeaderHeight))
            }
            .frame(height: height)
        case .chart:
            chart
                .frame(height: height)
        default:
            Color.clear
                .frame(height: height)
        }
    }

    private var chart: some View {
        // the glance only shows the chart: no scrubbing there (this fork's chart takes the crown by bindings)
        GlucoseChartView(
            state: state,
            glucoseValues: state.glucoseValues,
            isScrubbing: .constant(false),
            scrubSteps: .constant(0)
        )
            .allowsHitTesting(false)
    }

    // MARK: - Elements

    private var newestReading: Date? { state.glucoseValues.last?.date }

    private func isStale(_ now: Date) -> Bool {
        newestReading.map { now.timeIntervalSince($0) > 6 * 60 } ?? true
    }

    private var arrow: String { WatchG7Reader.shared.arrow(for: state.trend) }

    private func glucose(size: CGFloat, now: Date) -> some View {
        let stale = isStale(now)
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(state.currentGlucose)
                    .font(.system(size: size, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(arrow).font(.system(size: size * 0.45, weight: .semibold))
            }
            .foregroundStyle(stale ? Self.dim : state.currentGlucoseColorString.toColor())
            // the reading's time, then its delta, or how old it is once stale
            if let newestReading {
                HStack(spacing: 6) {
                    Text(newestReading, format: .dateTime.hour().minute()).foregroundStyle(Self.dim)
                    if stale {
                        Text("\(minutes(since: newestReading, now: now)) min ago").foregroundStyle(Color.loopYellow)
                    } else if let delta = state.delta {
                        Text(delta).foregroundStyle(Self.dim)
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
            }
        }
    }

    /// A combined element shows its parts side by side, each with its own label.
    private func cell(_ item: WatchGlanceItem, now: Date) -> some View {
        HStack(spacing: 2) {
            ForEach(item.parts, id: \.self) { part in
                VStack(spacing: 0) {
                    value(part, now: now)
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    // the small glucose is labelled with its reading's time
                    Group {
                        if part == .glucose, let newestReading {
                            Text(newestReading, format: .dateTime.hour().minute())
                        } else {
                            Text(part.label.uppercased())
                        }
                    }
                    .font(.system(size: 8, weight: .medium))
                    .kerning(0.6)
                    .foregroundStyle(Self.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private func value(_ item: WatchGlanceItem, now: Date) -> some View {
        let data = manager.data
        switch item {
        case .glucose:
            Text("\(state.currentGlucose)\(arrow)")
                .foregroundStyle(isStale(now) ? Self.dim : state.currentGlucoseColorString.toColor())
        case .loop:
            let age = data.lastLoopDate.map { now.timeIntervalSince($0) }
            HStack(spacing: 3) {
                Circle().stroke(loopColor(age), lineWidth: 2).frame(width: 10, height: 10)
                Text(age.map { "\(Int($0 / 60))m" } ?? "--")
            }
        case .iob:
            Text(state.iob ?? "--").foregroundStyle(Color.insulin)
        case .cob:
            Text(state.cob ?? "--").foregroundStyle(Color.orange)
        case .tempBasal:
            let temp = UntetheredAlgorithm.historyTempBasal(data.pumpHistory, now: now)
            Text(temp.duration > 0 ? "\(number(temp.rate, places: 2))" : "--")
        case .eventualGlucose:
            Text(data.lastDetermination?.eventualBG.map { glucoseText($0) } ?? "--")
        case .heartRate:
            HStack(spacing: 2) {
                Image(systemName: "heart.fill").font(.system(size: 11)).foregroundStyle(Color.red)
                Text(manager.heartRate.map { "\(Int($0.rounded()))" } ?? "--")
            }
        case .reservoir:
            // "50+ U" only for the pod's above-50 marker, as the Reservoir tile; unknown is "--"
            Text(data.reservoir.map { "\(number($0, places: 0)) U" }
                ?? (data.grant?.reservoir == Decimal(UInt32(0xDEAD_BEEF)) ? "50+ U" : "--"))
        case .lastReading:
            Text(newestReading.map { "\(minutes(since: $0, now: now))m" } ?? "--")
        case .totalDailyDose:
            Text(data.tddRows.max(by: { $0.date < $1.date }).map { "\(number($0.total, places: 1)) U" } ?? "--")
        case .clock:
            Text(now, format: .dateTime.hour().minute())
        default:
            Text("--")
        }
    }

    /// As the phone's loop ring: within 5 minutes green, within 10 yellow, then red.
    private func loopColor(_ age: TimeInterval?) -> Color {
        guard let age else { return Self.dim }
        return age <= 5 * 60 ? .loopGreen : age <= 10 * 60 ? .loopYellow : .loopRed
    }

    private func minutes(since date: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 60))
    }

    private func glucoseText(_ mgdl: Int) -> String {
        guard manager.data.grant?.units == .mmolL else { return "\(mgdl)" }
        return NSDecimalNumber(decimal: Decimal(mgdl).asMmolL).doubleValue.formatted(.number.precision(.fractionLength(1)))
    }

    private func number(_ value: Decimal, places: Int) -> String {
        NSDecimalNumber(decimal: value).doubleValue.formatted(.number.precision(.fractionLength(0 ... places)))
    }
}

/// A meter's blood glucose, picked with the crown (or − / +) in the phone's units and saved as a manual reading:
/// the loop takes it into account from the next sensor reading on, and the phone files it as a manual entry.
struct ManualGlucoseEntryView: View {
    let manager: UntetheredWatchManager
    @Environment(\.dismiss) private var dismiss
    @State private var value: Double = 0
    @State private var confirmDifference = false

    private var isMmol: Bool { (manager.data.grant?.units ?? .mgdL) == .mmolL }
    /// A meter's range: 40–400 mg/dL (2.2–22.2 mmol/L).
    private var range: ClosedRange<Double> { isMmol ? 2.2 ... 22.2 : 40 ... 400 }
    private var step: Double { isMmol ? 0.1 : 1 }
    /// As the phone's `asMgdL`.
    private var mgdl: Int { isMmol ? Int((value / 0.0555).rounded()) : Int(value.rounded()) }
    private var shown: String { isMmol ? String(format: "%.1f", value) : "\(Int(value.rounded()))" }

    /// The sensor's newest reading, when it's recent enough to compare with.
    private var sensorReading: Int? {
        guard let newest = manager.sensorGlucose.max(by: { $0.dateString < $1.dateString }),
              Date().timeIntervalSince(newest.dateString) < 15 * 60
        else { return nil }
        return newest.glucose ?? newest.sgv
    }

    /// Asked before saving a BG far from the sensor (40 mg/dL or 30 %): a typo here doses insulin.
    private var isFarFromSensor: Bool {
        guard let sensor = sensorReading, sensor > 0 else { return false }
        let difference = abs(mgdl - sensor)
        return difference >= 40 || Double(difference) / Double(sensor) >= 0.3
    }

    private func display(_ mgdl: Int) -> String {
        isMmol ? Decimal(mgdl).formatted(for: .mmolL) : "\(mgdl)"
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button { value = max(range.lowerBound, value - step) } label: { Image(systemName: "minus") }
                    .buttonStyle(.bordered)
                    .frame(width: 40)
                Text(shown)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity)
                    .focusable(true)
                    .digitalCrownRotation(
                        $value,
                        from: range.lowerBound,
                        through: range.upperBound,
                        by: step,
                        sensitivity: .medium,
                        isContinuous: false,
                        isHapticFeedbackEnabled: true
                    )
                Button { value = min(range.upperBound, value + step) } label: { Image(systemName: "plus") }
                    .buttonStyle(.bordered)
                    .frame(width: 40)
            }
            Text(isMmol ? "mmol/L" : "mg/dL")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let sensor = sensorReading {
                Text("Sensor: \(display(sensor))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                if isFarFromSensor { confirmDifference = true } else { save() }
            } label: {
                Text("Save")
                    .frame(maxWidth: .infinity)
            }
            .tint(.green)
        }
        .navigationTitle("Add BG")
        .onAppear {
            let start = sensorReading ?? 100
            value = min(max(isMmol ? (Double(start) * 0.0555 * 10).rounded() / 10 : Double(start), range.lowerBound), range.upperBound)
        }
        .confirmationDialog("Save this BG?", isPresented: $confirmDifference) {
            Button("Save \(shown)") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(shown) is far from the sensor's \(display(sensorReading ?? 0)). The loop will use it.")
        }
    }

    private func save() {
        manager.addManualGlucose(mgdl: mgdl)
        WKInterfaceDevice.current().play(.success)
        dismiss()
    }
}

/// A risky action confirmed by a full turn of the Digital Crown instead of a tap: a deliberate motion that a
/// brush against the small screen doesn't make. Turning back, Cancel or closing the sheet confirms nothing.
struct CrownConfirmView: View {
    let title: String
    let message: String
    let prompt: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var turn = 0.0
    @State private var confirmed = false
    @FocusState private var crownFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: turn)
                        .stroke(Color.red, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "arrow.clockwise")
                        .font(.title3)
                }
                .frame(width: 64, height: 64)
                .focusable(true)
                .focused($crownFocused)
                .digitalCrownRotation(
                    $turn,
                    from: 0,
                    through: 1,
                    by: 0.01,
                    sensitivity: .low,
                    isContinuous: false,
                    isHapticFeedbackEnabled: true
                )
                Text(prompt)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Cancel") { dismiss() }
            }
        }
        .onAppear { crownFocused = true }
        .onChange(of: turn) { _, value in
            guard value >= 1, !confirmed else { return }
            confirmed = true
            WKInterfaceDevice.current().play(.success)
            dismiss()
            onConfirm()
        }
    }
}
