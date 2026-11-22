import CryptoKit
import Security
import WatchConnectivity
import WatchKit

/// Receives the launches and background wakes SwiftUI does not surface. Its
/// one job beyond defaults: bring the watch's G7 reader up at every launch
/// (including the silent ones the system makes for a Bluetooth link) and hold
/// the Bluetooth wakes long enough for a reading to arrive.
/// While untethered mode runs, the pump and the sensor belong to it: its wakes
/// run a loop cycle instead, and the reader stays out of the sensor's way.
final class TrioWatchAppDelegate: NSObject, WKApplicationDelegate {
    /// Untethered wakes are held long enough for one loop cycle and the G7's re-connect.
    private static let untetheredBluetoothHold: TimeInterval = 25
    /// Kept, not just their identities: WatchKit can hand a task over again, and completing one twice crashes.
    /// Untethered: one task held per wake. WatchKit delivers one for every Bluetooth message, dozens a second
    /// while the sensor pairs; the rest are completed on arrival (EJM0 b644da1).
    private var heldUntetheredTask: WKRefreshBackgroundTask?
    private var heldSince: Date?
    /// A held task older than this is from an earlier wake.
    private static let wakeLength: TimeInterval = 60

    func applicationDidFinishLaunching() {
        // restores a running untethered session first, so the reader sees it and stays off
        _ = UntetheredWatchManager.shared
        WatchG7Reader.shared.bootstrap()
        WatchG7Reader.shared.scheduleBackgroundRefresh()
        // remote commands sent straight to the watch while the phone is away (LoopFollow) arrive as pushes
        WKApplication.shared().registerForRemoteNotifications()
    }

