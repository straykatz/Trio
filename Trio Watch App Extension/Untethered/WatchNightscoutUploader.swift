import Foundation
import Security

/// The untethered watch's own Nightscout upload, while the phone is out of reach: its readings as entries and each
/// loop as a device status, over Wi-Fi or the watch's cellular connection. Without a network nothing goes up, and the
/// phone uploads the session's history after the hand-back as it always did.
///
/// The address and the API secret's SHA-1 come from the phone with the watch state and are kept in the watch's
/// keychain; the secret itself never reaches the watch. Neither appears in the log.
actor WatchNightscoutUploader {
    static let shared = WatchNightscoutUploader()

    struct Outcome {
        var entries = 0
        var statusUploaded = false
        var treatments = 0
        var failure: String?
    }

    /// A loop's upload gets this much of the background time the loop holds.
    static let timeout: TimeInterval = 12

    private static let keychainService = "org.nightscout.trio.watch.nightscout"
    private static let keychainAccount = "credentials"
    private static let lastEntryKey = "WatchNightscoutUploader.lastEntry"
    /// Fingerprint and time of each treatment uploaded, kept a day: one goes up again only when it changed.
    private static let uploadedTreatmentsKey = "WatchNightscoutUploader.treatments"

    private var cached: UntetheredNightscoutCredentials??

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = WatchNightscoutUploader.timeout
        configuration.timeoutIntervalForResource = WatchNightscoutUploader.timeout
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: configuration)
    }()

    var isConfigured: Bool { credentials != nil }

    /// From the phone's watch state; nil forgets them (the setting or Nightscout upload is off on the phone).
    func setCredentials(_ new: UntetheredNightscoutCredentials?) {
        guard new != credentials else { return }
        cached = .some(new)
        Self.save(new)
        if new == nil {
            UserDefaults.standard.removeObject(forKey: Self.lastEntryKey)
            UserDefaults.standard.removeObject(forKey: Self.uploadedTreatmentsKey)
        }
        let line = new == nil ? "⌚️ Nightscout: the watch doesn't upload" : "⌚️ Nightscout: the watch uploads while the iPhone is away"
        Task { await WatchLogger.shared.log(line, force: true) }
    }

    /// The readings not uploaded yet and, when given, one loop's device status. Entries first: followers see the
    /// reading the loop went by before its status.
    func upload(
        glucose: [BloodGlucose],
        status: Data?,
        treatments: [UntetheredNightscout.Treatment] = [],
        now: Date = Date()
    ) async -> Outcome {
        var outcome = Outcome()
        guard let credentials else {
            outcome.failure = "not set up"
            return outcome
        }
        if credentials.uploadsGlucose {
            let last = UserDefaults.standard.object(forKey: Self.lastEntryKey) as? Date
            let entries = UntetheredNightscout.entries(glucose, after: last, now: now)
            if !entries.isEmpty {
                do {
                    let body = try JSONCoding.encoder.encode(entries)
                    try await post(UntetheredNightscout.entriesPath, body: body, credentials: credentials)
                    if let newest = entries.map(\.dateString).max() {
                        UserDefaults.standard.set(newest, forKey: Self.lastEntryKey)
                    }
                    outcome.entries = entries.count
                } catch {
                    outcome.failure = Self.describe(error)
                    // the status would show a loop for a reading followers don't have yet: both on the next loop
                    return outcome
                }
            }
        }
        if let status {
            do {
                try await post(UntetheredNightscout.statusPath, body: status, credentials: credentials)
                outcome.statusUploaded = true
            } catch {
                outcome.failure = Self.describe(error)
            }
        }
        // after the status: a failure here keeps neither the readings nor the loop from followers
        var uploaded = (UserDefaults.standard.dictionary(forKey: Self.uploadedTreatmentsKey) as? [String: Double] ?? [:])
            .filter { now.timeIntervalSince1970 - $0.value < UntetheredNightscout.entriesWindow }
        let fresh = treatments.filter { uploaded[$0.fingerprint] == nil }
        if !fresh.isEmpty {
            do {
                let body = try JSONCoding.encoder.encode(fresh)
                try await post(UntetheredNightscout.treatmentsPath, body: body, credentials: credentials)
                for treatment in fresh {
                    uploaded[treatment.fingerprint] = now.timeIntervalSince1970
                }
                outcome.treatments = fresh.count
            } catch {
                outcome.failure = outcome.failure ?? Self.describe(error)
            }
        }
        UserDefaults.standard.set(uploaded, forKey: Self.uploadedTreatmentsKey)
        return outcome
    }

    private var credentials: UntetheredNightscoutCredentials? {
        if let cached { return cached }
        let loaded = Self.load()
        cached = .some(loaded)
        return loaded
    }

    private func post(_ path: String, body: Data, credentials: UntetheredNightscoutCredentials) async throws {
        guard let request = UntetheredNightscout.request(path: path, body: body, credentials: credentials, timeout: Self.timeout)
        else { throw URLError(.badURL) }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200 ..< 300).contains(http.statusCode) else { throw UploadError.status(http.statusCode) }
    }

    private enum UploadError: Error {
        case status(Int)
    }

    /// For the log: the kind of failure, never the address.
    private static func describe(_ error: Error) -> String {
        if case let UploadError.status(code) = error {
            return code == 401 ? "Nightscout refused the API secret (401)" : "Nightscout answered \(code)"
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "no network"
            case .timedOut: return "timed out"
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost: return "Nightscout not reachable"
            default: return "network error \(urlError.code.rawValue)"
            }
        }
        return "upload error"
    }

    // MARK: - Keychain

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    private static func load() -> UntetheredNightscoutCredentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(UntetheredNightscoutCredentials.self, from: data)
    }

    private static func save(_ credentials: UntetheredNightscoutCredentials?) {
        SecItemDelete(query as CFDictionary)
        guard let credentials, let data = try? JSONEncoder().encode(credentials) else { return }
        var item = query
        item[kSecValueData as String] = data
        // read by loops in the background, also with the watch locked
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
