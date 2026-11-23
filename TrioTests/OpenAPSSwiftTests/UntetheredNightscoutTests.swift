import Foundation
import Testing
@testable import Trio

/// The untethered watch's own Nightscout upload: what it sends must look like the phone's upload of the same loop, or
/// followers would see two kinds of status, and the phone must recognise what the watch already uploaded.
@Suite("Untethered watch mode: Nightscout upload from the watch") struct UntetheredNightscoutTests {
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    let credentials = UntetheredNightscoutCredentials(
        url: URL(string: "https://example.invalid:1337/some/path")!,
        secretHash: "0123456789abcdef0123456789abcdef01234567",
        uploadsGlucose: true
    )

    func reading(_ minutesAfterT0: Double, _ mgdl: Int) -> BloodGlucose {
        let date = t0.addingTimeInterval(minutesAfterT0 * 60)
        return BloodGlucose(
            sgv: mgdl,
            direction: .flat,
            date: Decimal(Int(date.timeIntervalSince1970 * 1000)),
            dateString: date,
            glucose: mgdl,
            type: "sgv"
        )
    }

    func determination(reason: String = "COB: 0, Dev: 18, BGI: -2, ISF: 180→170, Target: 100, minPredBG 90") throws
        -> Determination
    {
        let json = """
        {"reason": "\(reason)", "IOB": 1.25, "COB": 0, "bg": 120, "eventualBG": 110, "current_target": 100,
         "minGuardBG": 90, "minPredBG": 95, "threshold": 70, "reservoir": 87.5, "rate": 0.8, "duration": 30,
         "deliverAt": "2026-10-27T08:13:20.000Z", "predBGs": {"IOB": [120, 118, 116]}}
        """
        return try JSONCoding.decoder.decode(Determination.self, from: Data(json.utf8))
    }

    func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Credentials

    @Test("credentials: round trip through the watch state; empty or incomplete means none")
    func credentialsDictionary() {
        #expect(UntetheredNightscoutCredentials(dictionary: credentials.dictionary) == credentials)
        #expect(UntetheredNightscoutCredentials(dictionary: [:]) == nil)
        #expect(UntetheredNightscoutCredentials(dictionary: ["url": "not a url", "secretHash": "abc"]) == nil)
        #expect(UntetheredNightscoutCredentials(dictionary: ["url": "https://example.invalid", "secretHash": ""]) == nil)
        // from a phone build that didn't send the glucose setting: uploads glucose, as the phone's default
        let old = UntetheredNightscoutCredentials(dictionary: ["url": "https://example.invalid", "secretHash": "abc"])
        #expect(old?.uploadsGlucose == true)
    }

