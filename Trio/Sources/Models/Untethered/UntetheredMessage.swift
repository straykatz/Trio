import CryptoKit
import Foundation
#if canImport(LoopKit)
    import LoopKit
#endif

/// What the phone and the watch tell each other about untethered watch mode.
enum UntetheredMessage: Codable, Equatable {
    case prepare(UntetheredGrant)
    case prepared
    case rejected(reason: String)
    case commit(UntetheredHandover)
    case takeoverComplete(UntetheredPodStatus)
    case takeoverFailed(reason: String)
    case records([UntetheredRecord])
    /// The phone stored these record versions; the watch drops their payloads and keeps only the sync entries.
    case recordsStored([UUID])
    case syncRequest(bucketStart: Int, checksums: [Int])
    case syncDone
    case endRequest
    case handback(UntetheredPodStatus?)
    case handbackAck
    case revoke
    /// The watch let go of the pump in an emergency stop.
    case released(UntetheredPodStatus?)
    case statusQuery
    /// The takeover status while the watch holds the pump, nil when it doesn't.
    case statusReport(holding: UntetheredPodStatus?)
    /// Started from the wrist: the phone runs its own start, as from its settings.
    case startRequest
    /// The phone's checks refused the start asked for from the wrist.
    case startRefused(reason: String)
    /// Cancelled on the phone: the override or temp target that started at `start` ends at `at` on the watch too.
    case adjustmentCancelled(UntetheredAdjustment, start: Date, at: Date)
    /// The active dosing mode changed on either side while the watch owns the pump.
    case dosingModeChanged(DosingMode)
    /// The grant the watch starts from without the phone: issued expired while the phone has the pump, refreshed
    /// as the phone doses and its settings change. Only the newest is kept.
    case standingGrant(UntetheredGrant, issuedAt: Date)
    /// The watch has no standing grant young enough to start from: the phone sends one at once.
    case standingGrantRequest
    /// The watch hasn't reached the pod for this long while readings came in: the phone takes the pump back as with
    /// Take Back the Pump Now, as it reaches a pod the watch's background links can't (2026-10-21, 00:45 to 05:56).
    case handbackRequested(minutesWithoutLoop: Int)
    /// A remote bolus or meal (LoopFollow, Nightscout) that reached the phone while the watch has the pump: the watch
    /// checks it as the phone checks one, with its own IOB and history, and delivers it.
    case remoteTreatment(UntetheredRemoteTreatment)
    /// The watch's answer, which the phone passes back to the sender (treatments and adjustments alike).
    case remoteTreatmentResult(id: UUID, delivered: Bool, message: String)
    /// A remote override or temp target (start or cancel) while the watch has the pump.
    case remoteAdjustment(UntetheredRemoteAdjustment)
}

/// A remote override or temp target, started or cancelled from LoopFollow or Nightscout while the watch has the pump:
/// it applies them to its own loop, and the phone takes them over with the watch's history.
struct UntetheredRemoteAdjustment: Codable, Equatable {
    enum Action: Codable, Equatable {
        /// By preset name, as the phone's remote control starts one.
        case startOverride(name: String)
        case cancelOverride
        /// A custom target in mg/dL for its minutes, as the phone's remote control sets one.
        case startTempTarget(targetMgdl: Decimal, minutes: Decimal)
        case cancelTempTarget
    }

    let id: UUID
    let sentAt: Date
    let action: Action

    var summary: String {
        switch action {
        case let .startOverride(name): return "start override \(name)"
        case .cancelOverride: return "cancel override"
        case let .startTempTarget(target, minutes): return "temp target \(target) mg/dL for \(minutes) min"
        case .cancelTempTarget: return "cancel temp target"
        }
    }

    /// The same for the phone's copy and the one sent straight to the watch (`UntetheredRemoteTreatment.id`).
    static func id(sentAt: TimeInterval, commandType: String, overrideName: String?, target: Int?, duration: Int?) -> UUID {
        UntetheredRemoteTreatment.id(
            sentAt: sentAt,
            commandType: commandType + "|" + (overrideName ?? ""),
            bolus: nil,
            carbs: target,
            fat: duration,
            protein: nil
        )
    }
}

