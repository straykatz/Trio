import Charts
import SwiftUI

extension UntetheredPhoneManager {
    /// Checking the devices, handing over, handing back or reading the pump after its return.
    var isBusy: Bool {
        if isCheckingDevices || isReachingPod { return true }
        switch state.session.phase {
        case .ending,
             .preparing,
             .starting: return true
        case .active,
             .idle: return state.pumpReturnPending
        }
    }
}

extension UntetheredPhoneManager {
    /// The hand-back was asked for and the watch hasn't handed back yet: it may take until the watch's next wake.
    var isHandingBack: Bool { state.session.phase == .ending }

    /// The start is under way and the watch hasn't answered yet: the phone keeps the pump and doses meanwhile.
    var isReachingWatch: Bool { state.session.phase == .preparing }

    /// The start's progress, so nobody taps again while it still goes on (9 November: a link that came and went ended
    /// a start after 30 s, and it showed only as "Untethered on Apple Watch" for a moment).
    func startProgressText(now: Date = Date()) -> String {
        let total = UntetheredSession.prepareTimeout
        let left = state.session.prepareDeadline.map { max(0, Int($0.timeIntervalSince(now).rounded())) } ?? Int(total)
        let waited = max(0, Int(total) - left)
        let tries = prepareAttempts > 0 ? " " + String(localized: "(try \(prepareAttempts + 1))") : ""
        return String(
            localized: "Reaching the watch: \(waited) s of up to \(Int(total)) s\(tries). Keep Trio open on the watch. The phone keeps the pump and doses until the watch has taken it."
        )
    }

    /// Why the hand-back takes its time: the watch's next wake. A bolus the watch runs goes on meanwhile and after.
    var handingBackText: String {
        if let left = watchBolusLeft {
            let units = String(format: "%.2f", left.units)
            let time = left.until.formatted(date: .omitted, time: .shortened)
            return String(
                localized: "The watch's bolus goes on: about \(units) U left, until \(time). The pump comes back meanwhile; the phone keeps the bolus as the watch reported it."
            )
        }
        return String(
            localized: "Open Trio on the watch to finish now. Otherwise it can take a few minutes, until the watch picks up the request."
        )
    }

    /// While the pump comes back: reaching it, then waiting for the watch's last records and the audit.
    var pumpReturnTitle: String {
        pumpReturnAnswered ? String(localized: "Checking the watch's records…") : String(localized: "Reaching the pump…")
    }
}

/// The toggle in Settings › Apple Watch. It only stays on once the watch has taken the pump.
struct UntetheredSettingsSection: View {
    @ObservedObject var manager: UntetheredPhoneManager
    @State private var confirmEnd = false
    @State private var confirmForce = false

    var body: some View {
        // under the Untethered Mode switch in Settings › Apple Watch: this one starts and ends a session
        Section(
            footer: Text(
                "The watch runs the loop with its own connection to the pump and the CGM while the phone is away. While it does, the phone shows glucose but doesn't dose."
            )
        ) {
            HStack {
                Text("Watch Runs the Loop")
                Spacer()
                if manager.isBusy {
                    ProgressView()
                } else {
                    Toggle("", isOn: Binding(
                        get: { manager.isWatchShownInCharge },
                        set: { on in
                            if on {
                                Task { await manager.start() }
                            } else {
                                confirmEnd = true
                            }
                        }
                    ))
                        .labelsHidden()
                }
            }

            if manager.isReachingWatch {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(manager.startProgressText(now: context.date))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = manager.state.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }

            if manager.isWatchInCharge {
                Button("Take Back the Pump Now", role: .destructive) { confirmForce = true }
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    UntetheredReadinessRow(readiness: manager.readiness)
                }
            }
        }
        .listRowBackground(Color.chart)
        .confirmationDialog("End watch mode?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End") { Task { await manager.end() } }
        } message: {
            Text("The watch hands the pump back as soon as it is reachable.")
        }
        .untetheredForceDialog(isPresented: $confirmForce, manager: manager)
    }
}

