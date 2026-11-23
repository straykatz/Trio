import Foundation
import SwiftUI

/// Devices page — pump and CGM peripheral lifetime at a glance.
///
/// From EJM0/Trio (Elias Maurer, `PeripheralsView`). In this fork the phone's data can be overridden by what the
/// watch knows itself while it runs the pod and the sensor (untethered mode): `own`.
///
/// Laid out as two gauges side by side so the page reads like the rest of the
/// carousel: content floats on the shared gradient, no card chrome, and the
/// rings echo the glucose bobble on page 2. It deliberately never scrolls —
/// the digital crown drives paging on this `TabView`, so a `ScrollView` here
/// would swallow the gesture that gets the user back to their glucose.
///
/// Every element is conditional on the phone actually having the data: patch
/// pumps report no battery, conventional pumps have no expiration, and several
/// CGM sources (Eversense, Nightscout, xDrip) surface no sensor expiry at all.
/// Rather than render placeholders, a section that has nothing to say is simply
/// not drawn.
///
/// Note on style: the view deliberately avoids generic container views, range
/// patterns over `Decimal`, and ternaries inside view initializers. Each of
/// those is cheap on its own but they compound into multi-minute SwiftUI type
/// checking, so values are computed into explicitly typed locals first.
/// The pod and the sensor as the watch itself sees them, while it runs them (untethered mode).
struct WatchOwnDevices {
    var reservoir: Decimal?
    var expiresAt: Date?
    var activatedAt: Date?
    var sensorExpiresAt: Date?
}

struct PeripheralsView: View {
    let state: WatchState
    let isWatchStateDated: Bool
    /// Set while the watch runs the pod and the sensor: their values come from the watch and are never dated.
    var own: WatchOwnDevices?

    /// Matches the phone's `0xDEAD_BEEF` sentinel for "reservoir is above the
    /// pump's reportable threshold" (Omnipod caps its reading at 50 U).
    ///
    /// Built from `UInt32` rather than an `Int` literal: `Int` is 32 bits wide
    /// on watchOS (arm64_32), where 0xDEAD_BEEF does not fit.
    private static let reservoirAboveThreshold = Decimal(UInt32(0xDEAD_BEEF))

    private static let hour: TimeInterval = 60 * 60
    private static let podWarningThreshold: TimeInterval = 24 * hour
    private static let podCriticalThreshold: TimeInterval = 8 * hour
    /// Fallback pod lifetime when the phone sent no activation date, which is
    /// the case for Omnipod in its default (non-extended) expiry mode.
    private static let nominalPodLifetime: TimeInterval = 72 * hour

    private static let staleValue = "--"

    /// As the phone's `SensorRemainingTimeFormatter`: "2d 5h", "7h", "35m", "< 1m".
    private static func remainingTime(until expiresAt: Date, now: Date) -> String {
        let totalMinutes = Int(max(0, expiresAt.timeIntervalSince(now))) / 60
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        let d = String(localized: "d", comment: "Abbreviation for Days")
        let h = String(localized: "h", comment: "Abbreviation for Hours")
        let m = String(localized: "m", comment: "Abbreviation for Minutes")
        if days > 0, hours > 0 { return "\(days)\(d) \(hours)\(h)" }
        if days > 0 { return "\(days)\(d)" }
        if hours > 0 { return "\(hours)\(h)" }
        if minutes > 0 { return "\(minutes)\(m)" }
        return "<\u{00A0}1\u{00A0}\(m)"
    }

    // MARK: - Values (the watch's own first, while it has the devices)