    // MARK: - Push test

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        // only its end, enough to tell a new token: logs get shared, and the token reaches the phone by its own way
        Task { await WatchLogger.shared.log("⌚️ Push test: watch push token …\(token.suffix(6))", force: true) }
        WatchRemoteCommands.sendTokenToPhone(token)
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        Task { await WatchLogger.shared.log("⌚️ Push test: registering failed: \(error.localizedDescription)", force: true) }
    }

    func didReceiveRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void
    ) {
        let state = WKApplication.shared().applicationState
        // the test push carries the Mac's send time, so the log shows how long it took
        let sent = (userInfo["sentAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let delay = sent.map { " \(Int(Date().timeIntervalSince($0))) s after sending" } ?? ""
        let phone = WCSession.default.isReachable ? "phone in reach" : "phone not in reach"
        let encrypted = userInfo["encrypted_data"] as? String
        Task { @MainActor in
            let what = encrypted == nil ? "push" : "remote command"
            await WatchLogger.shared.log("⌚️ Push test: \(what) received\(delay), app state \(state.rawValue), \(phone)", force: true)
            // the wake lasts until the command is done and the sender has its answer
            if let encrypted { await WatchRemoteCommands.handle(encrypted: encrypted) }
            completionHandler(.newData)
        }
    }

    func applicationDidBecomeActive() {
        WatchG7Reader.shared.appBecameActive()   // before the recheck, so it holds in the app
        WatchG7Reader.shared.noteWake()
    }

    func applicationWillEnterForeground() {
        WatchG7Reader.shared.noteWake()
    }

    /// Implementing this makes every background task ours to complete.
    /// Extended Untethered Mode's workout outlived the last process.
    func handleActiveWorkoutRecovery() {
        UntetheredWatchManager.shared.recoverWorkout()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        // Not always on main (EJM0 f858f18): a Bluetooth task can arrive on CoreBluetooth's queue, and all below is
        // main-only. The reader's hold asserts main, so such a task ended the process right at the link-up (Trio
        // 2026-10-18: a new process 5 s after "link up" at 14:10, no reading for hours).
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.handle(backgroundTasks) }
            return
        }
        for task in backgroundTasks {
            switch task {
            case let bluetoothTask as WKBluetoothAlertRefreshBackgroundTask:
                if UntetheredWatchManager.shared.isActive {
                    if bluetoothTask === heldUntetheredTask { continue }
                    if heldUntetheredTask != nil, let since = heldSince, Date().timeIntervalSince(since) < Self.wakeLength {
                        completeOnce(bluetoothTask)
                        continue
                    }
                    heldUntetheredTask = bluetoothTask
                    let since = Date()
                    heldSince = since
                    // the system may grant less than the hold: the task ends then, not later, and the grant is logged
                    bluetoothTask.expirationHandler = { [weak self, weak bluetoothTask] in
                        let expire = {
                            let granted = Date().timeIntervalSince(since)
                            Task {
                                await WatchLogger.shared
                                    .log(String(format: "⌚️ Bluetooth wake expired by the system after %.1f s", granted))
                            }
                            if let bluetoothTask { self?.releaseUntethered(bluetoothTask) }
                        }
                        if Thread.isMainThread { expire() } else { DispatchQueue.main.sync(execute: expire) }
                    }
                    // a reading in this wake loops through the CGM delegate; the wake itself only checks (EJM0 cfbb364)
                    UntetheredWatchManager.shared.recheckCGM()
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.untetheredBluetoothHold) {
                        self.releaseUntethered(bluetoothTask)
                    }
                } else {
                    WatchG7Reader.shared.hold(bluetoothTask: bluetoothTask)
                }

            case let connectivityTask as WKWatchConnectivityRefreshBackgroundTask:
                // Keep the app awake until WatchConnectivity has delivered
                // what the phone queued, as Apple asks.
                WatchG7Reader.shared.noteWake()
                completeWhenConnectivityIsDelivered(connectivityTask, attempt: 0)

            case let refreshTask as WKApplicationRefreshBackgroundTask:
                if UntetheredWatchManager.shared.isActive {
                    UntetheredWatchManager.shared.recheckCGM()
                }
                WatchG7Reader.shared.noteWake()
                WatchG7Reader.shared.scheduleBackgroundRefresh()
                // the session's own wake, after the reader's: one refresh is pending at a time
                UntetheredWatchManager.shared.scheduleSessionRefresh()
                // A few seconds for the re-check to lodge its request before suspending.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    refreshTask.setTaskCompletedWithSnapshot(false)
                }

            case let snapshotTask as WKSnapshotRefreshBackgroundTask:
                snapshotTask.setTaskCompleted(
                    restoredDefaultState: true,
                    estimatedSnapshotExpiration: Date.distantFuture,
                    userInfo: nil
                )

            default:
                WatchG7Reader.shared.noteWake()
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    /// Ends a held untethered wake, by the hold or by the system's expiry, whichever comes first.
    private func releaseUntethered(_ task: WKRefreshBackgroundTask) {
        if heldUntetheredTask === task {
            heldUntetheredTask = nil
            heldSince = nil
        }
        completeOnce(task)
    }

    private func completeOnce(_ task: WKRefreshBackgroundTask) {
        Self.completeOnce(task)
    }

    /// Every task completed, the delegate's and the reader's, held weakly and never dropped while a task lives: the list
    /// of 128 let a burst of wakes push out a task still held, and its hold's end completed it a second time, which
    /// WatchKit answers with a crash (19 November 06:05:43, 25.6 s after its first completion; no readings until 06:33).
    private static let completedTasks = NSHashTable<WKRefreshBackgroundTask>.weakObjects()

    static func completeOnce(_ task: WKRefreshBackgroundTask) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !completedTasks.contains(task) else { return }
        completedTasks.add(task)
        task.setTaskCompletedWithSnapshot(false)
    }

    /// watchOS gives this wake 15 s of wall clock and ends Trio past it ("WatchConnectivity watchdog transgression",
    /// 8 November 17:46, first tester: launched for it, killed 15.3 s later with content still pending). Up to 15 checks a
    /// second apart reached exactly that. Now it lets go after 10 s at most, and at once when the system ends it
    /// early; what is still pending comes with the next wake.
    private static let connectivityHold: TimeInterval = 10
    /// While the watch has the pump: the same wake also allows Trio only 2 s of CPU, and a loop running meanwhile counts
    /// toward it (22 November 07:35, first tester: "Exhausted CPU time allowance of 2.00 seconds", ended mid-session
    /// as a sensor wake's loop ran with content still pending). Held 1 s at most then, and not at all while a sensor
    /// wake or a loop is under way; what is still pending comes with the next wake.
    private static let connectivityHoldUntethered: TimeInterval = 1

    private func completeWhenConnectivityIsDelivered(_ task: WKWatchConnectivityRefreshBackgroundTask, attempt: Int) {
        if attempt == 0 {
            task.expirationHandler = { [weak self, weak task] in
                let expire = {
                    Task { await WatchLogger.shared.log("⌚️ Connectivity wake expired by the system", force: true) }
                    if let task { self?.completeOnce(task) }
                }
                if Thread.isMainThread { expire() } else { DispatchQueue.main.async(execute: expire) }
            }
        }
        let session = WCSession.default
        let untethered = UntetheredWatchManager.shared
        let busy = untethered.isActive && untethered.isBluetoothWakeUnderway
        let hold = untethered.isActive ? Self.connectivityHoldUntethered : Self.connectivityHold
        if session.activationState != .activated || !session.hasContentPending || busy
            || TimeInterval(attempt) >= hold
        {
            if session.hasContentPending {
                Task { await WatchLogger.shared.log("⌚️ Connectivity wake let go after \(attempt) s with content still pending", force: true) }
            }
            completeOnce(task)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.completeWhenConnectivityIsDelivered(task, attempt: attempt + 1)
        }
    }
}

