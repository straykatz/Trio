import SwiftUI

/// The watch's own G7 reading: the switch, the latest reading, one status
/// line and the pairing button. Details and the log sit behind a button.
struct WatchG7View: View {
    @State private var showDetails = false
    @State private var showResetConfirmation = false

    private var reader: WatchG7Reader { WatchG7Reader.shared }
    /// As TrioMainWatchView: the untethered page shows while the mode is on on the phone or a session runs.
    private var showsUntetheredPage: Bool { WatchState.shared.untetheredMode || UntetheredWatchManager.shared.isActive }

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                Toggle(isOn: Binding(
                    get: { reader.isEnabled },
                    set: { reader.setEnabled($0) }
                )) {
                    Text("Watch sensor", comment: "Toggle: the watch reads the G7 itself")
                        .font(.footnote)
                }

                if reader.isEnabled, reader.isStandingAside {
                    // the old value would only count up; untethered mode's readings are on the first pages
                    Text(
                        "Watch mode is reading the sensor. Its values are on the first pages.",
                        comment: "Watch sensor page while watch mode holds the sensor"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                    // the untethered page has the log, always; here only without it
                    if !showsUntetheredPage {
                        Button {
                            showDetails = true
                        } label: {
                            Text("Log", comment: "Button: open the watch sensor details and log")
                                .font(.footnote)
                        }
                    }
                } else if reader.isEnabled {
                    latestReading

                    Text(reader.statusText)
                        .font(.caption2)
                        .foregroundStyle(reader.isConnected || reader.freshReading != nil ? Color.secondary : Color.loopYellow)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    pairingButton

                    // the untethered page has the log, always; here only without it
                    if !showsUntetheredPage {
                        Button {
                            showDetails = true
                        } label: {
                            Text("Log", comment: "Button: open the watch sensor details and log")
                                .font(.footnote)
                        }
                    }
                } else {
                    Text(
                        "Reads your G7 when the iPhone is away. No dosing.",
                        comment: "One-line explanation under the watch sensor toggle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                    // the watch starts by itself only once this reader has readings of its own
                    if WatchState.shared.fallbackLoop, WatchState.shared.untetheredMode,
                       WatchState.shared.allowUntetheredStartWithoutPhone
                    {
                        Text(
                            "Off: the watch can't start by itself when the iPhone stops.",
                            comment: "Watch sensor page: the reader is off while Start by Itself is on"
                        )
                        .font(.caption2)
                        .foregroundStyle(Color.loopYellow)
                        .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .sheet(isPresented: $showDetails) {
            WatchG7DetailsView()
        }
        .confirmationDialog(
            Text("Pair the watch with the sensor again?", comment: "Confirmation title for resetting the watch's sensor pairing"),
            isPresented: $showResetConfirmation
        ) {
            Button(role: .destructive) {
                reader.resetWatchPairing()
            } label: {
                Text("Pair again", comment: "Confirm resetting the watch's sensor pairing")
            }
        }
        .onAppear {
            reader.noteWake()
        }
    }

    /// Right under the status, never greyed out: without a key it starts the pairing now (a new sensor, or a missed
    /// "Open Trio to Pair the Sensor"); with one it forgets the key and pairs again, after a confirmation.
    @ViewBuilder private var pairingButton: some View {
        if reader.hasWatchKey {
            Button(role: .destructive) {
                showResetConfirmation = true
            } label: {
                Text("Pair watch again", comment: "Button: forget the watch's own pairing with the sensor")
                    .font(.footnote)
            }
        } else {
            Button {
                reader.pairNow()
            } label: {
                Text("Pair sensor now", comment: "Button: start pairing the watch with the sensor")
                    .font(.footnote)
                    .fontWeight(.semibold)
            }
            .tint(.loopGreen)

            Text(
                "Keep Trio open until the first reading shows, and accept the Bluetooth request.",
                comment: "Hint under the watch sensor's pair button"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
    }

    private var latestReading: some View {
        VStack(spacing: 0) {
            if let latest = reader.latest {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(reader.format(Double(latest.glucose)))
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(reader.arrow(for: latest.trendName))
                        .font(.title3)
                }
                Text(latest.date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("--")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Everything for testing: the share button, what the watch knows, and the log (folded away).
struct WatchG7DetailsView: View {
    /// the log is long: folded away by default, so the details are in reach without scrolling
    @State private var showLog = false

    private var reader: WatchG7Reader { WatchG7Reader.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                // to Messages or Mail, for whoever helps with testing
                ShareLink(
                    item: shareText,
                    subject: Text("Trio watch sensor log"),
                    preview: SharePreview("Trio watch sensor log")
                ) {
                    Label {
                        Text("Share log", comment: "Button: share the watch sensor log")
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .font(.footnote)
                }

                VStack(alignment: .leading, spacing: 2) {
                    row(String(localized: "Sensor", comment: "Watch sensor details label"), reader.sensorName ?? "–")
                    row(
                        String(localized: "Code", comment: "Watch sensor details label: pairing code received"),
                        reader.pairingCode == nil ? "–" : "✓"
                    )
                    row(
                        String(localized: "Paired", comment: "Watch sensor details label: the watch has its own key"),
                        reader.hasWatchKey ? "✓" : "–"
                    )
                    row(String(localized: "Connected", comment: "Watch sensor details label"), reader.isConnected ? "✓" : "–")
                    let coverage = reader.recentCoverage
                    row(
                        String(
                            localized: "Last 2 h",
                            comment: "Watch sensor details label: readings received in the last two hours"
                        ),
                        "\(coverage.count)/\(coverage.expected) · max gap \(coverage.longestGapMinutes) min"
                            + (coverage.filledIn > 0 ? " · +\(coverage.filledIn) filled" : "")
                    )
                    row(String(localized: "Units", comment: "Watch sensor details label"), reader.units)
                    // the watch's own newest reading: its reader's, or in watch mode the session's from the sensor
                    let watchReading = [reader.latest?.date, UntetheredWatchManager.shared.ownSessionReadingDate]
                        .compactMap { $0 }.max()
                    row(
                        String(
                            localized: "Watch BG",
                            comment: "Watch sensor details label: age of the watch's own newest glucose"
                        ),
                        watchReading.map { minutesAgo($0) } ?? "–"
                    )
                    row(
                        String(localized: "iPhone BG", comment: "Watch sensor details label: age of the phone's newest glucose"),
                        reader.phoneGlucoseDate.map { minutesAgo($0) } ?? "–"
                    )
                    row(
                        String(
                            localized: "iPhone link",
                            comment: "Watch sensor details label: age of the last update from the phone"
                        ),
                        reader.lastPhoneContact.map { minutesAgo($0) } ?? "–"
                    )
                    if let problem = reader.sensorProblem {
                        row(
                            String(localized: "State", comment: "Watch sensor details label: sensor state without a reading"),
                            problem
                        )
                    }
                }
                .font(.caption2)

                if !reader.logLines.isEmpty {
                    Divider()
                    Button {
                        withAnimation { showLog.toggle() }
                    } label: {
                        Label {
                            showLog
                                ? Text("Hide log", comment: "Button: fold away the watch sensor log")
                                : Text("Show log", comment: "Button: unfold the watch sensor log")
                        } icon: {
                            Image(systemName: showLog ? "chevron.up" : "chevron.down")
                        }
                        .font(.footnote)
                    }
                    if showLog {
                        ForEach(Array(reader.logLines.suffix(60).reversed().enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    /// The details above the log, then the whole log (up to 200 lines), oldest first.
    private var shareText: String {
        let coverage = reader.recentCoverage
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
            + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")"
        let header = [
            "Trio watch sensor log, \(Date().formatted(date: .abbreviated, time: .shortened))",
            "Trio \(version)",
            "Sensor: \(reader.sensorName ?? "–")",
            "Paired: \(reader.hasWatchKey ? "yes" : "no") · connected: \(reader.isConnected ? "yes" : "no")",
            "Last 2 h: \(coverage.count)/\(coverage.expected) readings live, \(coverage.filledIn) filled in later, "
                + "longest gap \(coverage.longestGapMinutes) min (watch mode time left out)",
            "Units: \(reader.units)"
        ]
        return (header + [""] + reader.logLines).joined(separator: "\n")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
        }
    }

    private func minutesAgo(_ date: Date) -> String {
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        return String(
            localized: "\(minutes) min ago",
            comment: "Watch sensor details: minutes since a reading or an iPhone update"
        )
    }
}
