import Foundation

/// Where the untethered watch uploads to Nightscout by itself, while the phone is out of reach. The phone passes the
/// address and the API secret's SHA-1, which is the form Nightscout's `api-secret` header takes; the secret itself
/// stays on the phone.
struct UntetheredNightscoutCredentials: Codable, Equatable {
    static let urlKey = "url"
    static let secretHashKey = "secretHash"
    static let uploadsGlucoseKey = "uploadsGlucose"

    let url: URL
    let secretHash: String
    /// The phone's Upload Glucose setting: off, the watch uploads loop statuses only.
    let uploadsGlucose: Bool

    init(url: URL, secretHash: String, uploadsGlucose: Bool) {
        self.url = url
        self.secretHash = secretHash
        self.uploadsGlucose = uploadsGlucose
    }

    /// From the phone's watch state; nil for an empty dictionary, which tells the watch to forget them.
    init?(dictionary: [String: Any]) {
        guard let string = dictionary[Self.urlKey] as? String, let url = URL(string: string), url.host != nil,
              let secretHash = dictionary[Self.secretHashKey] as? String, !secretHash.isEmpty
        else { return nil }
        self.init(url: url, secretHash: secretHash, uploadsGlucose: dictionary[Self.uploadsGlucoseKey] as? Bool ?? true)
    }

    var dictionary: [String: Any] {
        [Self.urlKey: url.absoluteString, Self.secretHashKey: secretHash, Self.uploadsGlucoseKey: uploadsGlucose]
    }
}

/// What the watch uploads, built the way the phone's Nightscout upload builds it, so Nightscout and its followers
/// see the same thing whichever device uploaded: readings as entries, each loop as a device status.
enum UntetheredNightscout {
    static let entriesPath = "/api/v1/entries.json"
    static let statusPath = "/api/v1/devicestatus.json"
    static let treatmentsPath = "/api/v1/treatments.json"
    /// As the phone's batches; a session's first upload after a long time without Wi-Fi takes the newest.
    static let maxEntries = 100
    /// Readings older than this aren't uploaded by the watch: the phone uploads the session after the hand-back.
    static let entriesWindow: TimeInterval = 24 * 60 * 60

    /// As `NightscoutAPI`: the address's scheme, host and port with the API path.
    static func request(path: String, body: Data, credentials: UntetheredNightscoutCredentials, timeout: TimeInterval) -> URLRequest? {
        var components = URLComponents()
        components.scheme = credentials.url.scheme
        components.host = credentials.url.host
        components.port = credentials.url.port
        components.path = path
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(credentials.secretHash, forHTTPHeaderField: "api-secret")
        request.httpBody = body
        return request
    }

    /// Readings newer than the last one uploaded, oldest first, at most `maxEntries` (the newest). Nightscout keeps
    /// one entry per time and type, so the phone's upload of the same readings after the hand-back adds none.
    static func entries(_ glucose: [BloodGlucose], after last: Date?, now: Date) -> [BloodGlucose] {
        let floor = max(last ?? .distantPast, now.addingTimeInterval(-entriesWindow))
        let fresh = glucose.filter { $0.dateString > floor && $0.dateString <= now.addingTimeInterval(60) }
            .sorted { $0.dateString < $1.dateString }
        return Array(fresh.suffix(maxEntries))
    }

    /// A bolus, temp basal or carb entry in the shape the phone uploads it (`NightscoutTreatment`).
    struct Treatment: Encodable, Equatable {
        let eventType: String
        let created_at: Date
        var enteredBy = "Trio"
        var insulin: Decimal?
        var duration: Int?
        var absolute: Decimal?
        var rate: Decimal?
        var carbs: Decimal?
        var fat: Decimal?
        var protein: Decimal?
        var notes: String?
        var foodType: String?
        var id: String?
        var fpuID: String?
        var targetTop: Decimal?
        var targetBottom: Decimal?

        /// Changes when the treatment does (a bolus finishing, a temp basal, override or temp target cut short): it
        /// goes up again then.
        var fingerprint: String {
            "\(eventType)|\(created_at.timeIntervalSince1970)|\(insulin ?? 0)|\(duration ?? 0)|\(rate ?? 0)|\(carbs ?? 0)|\(fat ?? 0)|\(protein ?? 0)|\(targetTop ?? 0)|\(notes ?? "")"
        }
    }

    /// An override as Nightscout keeps it (`OverrideStorage`, `NightscoutExercise`): a running one with its planned
    /// duration, an ended one with the minutes it ran, under the same start, which replaces the first upload.
    struct OverrideRun: Codable, Equatable {
        let name: String
        let start: Date
        let minutes: Decimal
    }

    /// The phone's `OverrideStored.EventType.nsExercise`.
    static let overrideEventType = "Exercise"
    /// The phone's upload of an indefinite override: 30 days.
    static let indefiniteMinutes: Decimal = 43200