/// A remote bolus or meal on its way to the watch. Sent interactively and queued as well: the watch acts on the
/// first copy that arrives and ignores the other one.
struct UntetheredRemoteTreatment: Codable, Equatable {
    let id: UUID
    /// When the command was sent, not received: the watch refuses it once it is older than `window`, and counts the
    /// boluses and carbs entered since, as the phone does.
    let sentAt: Date
    let bolus: Decimal?
    let carbs: Decimal?
    let fat: Decimal?
    let protein: Decimal?
    /// A meal's own time, when it was given one.
    let carbsDate: Date?

    /// As the phone's remote control (`TrioRemoteControl.timeWindow`).
    static let window: TimeInterval = 600

    /// The same for the copy the phone passes on and the copy sent straight to the watch, so the watch acts on one.
    static func id(sentAt: TimeInterval, commandType: String, bolus: Decimal?, carbs: Int?, fat: Int?, protein: Int?) -> UUID {
        let text = "\(sentAt)|\(commandType)|\(bolus.map { "\($0)" } ?? "-")|\(carbs ?? -1)|\(fat ?? -1)|\(protein ?? -1)"
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // name-based (version 5 layout)
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    var summary: String {
        var parts: [String] = []
        if let bolus, bolus > 0 { parts.append("bolus \(bolus) U") }
        if let carbs, carbs > 0 { parts.append("carbs \(carbs) g") }
        if let fat, fat > 0 { parts.append("fat \(fat) g") }
        if let protein, protein > 0 { parts.append("protein \(protein) g") }
        return parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
    }
}

enum UntetheredAdjustment: String, Codable {
    case override
    case tempTarget
}

struct UntetheredPodStatus: Codable, Equatable {
    let date: Date
    let deliveredUnits: Double?
    let reservoir: Double?
    /// Hand-back: the temp basal the watch cancelled before letting go.
    var tempBasal: UntetheredTempBasal? = nil
    /// Hand-back: a high temp the watch left running, for the phone to cancel once it has the pod.
    var runningHighTemp: UntetheredTempBasal? = nil
    /// Start without the phone: when the standing grant's pump copy was taken. The phone's doses started after it
    /// never reached the watch, which doesn't take them over.
    var copyAsOf: Date? = nil
}

/// The pump as the phone let go of it, a moment before the commit: the grant's configuration is older, and a temp
/// basal set since would reach the watch as a dose in flight that the pod no longer runs.
struct UntetheredHandover: Codable, Equatable {
    let pumpConfiguration: Data?
    let tempBasal: UntetheredTempBasal?
    /// The phone's deadline for the takeover (`UntetheredSession.takeoverLease` from the watch's answer): the watch
    /// lets go if it hasn't reached the pump by then, and the phone doesn't take it back before then without word from
    /// the watch. Optional so a commit from an older phone build still reads.
    var leaseExpiresAt: Date? = nil
    /// When the phone sent the commit, by its clock: with the deadline, the watch logs how far the two clocks and the
    /// delivery put it from the phone's view, should a start ever fail at the edge of the lease.
    var committedAt: Date? = nil
}

/// A temp basal handed over: the side letting go cancels it, so its record ends where the pod stopped it; the side
/// taking over sets it again for what was left, as its own dose, which it tracks and later ends itself. A high one is
/// never set again (`handOverTempBasal`).
struct UntetheredTempBasal: Codable, Equatable {
    let unitsPerHour: Double
    let endsAt: Date
    /// Of the dose as recorded, so the phone can end the watch's record of a temp it cancelled.
    var syncIdentifier: String? = nil

    /// Above the scheduled rate. Set again on the other side it would run at least the pump's shortest temp, longer than
    /// it had left, should that side not loop.
    func isHigh(scheduledRate: Decimal) -> Bool {
        Decimal(unitsPerHour) > scheduledRate
    }

