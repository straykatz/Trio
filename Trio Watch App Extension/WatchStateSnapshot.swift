//
//  WatchStateSnapshot.swift
//  Trio
//
//  Created by Cengiz Deniz on 18.04.25.
//
import Foundation
import SwiftUI
import WidgetKit

enum WatchStateSnapshot {
    private static let storageKey = "WatchStateSnapshot.latest"

    static func saveLatestDateToDisk(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: storageKey)
    }

    static func loadLatestDateFromDisk() -> Date {
        let interval = UserDefaults.standard.double(forKey: storageKey)
        return Date(timeIntervalSince1970: interval)
    }
}

// MARK: - Glucose for the watch face

/// What the watch-face graph shows. The watch app writes it to the app group whenever a newer reading
/// arrives (from the phone, untethered mode or the watch's own G7 reader); the complication only reads
/// it. Keep in step with the copy in TrioWatchComplication.swift.
struct TrioComplicationData: Codable {
    struct Point: Codable {
        let date: Date
        /// In the display units.
        let value: Double
        /// "#RRGGBB" by Trio's glucose color scheme, as the phone and the Live Activity color it.
        var color: String?
    }

    var points: [Point]
    var isMmol: Bool
    /// The shaded range, in the display units.
    var low: Double
    var high: Double
    /// Nightscout direction name of the newest reading.
    var trend: String?
    var delta: String?
    /// The phone's color scheme and target, to color the watch's own readings the same way.
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
}

enum ComplicationStore {
    static let kind = "TrioWatchComplication"
    private static let key = "complication.glucose"
    /// The graph spans 3 hours.
    private static let span: TimeInterval = 3 * 60 * 60
    private static let mmolFactor = 0.0555

    private static var defaults: UserDefaults? {
        (Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String)
            .flatMap { UserDefaults(suiteName: $0) }
    }