/// Whether the watch could start by itself if the iPhone were left behind now.
struct UntetheredReadinessRow: View {
    let readiness: UntetheredPhoneManager.Readiness

    var body: some View {
        switch readiness {
        case .off:
            EmptyView()
        case .ready:
            Label("Ready for a forgotten iPhone", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(Color.loopGreen)
        case let .unknown(hours):
            Label(unknownText(hours), systemImage: "questionmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case let .missing(missing):
            VStack(alignment: .leading, spacing: 4) {
                Label("Not ready for a forgotten iPhone", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                ForEach(missing, id: \.self) { Text(verbatim: "• " + $0) }
            }
            .font(.footnote)
        }
    }

    private func unknownText(_ hours: Int?) -> String {
        guard let hours else {
            return String(localized: "Ready for a forgotten iPhone? No word from the watch yet: open Trio on it.")
        }
        return String(localized: "Ready for a forgotten iPhone? No word from the watch for \(hours) h.")
    }
}

/// Left of the cancel button of an override that offers untethered mode.
struct UntetheredOverrideButton: View {
    @ObservedObject var manager: UntetheredPhoneManager
    let overrideID: String?
    @State private var confirmEnd = false
    @State private var confirmForce = false
    @State private var showError = false

    var body: some View {
        Group {
            if manager.isBusy {
                ProgressView()
            } else {
                Image(systemName: manager.isWatchShownInCharge ? "applewatch" : "applewatch.slash")
                    .font(.title2)
                    .foregroundStyle(manager.isWatchShownInCharge ? Color.untethered : Color.secondary)
                    .onTapGesture {
                        if manager.isWatchInCharge {
                            confirmEnd = true
                        } else {
                            Task { await manager.start(linkedOverrideID: overrideID) }
                        }
                    }
                    .onLongPressGesture { if manager.isWatchInCharge { confirmForce = true } }
            }
        }
        .frame(minWidth: 30)
        .confirmationDialog("End watch mode?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End") { Task { await manager.end() } }
            Button("Take Back the Pump Now", role: .destructive) { confirmForce = true }
        }
        .untetheredForceDialog(isPresented: $confirmForce, manager: manager)
        // a refusal can come from the watch long after the tap
        .onChange(of: manager.state.lastError) { _, error in
            showError = error != nil && !manager.isWatchInCharge
        }
        .alert("Watch Mode", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(manager.state.lastError ?? "")
        }
    }
}

/// `content`, or the untethered notice while the watch has the pump. `banner` draws it in the home screen's
/// own panel style; a tap offers ending untethered mode or taking the pump back, so the banner only shows it is
/// tappable while there is something to offer. `content` gets the last session's audit finding, so it updates
/// with it.
struct UntetheredBannerSlot<Content: View, Banner: View>: View {
    @ObservedObject var manager: UntetheredPhoneManager
    @ViewBuilder let content: (_ auditFinding: String?) -> Content
    let banner: (_ title: String, _ subtitle: String, _ isTappable: Bool, _ action: @escaping () -> Void) -> Banner
    @State private var showActions = false
    @State private var confirmForce = false

    var body: some View {
        if manager.isWatchInCharge || manager.state.pumpReturnPending {
            // by the second while the start reaches the watch, so its progress counts up
            TimelineView(.periodic(from: .now, by: manager.isReachingWatch ? 1 : 60)) { context in
            banner(
                manager.isBluetoothOff
                    ? String(localized: "⚠️ iPhone Bluetooth Off")
                    : manager.state.pumpReturnPending
                    ? manager.pumpReturnTitle
                    : manager.isReachingWatch ? String(localized: "Starting Watch Mode…")
                    : manager.isHandingBack ? String(localized: "Asking the watch for the pump…")
                    : manager.state.session.isCheckingForeignSession ? String(localized: "Safety Check with the Watch")
                    : String(localized: "Watch mode on Apple Watch"),
                manager.isBluetoothOff
                    ? (manager.state.pumpReturnPending
                        ? String(localized: "The phone can't reach the pump and nothing doses. Turn Bluetooth on.")
                        : String(localized: "The watch doses. Turn Bluetooth on before the pump comes back to the phone."))
                    : manager.state.pumpReturnPending
                    ? manager.state.lastError
                    ?? String(localized: "Checking what the watch delivered before the phone doses again.")
                    : manager.isReachingWatch
                    ? manager.startProgressText(now: context.date)
                    : manager.isHandingBack
                    ? manager.handingBackText
                    : manager.state.session.isCheckingForeignSession
                    // not untethered mode, though it shows in its place (6 November, 07:36: "what was that?")
                    ? String(localized: "The watch was just at the pod. The phone waits for the watch's answer before dosing again, usually a few seconds. Watch mode is not on.")
                    : String(localized: "The phone doesn't dose. Bolus and carbs are entered on the watch."),
                manager.isWatchInCharge && !manager.isReachingWatch,
                { showActions = manager.isWatchInCharge && !manager.isReachingWatch }
            )
            }
            .confirmationDialog("Watch Mode", isPresented: $showActions, titleVisibility: .visible) {
                Button("End Watch Mode") { Task { await manager.end() } }
                Button("Take Back the Pump Now", role: .destructive) { confirmForce = true }
            }
            .untetheredForceDialog(isPresented: $confirmForce, manager: manager)
        } else {
            content(manager.state.auditFinding)
        }
    }
}

/// When the watch had the pump: a band in the mode's colour at the target, drawn as the override and temp target
/// bands are, stronger while it runs. One still running reaches now.
struct UntetheredSpansView: ChartContent {
    let y: Decimal
    let now: Date

    var body: some ChartContent {
        ForEach(UntetheredGate.state.spans, id: \.start) { span in
            RuleMark(
                xStart: .value("Start", span.start, unit: .second),
                xEnd: .value("End", span.end ?? now, unit: .second),
                y: .value("Value", y)
            )
            .foregroundStyle(Color.untethered.opacity(span.end == nil ? 0.4 : 0.25))
            .lineStyle(.init(lineWidth: 8))
        }
    }
}

/// What the home screen's pump shows. Outside the generic gate, so its content closure can be inferred.
enum UntetheredPumpDisplay {
    /// The phone has the pump: its own figures and messages.
    case phone
    case watch(UntetheredPumpStatus)
    /// The watch has the pump, and nothing recent came from it.
    case away
}

/// The home screen's pump while the watch has it: the watch's own figures while they are recent, otherwise what is
/// going on, never the connection error of the phone's own pump manager, which handed the pod over.
struct UntetheredPumpGate<Content: View>: View {
    @ObservedObject var manager: UntetheredPhoneManager
    let now: Date
    @ViewBuilder let content: (UntetheredPumpDisplay) -> Content

    /// Three of the watch's loops: older figures may no longer be what the pod does.
    static var recent: TimeInterval { 15 * 60 }

    var body: some View {
        if !manager.isWatchShownInCharge {
            content(.phone)
        } else if let status = manager.state.watchPump, now.timeIntervalSince(status.date) < Self.recent {
            content(.watch(status))
        } else {
            content(.away)
        }
    }
}

/// Bolus and carbs are entered on the watch while it has the pump: in their place, what is going on and the ways
/// back, in the app's own background and glass panels.
/// The settings the watch doses with, while it has the pump: they came with the grant, and a change here would never
/// reach it. Locked until the hand-back, as LoopKit/Loop#2545 locks Settings during a loan.
struct UntetheredSettingsGate<Content: View>: View {
    @ObservedObject var manager: UntetheredPhoneManager
    @ViewBuilder let content: () -> Content
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if manager.isWatchInCharge {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.untethered)
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(Color.untethered.opacity(0.18)))
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("Locked While the Watch Loops").font(.title3).fontWeight(.semibold)
                    Text("The watch doses with these settings. Hand back to change them.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 8)
                Spacer()
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
        } else {
            content()
        }
    }
}