    /// Temp targets as the phone uploads them (`TempTargetsStorage`): each start with its planned duration, or with
    /// the minutes it ran (at least 1) when a cancel or a newer temp target ended it early. A cancel isn't uploaded
    /// on its own.
    static func tempTargetTreatments(_ tempTargets: [TempTarget], since: Date, latest: Date) -> [Treatment] {
        let sorted = tempTargets.sorted { $0.createdAt < $1.createdAt }
        var result: [Treatment] = []
        for (index, target) in sorted.enumerated() where target.duration > 0 {
            guard target.createdAt <= latest, let top = target.targetTop ?? target.targetBottom, top > 0 else { continue }
            let next = index + 1 < sorted.count ? sorted[index + 1].createdAt : nil
            var minutes = target.duration
            if let next {
                minutes = min(minutes, Decimal(max(1, next.timeIntervalSince(target.createdAt) / 60)))
            }
            // one from before the session goes up again only if the watch ended it early
            guard target.createdAt >= since || ((next.map { $0 >= since } ?? false) && minutes < target.duration)
            else { continue }
            result.append(Treatment(
                eventType: EventType.nsTempTarget.rawValue,
                created_at: target.createdAt,
                enteredBy: target.enteredBy ?? TempTarget.local,
                duration: NSDecimalNumber(decimal: minutes).intValue,
                notes: target.name ?? TempTarget.custom,
                targetTop: top,
                targetBottom: target.targetBottom ?? top
            ))
        }
        return result
    }

    /// The session's boluses, SMBs, temp basals and carbs from `since`, as the phone uploads them
    /// (`PumpHistoryStorage.getPumpHistoryNotYetUploadedToNightscout`, `CarbsStorage.getCarbsNotYetUploadedToNightscout`):
    /// the same `created_at` and `eventType`. Nightscout keeps one treatment per `created_at` and `eventType`, so the
    /// phone's upload of the same doses after the hand-back replaces these instead of adding to them.
    /// The phone's session entry (`NightscoutManager.uploadUntetheredSession`), for followers to show untethered mode.
    static let sessionEventType = "Untethered Watch"

    /// - Parameter sessionStart: when the watch took the pump; the session goes up as running, without a duration,
    ///   as the phone uploads it when it knows. The phone's upload with the duration at the end replaces it.
    static func treatments(
        pumpHistory: [PumpHistoryEvent],
        carbs: [CarbsEntry],
        since: Date,
        now: Date,
        sessionStart: Date? = nil,
        tempTargets: [TempTarget] = [],
        overrides: [OverrideRun] = []
    ) -> [Treatment] {
        let latest = now.addingTimeInterval(60)
        let events = pumpHistory.filter { $0.timestamp >= since && $0.timestamp <= latest }
        var result: [Treatment] = []
        for event in events {
            switch event.type {
            case .bolus,
                 .smb:
                guard let amount = event.amount else { continue }
                // as `PumpHistoryStorage.determineBolusEventType`
                let type: EventType = event.type == .smb || event.isSMB == true ? .smb
                    : event.isExternal == true ? .isExternal : .bolus
                result.append(Treatment(eventType: type.rawValue, created_at: event.timestamp, insulin: amount, id: event.id))
            case .tempBasalDuration:
                guard let rate = events.first(where: { $0.type == .tempBasal && $0.timestamp == event.timestamp })?.rate
                else { continue }
                result.append(Treatment(
                    eventType: EventType.nsTempBasal.rawValue,
                    created_at: event.timestamp,
                    duration: event.durationMin ?? 0,
                    absolute: rate,
                    rate: rate,
                    id: event.id
                ))
            default:
                continue
            }
        }
        for entry in carbs where !(entry.isFPU ?? false) {
            let date = entry.actualDate ?? entry.createdAt
            guard date >= since, date <= latest else { continue }
            result.append(Treatment(
                eventType: EventType.nsCarbCorrection.rawValue,
                created_at: date,
                enteredBy: CarbsEntry.local,
                carbs: entry.carbs,
                fat: entry.fat ?? 0,
                protein: entry.protein ?? 0,
                notes: entry.note,
                foodType: entry.note,
                id: entry.id,
                fpuID: entry.fpuID
            ))
        }
        if let sessionStart {
            result.append(Treatment(eventType: sessionEventType, created_at: sessionStart, notes: "Watch mode on Apple Watch"))
        }
        // followers (LoopFollow, Nightscout) show the running override and temp target from these
        result += tempTargetTreatments(tempTargets, since: since, latest: latest)
        for run in overrides where run.start <= latest {
            result.append(Treatment(
                eventType: overrideEventType,
                created_at: run.start,
                duration: NSDecimalNumber(decimal: max(1, run.minutes)).intValue,
                notes: run.name
            ))
        }
        return result.sorted { $0.created_at < $1.created_at }
    }