    /// What was left, nil once over, rounded up to a duration the pump takes (`supportedTempBasalDurations`, shortest
    /// first; the longest at most): the new owner's next loop sets its own well before the extra time runs.
    func remainingDuration(at now: Date, supportedDurations: [TimeInterval]) -> TimeInterval? {
        let left = endsAt.timeIntervalSince(now)
        guard left > 0 else { return nil }
        return supportedDurations.first { $0 >= left } ?? supportedDurations.last
    }
}

#if canImport(LoopKit)
extension PumpManager {
    /// The running temp basal at a hand-over. A low or zero one is cancelled and returned to be set again on the other
    /// side. A high one is never set again: cancelled here when `cancellingHigh`, otherwise left running and returned
    /// as `leftRunning` for the phone to cancel once it has the pod, as LoopKit/Loop#2545 does. Both nil when none ran,
    /// or when the pump didn't take the cancel, which leaves it running as before.
    func handOverTempBasal(
        scheduledRate: Decimal,
        cancellingHigh: Bool
    ) async -> (resume: UntetheredTempBasal?, leftRunning: UntetheredTempBasal?) {
        guard case let .tempBasal(dose) = status.basalDeliveryState, dose.endDate > Date() else { return (nil, nil) }
        let temp = UntetheredTempBasal(unitsPerHour: dose.unitsPerHour, endsAt: dose.endDate, syncIdentifier: dose.syncIdentifier)
        let isHigh = temp.isHigh(scheduledRate: scheduledRate)
        if isHigh, !cancellingHigh { return (nil, temp) }
        guard await cancelTempBasal() == nil else { return (nil, nil) }
        return (isHigh ? nil : temp, nil)
    }

    /// Cancels whatever temp basal the pod runs, one this controller set or another's.
    func cancelTempBasal() async -> PumpManagerError? {
        await withCheckedContinuation { continuation in
            enactTempBasal(decisionId: nil, unitsPerHour: 0, for: 0) { continuation.resume(returning: $0) }
        }
    }

    /// Sets a handed-over temp basal again for what was left: the pump's error, or nil when set or already over.
    func resumeTempBasal(_ temp: UntetheredTempBasal) async -> PumpManagerError? {
        guard let durations = (self as? PumpDeliveryOdometer)?.supportedTempBasalDurations,
              let duration = temp.remainingDuration(at: Date(), supportedDurations: durations)
        else { return nil }
        return await withCheckedContinuation { continuation in
            enactTempBasal(decisionId: nil, unitsPerHour: temp.unitsPerHour, for: duration) { continuation.resume(returning: $0) }
        }
    }
}
#endif

/// Everything the watch needs to run the loop: the pump and CGM, therapy settings and 24 h of history.
struct UntetheredGrant: Codable, Equatable {
    let leaseExpiresAt: Date
    /// LoopKit `SharedDeviceConfiguration.rawValue`, as binary property lists.
    let pumpConfiguration: Data
    let cgmConfiguration: Data

    let pumpSettings: PumpSettings
    let bgTargets: BGTargets
    let basalProfile: [BasalProfileEntry]
    let insulinSensitivities: InsulinSensitivities
    let carbRatios: CarbRatios
    let preferences: Preferences
    var dosingMode: DosingMode
    let smoothGlucose: Bool
    let units: GlucoseUnits
    let tdd: OrefPipeline.TDDSummary
    /// Without enough days of TDD the dynamic ISF formulas stay off, as on the phone.
    let hasSufficientTDD: Bool
    /// The phone's TDD rows of the last two hours, zeros included, and its ten days of rows by the hour, so the
    /// watch keeps the averages moving with its own rows. Optional only so a grant saved before it still reads.
    let tddRecentRows: [UntetheredTDD]
    let tddHours: [UntetheredTDDHour]?
    /// The last day of pump history in the shape TDD is calculated from (`PumpHistoryStorage.getPumpHistory`).
    let tddPumpHistory: [PumpHistoryEvent]
    let autosens: Autosens?
    let reservoir: Decimal?
    let maxBolus: Decimal
    let maxCarbs: Decimal
    let bolusCalculator: UntetheredBolusCalculatorSettings
    /// `GlucoseColorScheme.rawValue`, so the watch colors readings as the phone does.
    let glucoseColorScheme: String
    /// The phone's last loop, so the watch shows IOB, COB and the forecast until its own first loop.
    let lastDetermination: Determination?
    let lastLoopDate: Date?
    /// mg/dL
    let lowGlucose: Decimal
    let highGlucose: Decimal

