import Foundation

/// Checks the pump's own delivered total against the history after it comes back from the watch.
/// The pump knows how much it delivered, not when, so the difference can only be booked as "now".
enum UntetheredAudit {
    /// Below this the records explain the pump: pulse rounding and per-minute basal steps.
    static let tolerance: Decimal = 0.2

    enum Verdict: Equatable {
        case explained
        /// The pump delivered this much that no record explains.
        case unrecorded(Decimal)
        /// The records claim this much more than the pump delivered.
        case overstated(Decimal)
    }

    /// At a start without the phone: what the pod delivered since the standing grant's copy that its history and the
    /// schedule don't explain, the phone having dosed on after the copy went. Nil within the tolerance, or without
    /// both readings. The amount is right, its time is not: booked as now, IOB errs high and dosing low.
    static func unexplainedSinceCopy(
        copyUnits: Double?,
        copyAt: Date,
        podUnits: Double?,
        podAt: Date,
        history: [PumpHistoryEvent],
        basalProfile: [BasalProfileEntry],
        bolusDeliveryRate: Double,
        calendar: Calendar = .current
    ) -> Decimal? {
        guard let copyUnits, let podUnits, podAt > copyAt, podUnits >= copyUnits else { return nil }
        let expected = expectedDelivery(
            from: copyAt,
            to: podAt,
            history: history,
            basalProfile: basalProfile,
            bolusDeliveryRate: bolusDeliveryRate,
            calendar: calendar
        )
        guard case let .unrecorded(units) = verdict(delivered: Decimal(podUnits - copyUnits), expected: expected)
        else { return nil }
        return units
    }

    static func verdict(delivered: Decimal, expected: Decimal) -> Verdict {
        let unexplained = delivered - expected
        if unexplained > tolerance { return .unrecorded(unexplained) }
        if unexplained < -tolerance { return .overstated(-unexplained) }
        return .explained
    }

    /// What `history` (`PumpHistoryStorage.getPumpHistory`'s shape, as TDD reads it) says the pump delivered between
    /// `start` and `end`: boluses, for the part of their delivery inside the span at the pump's `bolusDeliveryRate`
    /// (units per second; 0 counts each at its start); a finalized temp basal by the total the pump reported, its pulse
    /// rounding included, in proportion where the span cuts it; otherwise basal minute by minute from running temps,
    /// suspensions and the scheduled profile.
    static func expectedDelivery(
        from start: Date,
        to end: Date,
        history: [PumpHistoryEvent],
        basalProfile: [BasalProfileEntry],
        bolusDeliveryRate: Double,
        calendar: Calendar = .current
    ) -> Decimal {
        let events = history.sorted { $0.timestamp < $1.timestamp }

        // one still running at either edge, as one the phone started just before the watch took over without it
        // insulin entered by hand (pen, syringe) never went through the pump: on 3 November a third tester's 1 U
        // entered on the phone showed as 1.03 U the pump hadn't delivered
        let boluses = events.filter {
            [.bolus, .smb].contains($0.type) && $0.isExternal != true && $0.isExternalInsulin != true
        }.reduce(Decimal(0)) { sum, bolus in
            let units = bolus.deliveredUnits ?? bolus.amount ?? 0
            let length = bolusDeliveryRate > 0 ? NSDecimalNumber(decimal: units).doubleValue / bolusDeliveryRate : 0
            guard length > 0 else { return bolus.timestamp >= start && bolus.timestamp < end ? sum + units : sum }
            let overlap = min(bolus.timestamp.addingTimeInterval(length), end).timeIntervalSince(max(bolus.timestamp, start))
            return overlap > 0 ? sum + units * Decimal(overlap / length) : sum
        }

        let tempEvents = events.filter { $0.type == .tempBasal && $0.isScheduledBasal != true }
        // a temp runs to its own end or until the next one starts, whichever comes first
        let temps = tempEvents.enumerated().map { index, event in
            let ownEnd = event.timestamp.addingTimeInterval(Double(event.duration ?? 0) * 60)
            let next = index + 1 < tempEvents.count ? tempEvents[index + 1].timestamp : ownEnd
            return (start: event.timestamp, end: min(ownEnd, next), rate: event.amount ?? 0, reported: event.deliveredUnits)
        }
        let reportedTemps = temps.reduce(Decimal(0)) { sum, temp in
            guard let reported = temp.reported, temp.end > temp.start else { return sum }
            let overlap = min(temp.end, end).timeIntervalSince(max(temp.start, start))
            guard overlap > 0 else { return sum }
            return sum + reported * Decimal(overlap / temp.end.timeIntervalSince(temp.start))
        }
        let suspensions = events.filter { $0.type == .pumpSuspend || $0.type == .pumpResume }
        let profile = basalProfile.sorted { $0.minutes < $1.minutes }

        var basal: Decimal = 0
        var time = start
        while time < end {
            let step = min(60, end.timeIntervalSince(time))
            let rate: Decimal
            if suspensions.last(where: { $0.timestamp <= time })?.type == .pumpSuspend {
                rate = 0
            } else if let temp = temps.last(where: { $0.start <= time }), time < temp.end {
                // a reported temp is counted by its total
                rate = temp.reported == nil ? temp.rate : 0
            } else {
                let minute = calendar.component(.hour, from: time) * 60 + calendar.component(.minute, from: time)
                rate = profile.last(where: { $0.minutes <= minute })?.rate ?? profile.first?.rate ?? 0
            }
            basal += rate * Decimal(step) / 3600
            time = time.addingTimeInterval(step)
        }
        return boluses + reportedTemps + basal
    }
}

/// The pump's delivered total at a session's start and at its return. Kept until the watch's last records are in,
/// so the complete history judges the same span again.
struct UntetheredAuditPoint: Codable, Equatable {
    let epoch: Int
    let start: Date
    let startUnits: Double
    let end: Date
    let endUnits: Double

    var delivered: Decimal { Decimal(endUnits - startUnits) }
}
