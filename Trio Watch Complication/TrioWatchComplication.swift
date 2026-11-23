import Charts
import SwiftUI
import WidgetKit

// MARK: - Timeline Entry

struct TrioWatchComplicationEntry: TimelineEntry {
    let date: Date
    var data: TrioComplicationData?
}

// MARK: - Glucose from the watch app

/// Written by the watch app (ComplicationStore in WatchStateSnapshot.swift); keep the two in step.
struct TrioComplicationData: Codable {
    struct Point: Codable {
        let date: Date
        /// In the display units.
        let value: Double
        /// "#RRGGBB" by Trio's glucose color scheme.
        var color: String?
    }

    var points: [Point]
    var isMmol: Bool
    var low: Double
    var high: Double
    var trend: String?
    var delta: String?
    var colorScheme: String?
    var targetMgDL: Double?
    /// The sensor sends no glucose (failed, ended, a temporary issue) or the watch got none for 11 minutes in
    /// untethered mode: a yellow triangle, so a look at the face shows something needs checking.
    var sensorWarning: Bool?
    /// The watch has the pump (untethered mode): a watch symbol, so a look at the face shows it while another app
    /// (a workout) is in front.
    var untethered: Bool?
    /// The session's last loop, or its newest reading if newer (the loop follows the reading within seconds, and the
    /// face is redrawn for the reading): the symbol turns orange once this is `untetheredLateAfter` old.
    var untetheredLastLoop: Date?

    static func load() -> TrioComplicationData? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
              let data = UserDefaults(suiteName: group)?.data(forKey: "complication.glucose")
        else { return nil }
        return try? JSONDecoder().decode(TrioComplicationData.self, from: data)
    }
}

/// A reading older than this shows struck through and grey.
private let staleAfter: TimeInterval = 15 * 60
/// Untethered mode without a loop or reading for this long: the watch symbol turns orange.
private let untetheredLateAfter: TimeInterval = 10 * 60

extension TrioComplicationData {
    /// When the watch symbol turns orange, nil without untethered mode.
    var untetheredLateAt: Date? {
        guard untethered == true else { return nil }
        let reference = [untetheredLastLoop, points.last?.date].compactMap { $0 }.max() ?? .distantPast
        return reference.addingTimeInterval(untetheredLateAfter)
    }
}

/// The watch symbol while untethered mode has the pump: orange with an exclamation mark once it is late.
struct UntetheredBadge: View {
    let data: TrioComplicationData?
    let date: Date
    var size: CGFloat = 11
    var isFullColor = true

    var body: some View {
        if let lateAt = data?.untetheredLateAt {
            let isLate = date >= lateAt
            Image(systemName: isLate ? "exclamationmark.applewatch" : "applewatch")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isLate && isFullColor ? Color.orange : Color.primary)
                .widgetAccentable()
                .accessibilityLabel(isLate ? "Untethered mode, not looping" : "Untethered mode")
        }
    }
}

// MARK: - Provider

struct TrioWatchComplicationProvider: TimelineProvider {
    func placeholder(in _: Context) -> TrioWatchComplicationEntry {
        TrioWatchComplicationEntry(date: Date())
    }

    func getSnapshot(in _: Context, completion: @escaping (TrioWatchComplicationEntry) -> Void) {
        completion(TrioWatchComplicationEntry(date: Date(), data: TrioComplicationData.load()))
    }

    /// The watch app asks for a new timeline with every newer reading. Until then the graph stays as it
    /// is, and once the newest reading is too old a second entry shows it as stale.
    func getTimeline(in _: Context, completion: @escaping (Timeline<TrioWatchComplicationEntry>) -> Void) {
        let now = Date()
        let data = TrioComplicationData.load()
        var entries = [TrioWatchComplicationEntry(date: now, data: data)]
        if let latest = data?.points.last?.date, latest.addingTimeInterval(staleAfter) > now {
            entries.append(TrioWatchComplicationEntry(date: latest.addingTimeInterval(staleAfter + 1), data: data))
        }
        // the watch symbol turns orange by itself: a watch app that stopped running can't redraw the face
        if let lateAt = data?.untetheredLateAt, lateAt > now {
            entries.append(TrioWatchComplicationEntry(date: lateAt.addingTimeInterval(1), data: data))
        }
        entries.sort { $0.date < $1.date }
        completion(Timeline(entries: entries, policy: .never))
    }
}

// MARK: - Views

//// Displayed View Wrapper
struct TrioWatchComplicationEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily

    var entry: TrioWatchComplicationEntry

    var body: some View {
        switch widgetFamily {
        case .accessoryRectangular:
            TrioAccessoryRectangularView(entry: entry)
        case .accessoryCircular:
            TrioAccessoryCircularView(entry: entry)
        #if os(watchOS)
            case .accessoryCorner:
                TrioAccessoryCornerView(entry: entry)
        #endif
        default:
            Image("ComplicationIcon")
                .widgetAccentable()
                .widgetBackground(backgroundView: Color.clear)
        }
    }
}

#if os(watchOS)
    /// Corner Complication
    struct TrioAccessoryCornerView: View {
        var entry: TrioWatchComplicationProvider.Entry

        var body: some View {
            Text("")
                .widgetCurvesContent()
                .widgetLabel {
                    Text(entry.data?.untethered == true ? "Trio ⌚︎" : "Trio")
                }
                .widgetBackground(backgroundView: Color.clear)
        }
    }
#endif

/// Circular Complication
struct TrioAccessoryCircularView: View {
    var entry: TrioWatchComplicationProvider.Entry