struct UntetheredTreatmentGate<Content: View>: View {
    @ObservedObject var manager: UntetheredPhoneManager
    @ViewBuilder let content: () -> Content
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEnd = false
    @State private var confirmForce = false

    var body: some View {
        if manager.isWatchInCharge || manager.state.pumpReturnPending {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.untethered)
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(Color.untethered.opacity(0.18)))
                    .shadow(color: Color.untethered.opacity(0.35), radius: 16)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(
                        manager.state.pumpReturnPending ? manager
                            .pumpReturnTitle
                            : manager.state.session.isCheckingForeignSession ? String(localized: "Safety Check with the Watch")
                            : String(localized: "The Apple Watch is looping")
                    )
                    .font(.title3).fontWeight(.semibold)
                    Text(
                        manager.state.pumpReturnPending
                            ? manager.pumpReturnAnswered
                            ? String(localized: "The phone doses again once it has checked the watch's records.")
                            : String(localized: "The phone doses again once it has read the pump.")
                            : manager.state.session.isCheckingForeignSession
                            ? String(
                                localized: "The watch was just at the pod. Boluses wait for the watch's answer, usually a few seconds. Watch mode is not on."
                            )
                            :
                            String(
                                localized: "Enter carbs and boluses on the watch. They come back to the phone with the watch's history."
                            )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 8)