// MARK: - Remote commands sent straight to the watch

/// A remote bolus or meal (LoopFollow) sent straight to the watch while it runs the loop untethered, so it arrives
/// with the phone away too: opened with remote control's shared secret, checked and delivered as one the phone
/// passes on (`handleRemoteTreatment`), and answered to the sender from the watch. Without the pump the watch leaves
/// it to the phone, which gets the same command. Apple delivered such pushes to the watch app within seconds with
/// the phone switched off (31 October, 14:08 to 14:57).
@MainActor enum WatchRemoteCommands {
    private struct Payload: Decodable {
        let commandType: String
        let timestamp: TimeInterval
        let bolusAmount: Decimal?
        let carbs: Int?
        let fat: Int?
        let protein: Int?
        let scheduledTime: TimeInterval?
        let overrideName: String?
        let target: Int?
        let duration: Int?
        let returnNotification: ReturnInfo?

        enum CodingKeys: String, CodingKey {
            case commandType = "command_type"
            case timestamp
            case bolusAmount = "bolus_amount"
            case carbs
            case fat
            case protein
            case scheduledTime = "scheduled_time"
            case overrideName
            case target
            case duration
            case returnNotification = "return_notification"
        }
    }

    /// Where the answer goes (`CommandPayload.ReturnNotificationInfo`).
    private struct ReturnInfo: Decodable {
        let productionEnvironment: Bool
        let deviceToken: String
        let bundleId: String
        let teamId: String
        let keyId: String
        let apnsKey: String

        enum CodingKeys: String, CodingKey {
            case productionEnvironment = "production_environment"
            case deviceToken = "device_token"
            case bundleId = "bundle_id"
            case teamId = "team_id"
            case keyId = "key_id"
            case apnsKey = "apns_key"
        }
    }

    /// The answer, as the phone's (`RemoteNotificationResponseManager.NotificationPayload`).
    private struct Answer: Encodable {
        struct APS: Encodable {
            struct Alert: Encodable {
                let title: String
                let body: String
            }

            let alert: Alert
            let sound = "default"
        }

        let aps: APS
        let commandStatus: String
        let commandType: String
        let timestamp: TimeInterval

        enum CodingKeys: String, CodingKey {
            case aps
            case commandStatus = "command_status"
            case commandType = "command_type"
            case timestamp
        }
    }

    private static func log(_ line: String) {
        Task { await WatchLogger.shared.log("⌚️ Remote command (straight to the watch): \(line)", force: true) }
    }

    // MARK: Opening and acting on one