    private var pumpReservoir: Decimal? { own?.reservoir ?? state.pumpReservoir }
    private var pumpExpiresAt: Date? { own?.expiresAt ?? state.pumpExpiresAt }
    private var pumpActivatedAt: Date? { own?.activatedAt ?? state.pumpActivatedAt }
    /// The phone's pump message is about its own link, not the watch's, while the watch has the pod.
    private var pumpStatusMessage: String? { own == nil ? state.pumpStatusMessage : nil }
    private var pumpBatteryPercent: Int? { own == nil ? state.pumpBatteryPercent : nil }
    private var cgmSensorExpiresAt: Date? { own?.sensorExpiresAt ?? state.cgmSensorExpiresAt }
    /// The phone's numbers are old; the watch's own aren't.
    private var isPumpDated: Bool { own == nil && isWatchStateDated }
    private var isSensorDated: Bool { isWatchStateDated && own?.sensorExpiresAt == nil }

    // MARK: - Availability

    private var hasPumpData: Bool {
        if pumpReservoir != nil { return true }
        if pumpBatteryPercent != nil { return true }
        if pumpExpiresAt != nil { return true }
        if pumpStatusMessage != nil { return true }
        return false
    }

    private var hasCGMData: Bool {
        if cgmSensorExpiresAt != nil { return true }
        if state.cgmProgressPercent != nil { return true }
        if state.cgmStatusMessage != nil { return true }
        return false
    }

    /// Until the first watch state arrives the page has nothing to show.
    /// Distinguish that from "the phone answered and there is genuinely
    /// nothing to show".
    private var isAwaitingFirstPayload: Bool {
        !state.hasReceivedPeripheralData && !hasPumpData && !hasCGMData
    }

    // MARK: - Body