    let pumpHistory: [PumpHistoryEvent]
    /// Raw readings, so the phone gets the originals back.
    let glucose: [BloodGlucose]
    /// The phone's smoothed value per reading id, when smoothing is on.
    let smoothedGlucose: [String: Decimal]
    let carbs: [CarbsEntry]
    let activeOverride: Override?
    /// The temp targets file the algorithm reads; the newest entry decides.
    let tempTargets: [TempTarget]
    let overridePresets: [Override]
    let tempTargetPresets: [TempTarget]
    let linkedOverrideID: String?
}

/// One TDD calculation, as `TDDStored` keeps it.
struct UntetheredTDD: Codable, Equatable {
    let date: Date
    let total: Decimal
    let bolus: Decimal
    let tempBasal: Decimal
    let scheduledBasal: Decimal
    let weightedAverage: Decimal?
}

/// The TDD rows of one hour: the ten-day averages drop each hour as it leaves the window, as the phone's drop each row.
struct UntetheredTDDHour: Codable, Equatable {
    let start: Date
    var total: Decimal
    /// Rows above 0, which the algorithm's averages count (`OpenAPS.tddSummary`).
    var positive: Int
    /// Every row, which the stored weighted average counts (`BaseTDDStorage.calculateWeightedAverage`).
    var count: Int

    static let window: TimeInterval = 10 * 24 * 60 * 60

    static func hours(_ rows: [UntetheredTDD]) -> [UntetheredTDDHour] {
        var hours: [UntetheredTDDHour] = []
        for row in rows.sorted(by: { $0.date < $1.date }) {
            add(row, to: &hours)
        }
        return hours
    }