    static func handle(encrypted: String) async {
        guard let secret = RemoteSecretStore.load(), !secret.isEmpty else {
            return log("no shared secret on the watch (remote control or watch mode off on the iPhone)")
        }
        guard let combined = Data(base64Encoded: encrypted) else { return log("unreadable") }
        let payload: Payload
        do {
            // as the phone's `SecureMessenger`: AES-GCM with the secret's SHA-256, nonce first and tag last
            let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
            let opened = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
            payload = try JSONDecoder().decode(Payload.self, from: opened)
        } catch {
            return log("couldn't open it: the shared secret may differ from the sender's")
        }
        let manager = UntetheredWatchManager.shared
        // the phone has the pump and the same command
        guard manager.isActive else { return log("\(payload.commandType): the iPhone has the pump, left to it") }
        if let action = adjustment(payload) {
            return await handleAdjustment(payload, action: action)
        }
        guard payload.commandType == "bolus" || payload.commandType == "meal" else {
            return log("\(payload.commandType): only boluses, meals, overrides and temp targets are handled on the watch")
        }
        // what only the phone's settings limit; the rest is checked with the treatment
        let state = WatchState.shared
        if let fat = payload.fat, Decimal(fat) > state.maxFat {
            return await answer(payload, false, String(localized: "Command rejected: fat amount (\(fat)g) exceeds the maximum allowed (\(state.maxFat)g)."))
        }
        if let protein = payload.protein, Decimal(protein) > state.maxProtein {
            return await answer(payload, false, String(localized: "Command rejected: protein amount (\(protein)g) exceeds the maximum allowed (\(state.maxProtein)g)."))
        }
        let treatment = UntetheredRemoteTreatment(
            id: UntetheredRemoteTreatment.id(
                sentAt: payload.timestamp,
                commandType: payload.commandType,
                bolus: payload.bolusAmount,
                carbs: payload.carbs,
                fat: payload.fat,
                protein: payload.protein
            ),
            sentAt: Date(timeIntervalSince1970: payload.timestamp),
            bolus: payload.bolusAmount,
            carbs: payload.commandType == "meal" ? payload.carbs.map { Decimal($0) } : nil,
            fat: payload.commandType == "meal" ? payload.fat.map { Decimal($0) } : nil,
            protein: payload.commandType == "meal" ? payload.protein.map { Decimal($0) } : nil,
            carbsDate: payload.scheduledTime.map { Date(timeIntervalSince1970: $0) }
        )
        // the bolus answers once the pod took it; the wake holds at most `answerWait`
        let result: (delivered: Bool, message: String)?? = await withCheckedContinuation { continuation in
            let once = RemoteCommandOnce(continuation)
            manager.handleRemoteTreatment(treatment, epoch: manager.data.session.epoch) { once.resume(.some($0)) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(answerWait * 1_000_000_000))
                once.resume(nil)
            }
        }
        switch result {
        case let .some(.some(outcome)):
            await answer(payload, outcome.delivered, outcome.delivered && payload.bolusAmount != nil
                ? String(localized: "Bolus started on the Apple Watch") : outcome.message)
        case .some(.none):
            log("already handled through the iPhone")
        case .none:
            log("no result within \(Int(answerWait)) s, the sender isn't told")
        }
    }

    private static let answerWait: TimeInterval = 20

    /// An override or temp target command, as the phone's remote control reads one.
    private static func adjustment(_ payload: Payload) -> UntetheredRemoteAdjustment.Action? {
        switch payload.commandType {
        case "start_override":
            guard let name = payload.overrideName, !name.isEmpty else { return nil }
            return .startOverride(name: name)
        case "cancel_override": return .cancelOverride
        case "temp_target":
            guard let target = payload.target, let duration = payload.duration else { return nil }
            return .startTempTarget(targetMgdl: Decimal(target), minutes: Decimal(duration))
        case "cancel_temp_target": return .cancelTempTarget
        default: return nil
        }
    }

    private static func handleAdjustment(_ payload: Payload, action: UntetheredRemoteAdjustment.Action) async {
        let manager = UntetheredWatchManager.shared
        let adjustment = UntetheredRemoteAdjustment(
            id: UntetheredRemoteAdjustment.id(
                sentAt: payload.timestamp,
                commandType: payload.commandType,
                overrideName: payload.overrideName,
                target: payload.target,
                duration: payload.duration
            ),
            sentAt: Date(timeIntervalSince1970: payload.timestamp),
            action: action
        )
        let result: (delivered: Bool, message: String)?? = await withCheckedContinuation { continuation in
            let once = RemoteCommandOnce(continuation)
            manager.handleRemoteAdjustment(adjustment, epoch: manager.data.session.epoch) { once.resume(.some($0)) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(answerWait * 1_000_000_000))
                once.resume(nil)
            }
        }
        switch result {
        case let .some(.some(outcome)):
            await answer(payload, outcome.delivered, outcome.message)
        case .some(.none):
            log("already handled through the iPhone")
        case .none:
            log("no result within \(Int(answerWait)) s, the sender isn't told")
        }
    }

    // MARK: Answering the sender

    private static func answer(_ payload: Payload, _ success: Bool, _ message: String) async {
        guard let info = payload.returnNotification, !info.deviceToken.isEmpty else { return log("no address for the answer") }
        guard let jwt = token(keyID: info.keyId, teamID: info.teamId, pem: info.apnsKey) else {
            return log("couldn't sign the answer")
        }
        let host = info.productionEnvironment ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(info.deviceToken)") else { return }
        let body = Answer(
            aps: .init(alert: .init(title: success ? "Command Successful" : "Command Failed", body: message)),
            commandStatus: success ? "success" : "failed",
            commandType: payload.commandType,
            timestamp: Date().timeIntervalSince1970
        )
        // well inside the push's wake: a hung request would outlast it
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.httpBody = try? JSONEncoder().encode(body)
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue("0", forHTTPHeaderField: "apns-expiration")
        request.setValue(info.bundleId, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            log(status == 200 ? "answer sent: \(message)" : "answer refused by Apple (HTTP \(status))")
        } catch {
            log("answer not sent: \(error.localizedDescription)")
        }
    }

    /// Apple's ES256 token for the sender's key, as the phone's `APNSJWTManager`; the key comes with the command and
    /// isn't kept.
    private static func token(keyID: String, teamID: String, pem: String) -> String? {
        let key: P256.Signing.PrivateKey
        if let parsed = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
            key = parsed
        } else {
            // a key pasted without its line breaks
            let base64 = pem
                .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
                .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
                .components(separatedBy: .whitespacesAndNewlines).joined()
            guard let der = Data(base64Encoded: base64), let parsed = try? P256.Signing.PrivateKey(derRepresentation: der)
            else { return nil }
            key = parsed
        }
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        guard let header = try? JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID]),
              let claims = try? JSONSerialization.data(withJSONObject: ["iss": teamID, "iat": Int(Date().timeIntervalSince1970)])
        else { return nil }
        let input = "\(base64URL(header)).\(base64URL(claims))"
        guard let signature = try? key.signature(for: Data(input.utf8)) else { return nil }
        return "\(input).\(base64URL(signature.rawRepresentation))"
    }

    // MARK: The watch's push token

    private static let tokenSentKey = "RemoteCommands.tokenSent"

    /// Queued, so it reaches the phone whenever it is back; again only when it changed. WatchConnectivity may not be
    /// active yet this early in the launch: tried again a little later.
    static func sendTokenToPhone(_ token: String, attempt: Int = 1) {
        guard UserDefaults.standard.string(forKey: tokenSentKey) != token else { return }
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated else {
            guard attempt < 10 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { sendTokenToPhone(token, attempt: attempt + 1) }
            return
        }
        session.transferUserInfo([WatchMessageKeys.watchPushToken: token])
        UserDefaults.standard.set(token, forKey: tokenSentKey)
        log("push token sent to the iPhone")
    }
}