    /// One loop as a device status, as the phone uploads a loop synced from the watch
    /// (`NightscoutManager.uploadDeterminationHistory`): the suggestion at its time, the enacted one when the pump
    /// took it and the loop doses, the loop's IOB and reservoir, stamped with the loop's own time.
    static func deviceStatus(
        determination: Determination,
        enactedAt: Date?,
        automates: Bool,
        units: GlucoseUnits,
        bolusIncrement: Decimal,
        dosingMode: String,
        version: String
    ) throws -> Data {
        var determination = determination
        if units == .mmolL {
            determination.reason = reasonInMmolL(determination.reason)
            determination.current_target = determination.current_target?.asMmolL
            determination.minGuardBG = determination.minGuardBG?.asMmolL
            determination.minPredBG = determination.minPredBG?.asMmolL
            determination.threshold = determination.threshold?.asMmolL
        }
        let time = enactedAt ?? determination.deliverAt ?? Date()
        var suggested = determination
        suggested.timestamp = determination.deliverAt
        var enacted = determination
        enacted.timestamp = enactedAt
        let iob = determination.iob.map {
            IOBEntry(
                iob: $0, activity: 0, basaliob: 0, bolusiob: 0, netbasalinsulin: 0, bolusinsulin: 0,
                iobWithZeroTemp: nil, lastBolusTime: nil, lastTemp: nil, time: time
            )
        }
        let status = Status(
            device: "Trio",
            openaps: OpenAPS(
                iob: iob,
                suggested: suggested,
                enacted: automates && enactedAt != nil ? Received(determination: enacted) : nil,
                version: version,
                dosingMode: dosingMode
            ),
            pump: Pump(clock: time, reservoir: determination.reservoir, bolusIncrement: bolusIncrement),
            created_at: time
        )
        return try JSONCoding.encoder.encode(status)
    }

    private struct Status: Encodable {
        let device: String
        let openaps: OpenAPS
        let pump: Pump
        let created_at: Date
    }

    private struct OpenAPS: Encodable {
        let iob: IOBEntry?
        let suggested: Determination
        let enacted: Received?
        let version: String
        let dosingMode: String
    }

    private struct Pump: Encodable {
        let clock: Date
        let reservoir: Decimal?
        let bolusIncrement: Decimal
    }

    /// The enacted determination with `received`, as the phone's stored one has it once the pump took it.
    private struct Received: Encodable {
        let determination: Determination

        private enum Key: String, CodingKey { case received }

        func encode(to encoder: Encoder) throws {
            try determination.encode(to: encoder)
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(true, forKey: .received)
        }
    }