    var body: some View {
        // the watch's own values change without a phone push: look again every half minute
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if isAwaitingFirstPayload {
                loadingPlaceholder
            } else if !hasPumpData, !hasCGMData {
                emptyPlaceholder
            } else {
                HStack(alignment: .top, spacing: 6) {
                    if hasPumpData {
                        pumpColumn
                    }
                    if hasCGMData {
                        cgmColumn
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Placeholders

    private var loadingPlaceholder: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Loading…")
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary)
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "sensor.tag.radiowaves.forward")
                .font(.title3)
                .foregroundStyle(Color.secondary)
            Text("No device data")
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary)
        }
    }

    // MARK: - Pump

    private var pumpColumn: some View {
        VStack(spacing: 4) {
            pumpGauge

            PeripheralLabel(title: pumpTitle)

            pumpDetails
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var pumpTitle: String {
        state.pumpName ?? String(localized: "Pump", comment: "Watch peripherals section header")
    }

    /// Pod / patch lifetime. Conventional pumps never populate `pumpExpiresAt`,
    /// so they get the pump glyph instead of a countdown and the gauge keeps
    /// its size, which keeps both columns aligned.
    @ViewBuilder private var pumpGauge: some View {
        if let expiresAt = pumpExpiresAt {
            TimelineView(.periodic(from: Date(), by: 60)) { context in
                PeripheralGauge(
                    remaining: podRemaining(expiresAt: expiresAt, now: context.date),
                    color: podRingColor(expiresAt: expiresAt, now: context.date),
                    label: podRingLabel(expiresAt: expiresAt, now: context.date),
                    icon: "cross.vial.fill",
                    deviceType: state.deviceType
                )
            }
        } else {
            PeripheralGauge(
                remaining: nil,
                color: pumpGlyphColor,
                label: nil,
                icon: "cross.vial.fill",
                deviceType: state.deviceType
            )
        }
    }

    private var pumpGlyphColor: Color {
        if isPumpDated { return Color.secondary }
        return Color.insulin
    }

    /// A pump status highlight ("No Pod", "Insulin Suspended", …) takes the
    /// place of the reservoir and battery, exactly as it does in the phone's
    /// home header: while the pump is reporting a problem, the last known
    /// numbers are not what the user needs to see — and for a removed pod they
    /// are simply wrong.
    @ViewBuilder private var pumpDetails: some View {
        if let statusMessage = pumpStatusMessage {
            PeripheralMessage(text: statusMessage, color: Color.orange)
        } else {
            if let reservoir = pumpReservoir {
                let value: String = isPumpDated ? Self.staleValue : reservoirText(reservoir)
                let color: Color = isPumpDated ? Color.secondary : reservoirColor(reservoir)

                PeripheralMetric(icon: "cross.vial.fill", value: value, color: color)
            }

            if let batteryPercent = pumpBatteryPercent {
                let value: String = isPumpDated ? Self.staleValue : "\(batteryPercent) %"
                let color: Color = isPumpDated ? Color.secondary : batteryColor(batteryPercent)

                PeripheralMetric(icon: "battery.100", value: value, color: color)
            }
        }
    }

    private func reservoirText(_ reservoir: Decimal) -> String {
        let unit = String(localized: "U", comment: "Insulin unit")
        if reservoir == Self.reservoirAboveThreshold {
            return "50+ \(unit)"
        }
        // Rounds like the phone's `Formatter.integerFormatter`, so both show the same number
        return "\(reservoir.formatted(.number.precision(.fractionLength(0)))) \(unit)"
    }

    /// Mirrors `PumpView.reservoirColor` on the phone.
    private func reservoirColor(_ reservoir: Decimal) -> Color {
        if reservoir == Self.reservoirAboveThreshold { return Color.insulin }
        if reservoir <= Decimal(10) { return Color.loopRed }
        if reservoir <= Decimal(30) { return Color.orange }
        return Color.insulin
    }

    /// Mirrors `PumpView.batteryColor` on the phone.
    private func batteryColor(_ percent: Int) -> Color {
        if percent <= 10 { return Color.loopRed }
        if percent <= 20 { return Color.orange }
        return Color.loopGreen
    }

    /// Mirrors `PumpView.timerColor` on the phone.
    private func podRingColor(expiresAt: Date, now: Date) -> Color {
        if isPumpDated { return Color.secondary }
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= Self.podCriticalThreshold { return Color.loopRed }
        if remaining <= Self.podWarningThreshold { return Color.orange }
        return Color.loopGreen
    }

    /// Fraction of the pod's life still left, so the ring counts down.
    private func podRemaining(expiresAt: Date, now: Date) -> Double {
        let activatedAt = pumpActivatedAt ?? expiresAt.addingTimeInterval(-Self.nominalPodLifetime)
        let total = expiresAt.timeIntervalSince(activatedAt)
        guard total > 0 else { return 0 }
        let left = expiresAt.timeIntervalSince(now)
        let fraction: Double = left / total
        return min(1.0, max(0.0, fraction))
    }

    private func podRingLabel(expiresAt: Date, now: Date) -> String {
        if isPumpDated { return Self.staleValue }
        guard expiresAt > now else {
            return String(localized: "Replace", comment: "Watch: patch pump expired")
        }
        return Self.remainingTime(until: expiresAt, now: now)
    }

    // MARK: - CGM

    private var cgmColumn: some View {
        VStack(spacing: 4) {
            cgmGauge

            PeripheralLabel(title: cgmTitle)

            cgmDetails
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var cgmTitle: String {
        state.cgmName ?? String(localized: "Sensor", comment: "Watch peripherals section header")
    }

    @ViewBuilder private var cgmDetails: some View {
        if let statusMessage = state.cgmStatusMessage {
            PeripheralMessage(text: statusMessage, color: Color.secondary)
        }
    }

    /// Sensor lifetime. Sources that report an expiry get a live countdown;
    /// those that only report lifecycle progress (xDrip, some plugins) get the
    /// percentage instead; sources with neither get the sensor glyph.
    ///
    /// `cgmProgressPercent` is how much of the session is *used up*, so the
    /// ring gets its complement and drains like the pod's. Vendors that only
    /// publish progress near end of life (G7 under 48 h, Libre under 3 days)
    /// therefore show a full ring until they start reporting, rather than an
    /// empty one.
    @ViewBuilder private var cgmGauge: some View {
        if let expiresAt = cgmSensorExpiresAt {
            TimelineView(.periodic(from: Date(), by: 60)) { context in
                PeripheralGauge(
                    remaining: sensorRemaining(state.cgmProgressPercent ?? 0),
                    color: sensorColor,
                    label: sensorRingLabel(expiresAt: expiresAt, now: context.date),
                    icon: "sensor.tag.radiowaves.forward.fill",
                    deviceType: state.deviceType
                )
            }
        } else if let progress = state.cgmProgressPercent {
            PeripheralGauge(
                remaining: sensorRemaining(progress),
                color: sensorColor,
                label: sensorPercentLabel(progress),
                icon: "sensor.tag.radiowaves.forward.fill",
                deviceType: state.deviceType
            )
        } else {
            PeripheralGauge(
                remaining: nil,
                color: sensorColor,
                label: nil,
                icon: "sensor.tag.radiowaves.forward.fill",
                deviceType: state.deviceType
            )
        }
    }

    private func sensorRemaining(_ percentComplete: Double) -> Double {
        min(1.0, max(0.0, 1 - percentComplete))
    }

    private func sensorRingLabel(expiresAt: Date, now: Date) -> String {
        if isSensorDated { return Self.staleValue }
        return Self.remainingTime(until: expiresAt, now: now)
    }

    /// Percentage *left*, so the number counts down in step with the ring.
    private func sensorPercentLabel(_ percentComplete: Double) -> String {
        if isSensorDated { return Self.staleValue }
        let percent = Int((sensorRemaining(percentComplete) * 100).rounded())
        return "\(percent) %"
    }

    /// Mirrors `SensorLifecycleArcView.arcColor`, driven by the
    /// `DeviceLifecycleProgressState` raw value the phone forwarded.
    private var sensorColor: Color {
        if isSensorDated { return Color.secondary }
        guard let progressState = state.cgmProgressState else { return Color.loopGreen }
        if progressState == "critical" { return Color.loopRed }
        if progressState == "warning" { return Color.orange }
        return Color.loopGreen
    }
}

// MARK: - Building blocks

/// Scaled-down cousin of the glucose bobble: a faint track and, wrapped around
/// a compact label, an arc that starts full at 12 o'clock and counts down — it
/// retreats back toward 12 o'clock as the device's life runs out, so a short
/// arc always means little time left. Devices that report no lifetime at all
/// show their glyph instead, so a column keeps its shape whatever the hardware
/// can tell us.
private struct PeripheralGauge: View {
    /// Fraction of the device's lifetime still remaining, 1 → 0. `nil` when the
    /// device reports no lifetime, which draws the glyph instead of an arc.
    let remaining: Double?
    let color: Color
    let label: String?
    let icon: String
    let deviceType: WatchSize

    private var clampedRemaining: Double {
        min(1, max(0, remaining ?? 0))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: deviceType.peripheralRingLineWidth)

            if remaining != nil {
                Circle()
                    .trim(from: 0, to: clampedRemaining)
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: deviceType.peripheralRingLineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.6), radius: 3)
                    .animation(.easeInOut(duration: 0.25), value: clampedRemaining)
            }

            if let label = label {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .fontDesign(.rounded)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .padding(.horizontal, 3)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(color)
            }
        }
        .frame(width: deviceType.peripheralRingSize, height: deviceType.peripheralRingSize)
    }
}

/// Device name under a gauge — the caption that says which hardware the ring
/// above belongs to.
private struct PeripheralLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// `icon value` pair, styled like the IOB / COB readouts in the toolbar.
private struct PeripheralMetric: View {
    let icon: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10))

            Text(value)
                .fontWeight(.bold)
                .fontDesign(.rounded)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .font(.system(size: 12))
        .foregroundStyle(color)
    }
}

/// Status highlight forwarded from the pump or CGM — "No Pod", "Sensor
/// Warm-Up", and friends.
private struct PeripheralMessage: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
    }
}