    @Test("request: as NightscoutAPI, scheme, host and port with the API path, the secret hash as api-secret")
    func request() throws {
        let request = try #require(
            UntetheredNightscout.request(path: UntetheredNightscout.entriesPath, body: Data("[]".utf8), credentials: credentials, timeout: 12)
        )
        #expect(request.url?.absoluteString == "https://example.invalid:1337/api/v1/entries.json")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "api-secret") == credentials.secretHash)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 12)
    }

    // MARK: - Entries

    @Test("entries: only readings after the last upload, oldest first, the newest 100 at most")
    func entries() {
        let readings = (0 ..< 150).map { reading(Double($0) * 5, 100 + $0 % 20) }.shuffled()
        let now = t0.addingTimeInterval(150 * 5 * 60)

        let first = UntetheredNightscout.entries(readings, after: nil, now: now)
        #expect(first.count == UntetheredNightscout.maxEntries)
        #expect(first.map(\.dateString) == first.map(\.dateString).sorted())
        #expect(first.last?.dateString == t0.addingTimeInterval(149 * 5 * 60))

        let next = UntetheredNightscout.entries(readings, after: t0.addingTimeInterval(140 * 5 * 60), now: now)
        #expect(next.count == 9)
        #expect(next.first?.dateString == t0.addingTimeInterval(141 * 5 * 60))
    }

    @Test("entries: none older than a day, none from the future")
    func entriesWindow() {
        let now = t0.addingTimeInterval(30 * 60 * 60)
        let readings = [reading(0, 100), reading(10 * 60, 110), reading(30 * 60 - 5, 120), reading(30 * 60 + 10, 130)]
        let entries = UntetheredNightscout.entries(readings, after: nil, now: now)
        #expect(entries.map(\.glucose) == [110, 120])
    }

    // MARK: - Device status

    @Test("status: an enacted loop as the phone uploads one synced from the watch")
    func enactedStatus() throws {
        let enactedAt = Date(timeIntervalSince1970: 1_793_088_810) // 2026-10-27T08:13:30Z
        let data = try UntetheredNightscout.deviceStatus(
            determination: try determination(),
            enactedAt: enactedAt,
            automates: true,
            units: .mgdL,
            bolusIncrement: 0.05,
            dosingMode: "closed",
            version: "1.0.2"
        )
        let status = try object(data)
        #expect(status["device"] as? String == "Trio")
        #expect(status["created_at"] as? String == "2026-10-27T08:13:30.000Z")

        let openaps = try #require(status["openaps"] as? [String: Any])
        #expect(openaps["dosingMode"] as? String == "closed")
        #expect(openaps["version"] as? String == "1.0.2")
        let suggested = try #require(openaps["suggested"] as? [String: Any])
        #expect(suggested["timestamp"] as? String == "2026-10-27T08:13:20.000Z")
        #expect(suggested["received"] == nil)
        let enacted = try #require(openaps["enacted"] as? [String: Any])
        #expect(enacted["received"] as? Bool == true)
        #expect(enacted["timestamp"] as? String == "2026-10-27T08:13:30.000Z")
        #expect(enacted["rate"] as? Double == 0.8)
        let iob = try #require(openaps["iob"] as? [String: Any])
        #expect(iob["iob"] as? Double == 1.25)

        let pump = try #require(status["pump"] as? [String: Any])
        #expect(pump["reservoir"] as? Double == 87.5)
        #expect(pump["bolusIncrement"] as? Double == 0.05)
        #expect(pump["battery"] == nil)
        #expect(status["uploader"] == nil)
    }

    @Test("status: no enacted part when the pump didn't take it, or the loop doesn't dose")
    func suggestedOnly() throws {
        for (enactedAt, automates) in [(nil, true), (t0, false)] as [(Date?, Bool)] {
            let data = try UntetheredNightscout.deviceStatus(
                determination: try determination(),
                enactedAt: enactedAt,
                automates: automates,
                units: .mgdL,
                bolusIncrement: 0.05,
                dosingMode: automates ? "closed" : "open",
                version: "1.0.2"
            )
            let openaps = try #require(try object(data)["openaps"] as? [String: Any])
            #expect(openaps["enacted"] == nil)
            #expect(openaps["suggested"] != nil)
        }
        // stamped with the loop's time when nothing was enacted
        let data = try UntetheredNightscout.deviceStatus(
            determination: try determination(), enactedAt: nil, automates: true, units: .mgdL, bolusIncrement: 0.05,
            dosingMode: "closed", version: "1.0.2"
        )
        #expect(try object(data)["created_at"] as? String == "2026-10-27T08:13:20.000Z")
    }

    @Test("status: in mmol/L the reason and the targets are converted, the readings and forecasts stay in mg/dL")
    func mmolStatus() throws {
        let data = try UntetheredNightscout.deviceStatus(
            determination: try determination(),
            enactedAt: nil,
            automates: true,
            units: .mmolL,
            bolusIncrement: 0.05,
            dosingMode: "closed",
            version: "1.0.2"
        )
        let suggested = try #require((try object(data)["openaps"] as? [String: Any])?["suggested"] as? [String: Any])
        let reason = try #require(suggested["reason"] as? String)
        #expect(reason.contains("ISF: 10→9.4"))
        #expect(reason.contains("Target: 5.6"))
        #expect(reason.contains("Dev: 1"))
        #expect(suggested["current_target"] as? Double == 5.6)
        #expect(suggested["minGuardBG"] as? Double == 5)
        #expect(suggested["bg"] as? Double == 120)
        // as Nightscout's forecast lines read them: IOB, ZT, COB, UAM
        #expect((suggested["predBGs"] as? [String: Any])?["IOB"] as? [Int] == [120, 118, 116])
    }

    // MARK: - History

    @Test("history: the note that the watch uploaded a loop survives the trip to the phone")
    func uploadedRecord() throws {
        let deliverAt = Date(timeIntervalSince1970: 1_793_088_800)
        let record = UntetheredRecord(
            key: UntetheredRecord.nightscoutKey(deliverAt),
            date: deliverAt.addingTimeInterval(15),
            kind: .nightscoutUploaded(deliverAt)
        )
        let decoded = try JSONDecoder().decode(UntetheredRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
        #expect(record.key == "ns:1793088800")
        // its own key: a loop's determination record isn't replaced by the note
        #expect(record.key != UntetheredRecord.determinationKey(deliverAt))
    }

    // MARK: - Overrides and temp targets

    func tempTarget(_ minutesAfterT0: Double, target: Decimal, duration: Decimal) -> TempTarget {
        TempTarget(
            name: TempTarget.custom, createdAt: t0.addingTimeInterval(minutesAfterT0 * 60), targetTop: target,
            targetBottom: target, duration: duration, enteredBy: TempTarget.local, reason: TempTarget.custom,
            isPreset: false, enabled: true, halfBasalTarget: 160
        )
    }

    @Test("temp targets: as the phone uploads them, cut short by a cancel or a newer one, none from before the session")
    func tempTargets() {
        let targets = [
            tempTarget(-60, target: 150, duration: 30), // before the session, ran out: the phone uploaded it
            tempTarget(10, target: 108, duration: 420),
            tempTarget(18, target: 108, duration: 10), // replaces the first after 8 min
            TempTarget.cancel(at: t0.addingTimeInterval(22 * 60)) // ends the second after 4 min
        ]
        let treatments = UntetheredNightscout.tempTargetTreatments(targets, since: t0, latest: t0.addingTimeInterval(3600))
        #expect(treatments.map(\.eventType) == ["Temporary Target", "Temporary Target"])
        #expect(treatments.map(\.duration) == [8, 4])
        #expect(treatments.first?.targetTop == 108)
        #expect(treatments.first?.targetBottom == 108)
        #expect(treatments.first?.enteredBy == "Trio")
    }

    @Test("temp targets: one from before the session that the watch cancelled goes up with the minutes it ran")
    func tempTargetFromBefore() {
        let targets = [tempTarget(-20, target: 150, duration: 60), TempTarget.cancel(at: t0.addingTimeInterval(5 * 60))]
        let treatments = UntetheredNightscout.tempTargetTreatments(targets, since: t0, latest: t0.addingTimeInterval(3600))
        #expect(treatments.map(\.duration) == [25])
    }

    @Test("overrides: as Exercise with the name in notes, ended ones with the minutes they ran")
    func overrides() {
        let runs = [
            UntetheredNightscout.OverrideRun(name: "Low treatment", start: t0.addingTimeInterval(60), minutes: 1),
            UntetheredNightscout.OverrideRun(name: "Weaker", start: t0.addingTimeInterval(120), minutes: 43200)
        ]
        let treatments = UntetheredNightscout.treatments(
            pumpHistory: [], carbs: [], since: t0, now: t0.addingTimeInterval(600), overrides: runs
        )
        #expect(treatments.map(\.eventType) == ["Exercise", "Exercise"])
        #expect(treatments.map(\.notes) == ["Low treatment", "Weaker"])
        #expect(treatments.map(\.duration) == [1, 43200])
    }
}