/// Resumes its continuation once: with the answer, or empty when the wait runs out first. Outside the main actor, so
/// the treatment's answer can call it from wherever it comes.
private final class RemoteCommandOnce {
    private var continuation: CheckedContinuation<(delivered: Bool, message: String)??, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<(delivered: Bool, message: String)??, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: (delivered: Bool, message: String)??) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// Remote control's shared secret on the watch, from the phone's watch state; in the keychain, never in the log.
enum RemoteSecretStore {
    private static let service = "org.nightscout.trio.watch.remote"
    private static let account = "sharedSecret"
    private static var cached: String??

    static func load() -> String? {
        if let cached { return cached }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let value = SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
            ? (item as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        cached = .some(value)
        return value
    }

    /// Empty forgets it (remote control or untethered mode off on the phone).
    static func set(_ secret: String) {
        guard load() ?? "" != secret else { return }
        SecItemDelete(baseQuery as CFDictionary)
        if !secret.isEmpty {
            var item = baseQuery
            item[kSecValueData as String] = Data(secret.utf8)
            // readable while the watch app wakes in the background with the watch locked
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
        cached = .some(secret.isEmpty ? nil : secret)
        Task { await WatchLogger.shared.log(secret.isEmpty ? "⌚️ Remote command: shared secret removed" : "⌚️ Remote command: shared secret stored", force: true) }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