                if manager.isHandingBack {
                    VStack(spacing: 8) {
                        ProgressView()
                        // counts down while the watch's bolus runs
                        TimelineView(.periodic(from: .now, by: 5)) { _ in
                            Text(String(localized: "Asking the watch for the pump…") + " " + manager.handingBackText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    gateButton("Take Back the Pump Now", systemImage: "exclamationmark.triangle", tint: .red) {
                        confirmForce = true
                    }
                } else if manager.isWatchShownInCharge {
                    VStack(spacing: 10) {
                        gateButton("End Watch Mode", systemImage: "iphone", tint: .untethered) { confirmEnd = true }
                        gateButton("Take Back the Pump Now", systemImage: "exclamationmark.triangle", tint: .red) {
                            confirmForce = true
                        }
                    }
                }
                Spacer()
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
            .navigationTitle("Treatments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
            }
            .confirmationDialog("End watch mode?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End") { Task { await manager.end() } }
            } message: {
                Text("The watch hands the pump back as soon as it is reachable.")
            }
            .untetheredForceDialog(isPresented: $confirmForce, manager: manager)
        } else {
            content()
        }
    }

    private func gateButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(tint.opacity(0.18)))
                Text(title).font(.subheadline).fontWeight(.semibold).foregroundStyle(.primary)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .glassPanel(tint: tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The home screen's background while the watch has the pump: a wash of the untethered color over Trio's own.
struct UntetheredHomeTint: View {
    @ObservedObject var manager: UntetheredPhoneManager

    var body: some View {
        Color.untethered
            .opacity(manager.tintsHomeScreen ? 0.16 : 0)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.4), value: manager.tintsHomeScreen)
    }
}

extension Color {
    /// Untethered watch mode, wherever it shows: a bright cyan on the dark background, deeper on the light one.
    static let untethered = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x33 / 255, green: 0xE3 / 255, blue: 0xFF / 255, alpha: 1)
            : UIColor(red: 0x00 / 255, green: 0x9C / 255, blue: 0xBD / 255, alpha: 1)
    })
}

private extension View {
    func untetheredForceDialog(isPresented: Binding<Bool>, manager: UntetheredPhoneManager) -> some View {
        confirmationDialog("Take back the pump?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Take Back", role: .destructive) { Task { await manager.forceTakeBack() } }
        } message: {
            Text(
                "Use this when the watch can't hand the pump back, for example when it is lost or out of battery. The phone first reaches for the pod; if it can't, nothing changes and the watch keeps running. Otherwise it takes the pump without waiting for the watch, and counts insulin it has no record of until the watch's history arrives."
            )
        }
    }
}