    /// The glucose values in a determination's reason in mmol/L, as Nightscout shows the reason.
    static func reasonInMmolL(_ reason: String) -> String {
        let patterns = [
            "(?:ISF|Target):\\s*-?\\d+\\.?\\d*(?:→-?\\d+\\.?\\d*)+",
            // ISF or Target with any number of “→value” segments after the first number
            "Dev:\\s*-?\\d+\\.?\\d*", // Dev pattern
            "BGI:\\s*-?\\d+\\.?\\d*", // BGI pattern
            "Target:\\s*-?\\d+\\.?\\d*", // Target pattern
            "(?:minPredBG|minGuardBG|IOBpredBG|COBpredBG|UAMpredBG)\\s+-?\\d+\\.?\\d*(?:<-?\\d+\\.?\\d*)?", // minPredBG, etc.
            "minGuardBG\\s+-?\\d+\\.?\\d*<-?\\d+\\.?\\d*", // minGuardBG x<y
            "Eventual BG\\s+-?\\d+\\.?\\d*\\s*>=\\s*-?\\d+\\.?\\d*", // Eventual BG x >= target
            "Eventual BG\\s+-?\\d+\\.?\\d*\\s*<\\s*-?\\d+\\.?\\d*", // Eventual BG x < target
            "\\S+\\s+\\d+\\s*>\\s*\\d+%\\s+of\\s+BG\\s+\\d+" // maxDelta x > y% of BG z
        ]
        let pattern = patterns.joined(separator: "|")
        let regex = try! NSRegularExpression(pattern: pattern)

        func convertToMmolL(_ value: String) -> String {
            if let glucoseValue = Double(value.replacingOccurrences(of: "[^\\d.-]", with: "", options: .regularExpression)) {
                let mmolValue = Decimal(glucoseValue).asMmolL
                return mmolValue.description
            }
            return value
        }

        let matches = regex.matches(in: reason, range: NSRange(reason.startIndex..., in: reason))
        var updatedReason = reason

        for match in matches.reversed() {
            guard let range = Range(match.range, in: reason) else { continue }
            let glucoseValueString = String(reason[range])

            if glucoseValueString.contains("→") {
                // Handle ISF: X→Y… or Target: X→Y→Z…
                let parts = glucoseValueString.components(separatedBy: ":")
                guard parts.count == 2 else { continue }
                let targetOrISF = parts[0].trimmingCharacters(in: .whitespaces)
                let values = parts[1]
                    .components(separatedBy: "→")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let convertedValues = values.map { convertToMmolL($0) }
                let joined = convertedValues.joined(separator: "→")
                let rebuilt = "\(targetOrISF): \(joined)"
                updatedReason.replaceSubrange(range, with: rebuilt)

            } else if glucoseValueString.contains("Eventual BG"), glucoseValueString.contains("<") {
                // Handle Eventual BG XX < target
                let parts = glucoseValueString.components(separatedBy: "<")
                if parts.count == 2 {
                    let bgPart = parts[0].replacingOccurrences(of: "Eventual BG", with: "").trimmingCharacters(in: .whitespaces)
                    let targetValue = parts[1].trimmingCharacters(in: .whitespaces)
                    let formattedBGPart = convertToMmolL(bgPart)
                    let formattedTargetValue = convertToMmolL(targetValue)
                    let formattedString = "Eventual BG \(formattedBGPart)<\(formattedTargetValue)"
                    updatedReason.replaceSubrange(range, with: formattedString)
                }

            } else if glucoseValueString.contains("<") {
                // Handle minGuardBG (or minPredBG, etc.) x < y
                let parts = glucoseValueString.components(separatedBy: "<")
                if parts.count == 2 {
                    let firstValue = parts[0].trimmingCharacters(in: .whitespaces)
                    let secondValue = parts[1].trimmingCharacters(in: .whitespaces)
                    let formattedFirstValue = convertToMmolL(firstValue)
                    let formattedSecondValue = convertToMmolL(secondValue)
                    let formattedString = "minGuardBG \(formattedFirstValue)<\(formattedSecondValue)"
                    updatedReason.replaceSubrange(range, with: formattedString)
                }

            } else if glucoseValueString.contains(">=") {
                // Handle "Eventual BG X >= Y"
                let parts = glucoseValueString.components(separatedBy: " >= ")
                if parts.count == 2 {
                    let firstValue = parts[0].replacingOccurrences(of: "Eventual BG", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    let secondValue = parts[1].trimmingCharacters(in: .whitespaces)
                    let formattedFirstValue = convertToMmolL(firstValue)
                    let formattedSecondValue = convertToMmolL(secondValue)
                    let formattedString = "Eventual BG \(formattedFirstValue) >= \(formattedSecondValue)"
                    updatedReason.replaceSubrange(range, with: formattedString)
                }

            } else if glucoseValueString.contains(">"), glucoseValueString.contains("BG") {
                // Handle "maxDelta 37 > 20% of BG 95" style
                let localPattern = "(\\d+) > (\\d+)% of BG (\\d+)"
                let localRegex = try! NSRegularExpression(pattern: localPattern)
                let localMatches = localRegex.matches(
                    in: glucoseValueString,
                    range: NSRange(glucoseValueString.startIndex..., in: glucoseValueString)
                )
                if let localMatch = localMatches.first, localMatch.numberOfRanges == 4 {
                    let range1 = Range(localMatch.range(at: 1), in: glucoseValueString)!
                    let range2 = Range(localMatch.range(at: 2), in: glucoseValueString)!
                    let range3 = Range(localMatch.range(at: 3), in: glucoseValueString)!

                    let firstValue = convertToMmolL(String(glucoseValueString[range1]))
                    let thirdValue = convertToMmolL(String(glucoseValueString[range3]))

                    let oldSnippet =
                        "\(glucoseValueString[range1]) > \(glucoseValueString[range2])% of BG \(glucoseValueString[range3])"
                    let newSnippet = "\(firstValue) > \(glucoseValueString[range2])% of BG \(thirdValue)"

                    let replaced = glucoseValueString.replacingOccurrences(of: oldSnippet, with: newSnippet)
                    updatedReason.replaceSubrange(range, with: replaced)
                }

            } else {
                // Handle everything else, e.g., "minPredBG 39", "Dev: 5", etc.
                let parts = glucoseValueString.components(separatedBy: .whitespaces)
                if parts.count >= 2 {
                    var metric = parts[0]
                    let value = parts[1]

                    // Add ":" to the metric only if it doesn't already end with ":"
                    if !metric.hasSuffix(":") {
                        metric += ":"
                    }
                    let formattedValue = convertToMmolL(value)
                    let formattedString = "\(metric) \(formattedValue)"
                    updatedReason.replaceSubrange(range, with: formattedString)
                }
            }
        }

        return updatedReason
    }
}