    var body: some View {
        Image("ComplicationIcon")
            .resizable()
            .widgetAccentable()
            .overlay(alignment: .bottomTrailing) {
                if entry.data?.sensorWarning == true {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.yellow)
                }
            }
            .overlay(alignment: .bottomLeading) {
                UntetheredBadge(data: entry.data, date: entry.date, size: 12)
            }
            .widgetBackground(backgroundView: Color.clear)
    }
}

/// The middle slot: the newest glucose with its arrow and change, and the last 3 hours as a graph over
/// the target range, as the Live Activity shows it.
struct TrioAccessoryRectangularView: View {
    var entry: TrioWatchComplicationProvider.Entry
    /// Full color only on faces set to a multicolor option; the others tint the complication in one color.
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var isFullColor: Bool { renderingMode == .fullColor }

    private let span: TimeInterval = 3 * 60 * 60

    var body: some View {
        Group {
            if let data = entry.data, let latest = data.points.last {
                content(data, latest: latest)
            } else {
                VStack(alignment: .leading) {
                    Text("Trio").font(.headline)
                    Text("Open Trio on the watch once").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .widgetBackground(backgroundView: Color.clear)
    }

    private func content(_ data: TrioComplicationData, latest: TrioComplicationData.Point) -> some View {
        let isStale = entry.date.timeIntervalSince(latest.date) > staleAfter
        let start = entry.date.addingTimeInterval(-span)
        let points = data.points.filter { $0.date >= start }
        let values = points.map(\.value) + [data.low, data.high]
        let padding = data.isMmol ? 0.5 : 10
        let yMin = (values.min() ?? data.low) - padding
        let yMax = (values.max() ?? data.high) + padding

        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(format(latest.value, isMmol: data.isMmol))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .strikethrough(isStale)
                        .minimumScaleFactor(0.6)
                    Text(arrow(data.trend))
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(isStale ? Color.secondary : color(latest, data))
                .widgetAccentable()
                .lineLimit(1)
                Text(isStale ? "" : data.delta ?? "")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                HStack(spacing: 2) {
                    UntetheredBadge(data: data, date: entry.date, size: 11, isFullColor: isFullColor)
                    if data.sensorWarning == true {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(isFullColor ? Color.yellow : Color.primary)
                            .widgetAccentable()
                    }
                    Text(latest.date, style: .time)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            Chart {
                RectangleMark(
                    xStart: .value("Start", start),
                    xEnd: .value("End", entry.date),
                    yStart: .value("Low", data.low),
                    yEnd: .value("High", data.high)
                )
                .foregroundStyle(isFullColor ? Color.green.opacity(0.15) : Color.primary.opacity(0.08))
                // the low and high thresholds as lines, so the range still reads where the band is too faint
                ForEach([data.low, data.high], id: \.self) { threshold in
                    RuleMark(y: .value("Threshold", threshold))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .foregroundStyle(lineColor(threshold == data.low ? .red : .yellow))
                }
                if let target = data.targetMgDL {
                    RuleMark(y: .value("Target", data.isMmol ? target * 0.0555 : target))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(lineColor(.green))
                }
                ForEach(points, id: \.date) { point in
                    PointMark(x: .value("Time", point.date), y: .value("Glucose", point.value))
                        .symbolSize(10)
                        .foregroundStyle(isStale ? Color.secondary : color(point, data))
                        // in one tint, readings out of range stand out by brightness
                        .opacity(isFullColor || point.value < data.low || point.value > data.high ? 1 : 0.55)
                }
            }
            .chartXScale(domain: start ... entry.date)
            .chartYScale(domain: yMin ... yMax)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .widgetAccentable(!isFullColor)
        }
    }

    /// Red for low, green for the target and yellow for high on a multicolor face; in one tint, both lines in that tint.
    private func lineColor(_ color: Color) -> Color {
        isFullColor ? color.opacity(0.8) : Color.primary.opacity(0.5)
    }

    private func format(_ value: Double, isMmol: Bool) -> String {
        value.formatted(.number.precision(.fractionLength(isMmol ? 1 : 0)))
    }

    /// The color the watch app stored for the reading (Trio's static or dynamic scheme), else by range.
    private func color(_ point: TrioComplicationData.Point, _ data: TrioComplicationData) -> Color {
        if let hex = point.color, let stored = Color(hex: hex) { return stored }
        if point.value < data.low { return .red }
        if point.value > data.high { return .yellow }
        return .green
    }

    private func arrow(_ trend: String?) -> String {
        switch trend {
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
}

// MARK: - Widget Configuration

@main struct TrioWatchComplication: Widget {
    let kind: String = "TrioWatchComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TrioWatchComplicationProvider()) { entry in
            TrioWatchComplicationEntryView(entry: entry)
        }
        .configurationDisplayName("Trio")
        .description("Glucose and the last 3 hours in the wide slot; the Trio icon in the others")
        .supportedFamilies(supportedFamilies)
    }

    private var supportedFamilies: [WidgetFamily] {
        #if os(watchOS)
            return [.accessoryCorner, .accessoryCircular, .accessoryRectangular]
        #else
            return [.accessoryCircular]
        #endif
    }
}

extension Color {
    /// "#RRGGBB"
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let rgb = UInt64(digits, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

extension View {
    func widgetBackground(backgroundView: some View) -> some View {
        if #available(watchOS 10.0, iOSApplicationExtension 17.0, iOS 17.0, *) {
            return containerBackground(for: .widget) {
                backgroundView
            }
        } else {
            return background(backgroundView)
        }
    }
}