    static func load() -> TrioComplicationData? {
        defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(TrioComplicationData.self, from: $0) }
    }

    private static func save(_ data: TrioComplicationData, previousLatest: Date?, force: Bool = false) {
        guard let defaults, let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: key)
        if force {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
            return
        }
        // redraw only for a newer reading: watchOS budgets the redraws. The phone's copy of a reading the
        // watch read itself carries a timestamp a few seconds apart; that is the same reading, not a new one
        // (2026-10-19: some 20 redraws an hour overnight, likely past the budget: the face went stale).
        if let latest = data.points.last?.date,
           previousLatest.map({ abs(latest.timeIntervalSince($0)) > 60 }) ?? true
        {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }

    private static func range(isMmol: Bool, lowMgDL: Double? = nil, highMgDL: Double? = nil) -> (low: Double, high: Double) {
        let reader = WatchG7Reader.shared
        let low = lowMgDL ?? reader.lowMgDL ?? 70
        let high = highMgDL ?? reader.highMgDL ?? 180
        return isMmol ? (low * mmolFactor, high * mmolFactor) : (low, high)
    }

    /// After the phone's data or untethered mode's own reached the watch state. Untethered mode passes
    /// its units and range; the phone's come through the reader's settings.
    static func update(
        from state: WatchState,
        isMmol: Bool? = nil,
        lowMgDL: Double? = nil,
        highMgDL: Double? = nil,
        colorScheme: String? = nil,
        targetMgDL: Double? = nil
    ) {
        guard let newest = state.glucoseValues.last else { return }
        let old = load()
        let isMmol = isMmol ?? WatchG7Reader.shared.isMmol
        let cutoff = Date().addingTimeInterval(-span)
        // the phone and untethered mode already colored each reading by the scheme
        var points = state.glucoseValues.filter { $0.date >= cutoff }
            .map { TrioComplicationData.Point(date: $0.date, value: $0.glucose, color: $0.color.toHexString()) }
        var trend = state.trend
        var delta = state.delta
        // the watch's own reader may be ahead of the phone: keep its newer readings
        if let old, old.isMmol == isMmol {
            let newer = old.points.filter { $0.date > newest.date.addingTimeInterval(60) }
            if !newer.isEmpty {
                points += newer
                trend = old.trend
                delta = old.delta
            }
        }
        let shaded = range(isMmol: isMmol, lowMgDL: lowMgDL, highMgDL: highMgDL)
        save(
            TrioComplicationData(
                points: points,
                isMmol: isMmol,
                low: shaded.low,
                high: shaded.high,
                trend: trend,
                delta: delta,
                colorScheme: colorScheme ?? old?.colorScheme,
                targetMgDL: targetMgDL ?? old?.targetMgDL,
                sensorWarning: old?.sensorWarning,
                untethered: old?.untethered,
                untetheredLastLoop: old?.untetheredLastLoop
            ),
            previousLatest: old?.points.last?.date
        )
    }

    /// Untethered mode on or off, and its last loop. Redrawn at once when the mode changes; a new loop waits for the
    /// redraw of its reading (watchOS budgets the redraws), which the face takes as the loop's time until then.
    static func setUntethered(_ on: Bool, lastLoop: Date?) {
        guard var data = load() else { return }
        let loop = on ? lastLoop : nil
        guard (data.untethered ?? false) != on || data.untetheredLastLoop != loop else { return }
        let modeChanged = (data.untethered ?? false) != on
        data.untethered = on
        data.untetheredLastLoop = loop
        save(data, previousLatest: data.points.last?.date, force: modeChanged)
    }

    /// The sensor warning on or off; redrawn at once when it changes, which is rare.
    static func setSensorWarning(_ on: Bool) {
        guard var data = load(), (data.sensorWarning ?? false) != on else { return }
        data.sensorWarning = on
        save(data, previousLatest: data.points.last?.date, force: true)
    }

    /// A reading of the watch's own G7 reader, in mg/dL.
    static func add(_ reading: WatchG7Reading) {
        let old = load()
        let isMmol = WatchG7Reader.shared.isMmol
        var points = (old?.isMmol == isMmol ? old?.points : nil) ?? []
        // within a minute of one already there it is the same reading
        guard !points.contains(where: { abs($0.date.timeIntervalSince(reading.date)) < 60 }),
              reading.date > (points.last?.date ?? .distantPast)
        else { return }
        let value = isMmol ? Double(reading.glucose) * mmolFactor : Double(reading.glucose)
        var delta: String?
        if let previous = points.last, reading.date.timeIntervalSince(previous.date) < 15 * 60 {
            let change = value - previous.value
            let formatted = change.formatted(.number.precision(.fractionLength(isMmol ? 1 : 0)))
            delta = change < 0 ? formatted : "+" + formatted
        }
        let cutoff = Date().addingTimeInterval(-span)
        points.removeAll { $0.date < cutoff }
        // the range the phone or untethered mode last gave, else the reader's alert thresholds
        var shaded = range(isMmol: isMmol)
        if let old, old.isMmol == isMmol { shaded = (low: old.low, high: old.high) }
        // colored as the phone colors it: the dynamic scheme ramps between fixed ends around the target
        let scheme = old?.colorScheme.flatMap(GlucoseColorScheme.init(rawValue:)) ?? .staticColor
        let toMgDL = isMmol ? 1 / mmolFactor : 1
        let color = getDynamicGlucoseColor(
            glucoseValue: Decimal(reading.glucose),
            highGlucoseColorValue: scheme == .dynamicColor ? 220 : Decimal(shaded.high * toMgDL),
            lowGlucoseColorValue: scheme == .dynamicColor ? 55 : Decimal(shaded.low * toMgDL),
            targetGlucose: Decimal(old?.targetMgDL ?? 100),
            glucoseColorScheme: scheme
        )
        points.append(.init(date: reading.date, value: value, color: color.toHexString()))
        save(
            TrioComplicationData(
                points: points,
                isMmol: isMmol,
                low: shaded.low,
                high: shaded.high,
                trend: reading.trendName,
                delta: delta,
                colorScheme: old?.colorScheme,
                targetMgDL: old?.targetMgDL,
                sensorWarning: old?.sensorWarning,
                untethered: old?.untethered,
                untetheredLastLoop: old?.untetheredLastLoop
            ),
            previousLatest: old?.points.last?.date
        )
    }
}