    static func add(_ row: UntetheredTDD, to hours: inout [UntetheredTDDHour]) {
        let start = Date(timeIntervalSince1970: (row.date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        if let last = hours.indices.last, hours[last].start == start {
            hours[last].total += row.total
            hours[last].positive += row.total > 0 ? 1 : 0
            hours[last].count += 1
        } else {
            hours.append(UntetheredTDDHour(start: start, total: row.total, positive: row.total > 0 ? 1 : 0, count: 1))
        }
    }

    /// The hours of the last ten days; the oldest counts while most of it is inside, half an hour off at most.
    static func inWindow(_ hours: [UntetheredTDDHour], now: Date) -> [UntetheredTDDHour] {
        hours.filter { $0.start.addingTimeInterval(30 * 60) > now.addingTimeInterval(-window) }
    }
}

/// The phone's bolus calculator settings, so the watch recommends what the phone would.
struct UntetheredBolusCalculatorSettings: Codable, Equatable {
    let fraction: Decimal
    let fattyMeals: Bool
    let fattyMealFactor: Decimal
    let sweetMeals: Bool
    let sweetMealFactor: Decimal
}

/// One message on the wire: LZFSE-compressed JSON under a single WatchConnectivity key.
struct UntetheredEnvelope: Codable, Equatable {
    static let key = "untethered"

    let epoch: Int
    let message: UntetheredMessage
    /// The sender's app version and build (`UntetheredVersion.current`); nil from a build before the check.
    var appVersion: String?

    init(epoch: Int, message: UntetheredMessage, appVersion: String? = UntetheredVersion.current) {
        self.epoch = epoch
        self.message = message
        self.appVersion = appVersion
    }

    func payload() throws -> [String: Any] {
        let json = try JSONEncoder().encode(self)
        return [Self.key: try (json as NSData).compressed(using: .lzfse) as Data]
    }

    /// nil: not an untethered message.
    static func decode(_ payload: [String: Any]) throws -> UntetheredEnvelope? {
        guard let data = payload[key] as? Data else { return nil }
        let json = try (data as NSData).decompressed(using: .lzfse) as Data
        return try JSONDecoder().decode(UntetheredEnvelope.self, from: json)
    }
}

/// The phone and the watch hand the pump over only when they run the same build. The watch app is built and
/// numbered with the phone app, but watchOS installs it separately and in its own time, sometimes minutes after the
/// phone's update: meanwhile the old watch app answered the new phone app's start late or not at all (2026-10-21
/// 01:46), and two builds may not read each other's grant, records or hand-back the same way.
enum UntetheredVersion {
    /// "1.0.2.15 (579)": the version and build both apps carry. nil without them (tests).
    static var current: String? {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else { return nil }
        return "\(version) (\(build))"
    }

    /// Why no hand-over can start, when the other side's build differs from this one's; nil when they match or this
    /// build doesn't know its own (tests). A sender without a version is a build from before the check.
    static func mismatch(phone: String?, watch: String?) -> String? {
        guard let phone, let watch, phone != watch else { return nil }
        if let phoneBuild = build(of: phone), let watchBuild = build(of: watch), watchBuild > phoneBuild {
            // the iPhone still has the older build: closing Trio on the watch won't help
            return String(
                localized: "Trio on the iPhone (\(phone)) and on the watch (\(watch)) are different builds. Install the same build on the iPhone, then start again."
            )
        }
        return String(
            localized: "Trio on the iPhone (\(phone)) and on the watch (\(watch)) are different builds. Wait until the watch app has updated, then start again. \(closeOnWatch)"
        )
    }

    /// How to let watchOS install the watch app: it waits while Trio runs there, and Trio on the watch never stops by
    /// itself while it reads the sensor (third tester, 11 November: the update waited for hours, until Trio was closed).
    static var closeOnWatch: String {
        String(
            localized: "If it doesn't, close Trio on the watch: hold the side button until the power-off screen shows, then hold the Digital Crown until Trio closes. Keep the watch near the iPhone."
        )
    }

    /// The build number of "1.0.2.69 (760)"; nil without one.
    static func build(of version: String?) -> Int? {
        guard let version, let open = version.lastIndex(of: "("), let close = version.lastIndex(of: ")"), open < close
        else { return nil }
        return Int(version[version.index(after: open) ..< close])
    }

    /// Whether the phone's build is newer than the watch app's: then the watch app waits for watchOS to update it.
    static func phoneIsNewer(phone: String?, watch: String?) -> Bool {
        guard let phoneBuild = build(of: phone), let watchBuild = build(of: watch) else { return false }
        return phoneBuild > watchBuild
    }

    /// From the phone's side: the watch's build against this one.
    static func mismatch(watch: String?) -> String? {
        guard current != nil else { return nil }
        return mismatch(phone: current, watch: watch ?? String(localized: "an older build"))
    }

    /// From the watch's side: the phone's build against this one.
    static func mismatch(phone: String?) -> String? {
        guard current != nil else { return nil }
        return mismatch(phone: phone ?? String(localized: "an older build"), watch: current)
    }
}

/// A large envelope (the grant) travels as several interactive messages: WatchConnectivity refuses one
/// near 65 KB. The receiver reassembles them in any order; the reply of the completing part answers.
enum UntetheredChunks {
    static let key = "untetheredChunk"
    static let partSize = 48000

    /// nil when the payload fits one message.
    static func split(_ payload: [String: Any]) -> [[String: Any]]? {
        guard let data = payload[UntetheredEnvelope.key] as? Data, data.count > partSize else { return nil }
        let id = UUID().uuidString
        let parts = stride(from: 0, to: data.count, by: partSize).map { data.subdata(in: $0 ..< min($0 + partSize, data.count)) }
        return parts.enumerated().map { index, part in
            [key: part, "id": id, "index": index, "count": parts.count]
        }
    }

    final class Assembler {
        private var parts: [String: [Int: Data]] = [:]

        /// The whole payload once its last part arrived.
        func add(_ message: [String: Any]) -> [String: Any]? {
            guard let part = message[key] as? Data, let id = message["id"] as? String,
                  let index = message["index"] as? Int, let count = message["count"] as? Int
            else { return nil }
            parts[id, default: [:]][index] = part
            guard let received = parts[id], received.count == count else { return nil }
            parts[id] = nil
            return [UntetheredEnvelope.key: (0 ..< count).compactMap { received[$0] }.reduce(Data(), +)]
        }
    }
}
