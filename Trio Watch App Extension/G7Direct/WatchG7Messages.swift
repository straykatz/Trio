import Foundation

/// `LocalizedString` as the vendored G7SensorKit files call it. In the plugin it
/// looks strings up in the framework bundle; on the watch they live in the app.
func LocalizedString(_ key: String, tableName: String? = nil, value: String? = nil, comment: String) -> String {
    if let value = value {
        return NSLocalizedString(key, tableName: tableName, bundle: .main, value: value, comment: comment)
    } else {
        return NSLocalizedString(key, tableName: tableName, bundle: .main, comment: comment)
    }
}

/// The sensor's answer to a glucose request (opcode 0x4E), parsed as
/// G7SensorKit's `G7GlucoseMessage` parses it, without the LoopKit types.
struct WatchG7GlucoseMessage: Equatable {
    /// Nonzero when the sensor has no current reading (e.g. 0x80 from a failed sensor).
    let status: UInt8
    let glucose: UInt16?
    let glucoseIsDisplayOnly: Bool
    /// Seconds since the sensor session started, when the message was sent.
    let messageTimestamp: UInt32
    let algorithmState: AlgorithmState
    let sequence: UInt16
    /// mg/dL per minute.
    let trend: Double?
    /// Seconds between the reading and the message.
    let age: UInt16

    var hasReliableGlucose: Bool {
        algorithmState.hasReliableGlucose
    }

    init?(data: Data) {
        //    0  1  2 3 4 5  6 7  8  9 1011 1213 14 15 1617 18
        //         TTTTTTTT SQSQ       AGAG BGBG SS TR PRPR C
        guard data.count >= 19, data[data.startIndex] == G7Opcode.glucoseTx.rawValue else {
            return nil
        }
        let bytes = Data(data) // re-based so indices start at 0

        status = bytes[1]
        messageTimestamp = bytes[2 ..< 6].toInt()
        sequence = bytes[6 ..< 8].to(UInt16.self)
        age = bytes[10 ..< 12].to(UInt16.self)

        let glucoseData = bytes[12 ..< 14].to(UInt16.self)
        if glucoseData != 0xFFFF, status == 0 {
            glucose = glucoseData & 0xFFF
            glucoseIsDisplayOnly = (bytes[18] & 0x10) > 0
        } else {
            glucose = nil
            glucoseIsDisplayOnly = false
        }

        algorithmState = AlgorithmState(rawValue: bytes[14])

        if bytes[15] == 0x7F || status != 0 {
            trend = nil
        } else {
            trend = Double(Int8(bitPattern: bytes[15])) / 10
        }
    }
}

/// One 9-byte backfill record, as G7SensorKit's `G7BackfillMessage` parses it.
struct WatchG7BackfillRecord: Equatable {
    /// Seconds since the sensor session started.
    let timestamp: UInt32
    let glucose: UInt16?
    let algorithmState: AlgorithmState
    let trend: Double?

    var hasReliableGlucose: Bool {
        algorithmState.hasReliableGlucose
    }

    init?(data: Data) {
        //    0 1 2  3  4 5  6  7  8
        //   TTTTTT    BGBG SS    TR
        guard data.count == 9 else {
            return nil
        }
        let bytes = Data(data)

        // Three bytes, little-endian.
        timestamp = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16

        let glucoseBytes = bytes[4 ..< 6].to(UInt16.self)
        glucose = glucoseBytes != 0xFFFF ? glucoseBytes & 0xFFF : nil

        algorithmState = AlgorithmState(rawValue: bytes[6])

        if bytes[8] == 0x7F {
            trend = nil
        } else {
            trend = Double(Int8(bitPattern: bytes[8])) / 10
        }
    }
}

/// A reading the watch took itself, in mg/dL.
struct WatchG7Reading: Codable, Equatable {
    let date: Date
    let glucose: Int
    /// mg/dL per minute.
    let trendRate: Double?

    /// The Nightscout direction names the watch app already understands.
    var trendName: String? {
        // Beyond 8 mg/dL/min the Dexcom apps show no arrow; neither do we.
        guard let rate = trendRate, abs(rate) <= 8 else { return nil }
        switch rate {
        case ...(-3.0): return "DoubleDown"
        case ...(-2.0): return "SingleDown"
        case ...(-1.0): return "FortyFiveDown"
        case ..<1.0: return "Flat"
        case ..<2.0: return "FortyFiveUp"
        case ..<3.0: return "SingleUp"
        default: return "DoubleUp"
        }
    }
}
