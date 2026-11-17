import CoreBluetooth
import Foundation
import os.log

/// What the watch needs to reach its sensor. The pairing code and sensor name
/// come from the phone; the key and peripheral identifier are the watch's own,
/// learned the first time it pairs (a watch takes its own display slot, so it
/// runs its own key exchange).
struct WatchG7Credentials: Equatable {
    /// The advertised name ("DXCMxx"); matched on its last two characters.
    var sensorName: String?
    var pairingCode: String?
    var sharedKey: Data?
    var peripheralIdentifier: UUID?

    var canAuthenticate: Bool {
        sharedKey != nil || pairingCode != nil
    }
}

protocol WatchG7SessionDelegate: AnyObject {
    func session(_ session: WatchG7Session, didRead reading: WatchG7GlucoseMessage, receivedAt: Date)
    /// Readings filled in after a gap, as (date, mg/dL, trend) with dates resolved.
    func session(_ session: WatchG7Session, didReadBackfill readings: [WatchG7Reading])
    func session(_ session: WatchG7Session, didAuthenticateWith sharedKey: Data)
    func sessionDidInvalidateSharedKey(_ session: WatchG7Session)
    func session(_ session: WatchG7Session, didAdoptPeripheral identifier: UUID?)
    func session(_ session: WatchG7Session, log line: String)
    func session(_ session: WatchG7Session, didChangeConnection connected: Bool)
    func sessionStatusDidChange(_ session: WatchG7Session)
}

/// The watch's direct connection to a G7: the session half of G7SensorKit's
/// `G7Sensor` (direct mode only), on top of the vendored Bluetooth manager,
/// whose watch acquisition arm handles the radio's sleep/wake.
///
/// Every callback to the delegate arrives on `delegateQueue`.
final class WatchG7Session: G7BluetoothManagerDelegate {
    weak var delegate: WatchG7SessionDelegate?

    private let log = OSLog(category: "WatchG7Session")
    let bluetoothManager: G7BluetoothManager
    private let delegateQueue = DispatchQueue(label: "org.nightscout.Trio.WatchG7Session.delegate", qos: .utility)

    private let lockedCredentials: Locked<WatchG7Credentials>
    private let lockedIsActive = Locked(true)
    /// Trio on the screen: a pairing runs only then, as the system's pairing request can't show behind the watch face.
    private let lockedIsInFront = Locked(false)

    // Confined to `bluetoothManager.managerQueue`.
    private var activationDate: Date?
    private var latestReadingDate: Date?
    private var backfillRequestPending = false
    private var backfillBuffer: [WatchG7BackfillRecord] = []

    /// Readings older than this after a gap are not asked for.
    private static let maximumBackfillWindow = TimeInterval(hours: 6)

    var isSearchingForSensor: Bool { bluetoothManager.isSearchingForSensor }

    init(credentials: WatchG7Credentials, latestReadingDate: Date?) {
        lockedCredentials = Locked(credentials)
        self.latestReadingDate = latestReadingDate
        bluetoothManager = G7BluetoothManager()
        bluetoothManager.delegate = self
        bluetoothManager.setActivePeripheralIdentifier(credentials.peripheralIdentifier)
        if let latestReadingDate {
            bluetoothManager.noteReading(at: latestReadingDate)
        }
        G7PeripheralManager.gattErrorHook = { [weak self] line in
            self?.report(line)
        }
        // A relaunch for Bluetooth can hand back the restored link before the
        // delegate above was set, and then nobody authenticates on it: the
        // sensor holds an idle link and closes it, a wasted reading for the
        // watch and a busy sensor for the phone. Pick such a link up here.
        // One second leaves room for the restoration callback itself, which
        // arrives right after the central is created.
        bluetoothManager.managerQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.adoptRestoredLinkIfMissed()
        }
    }

    /// On the manager's queue, after any restoration callback.
    private func adoptRestoredLinkIfMissed() {
        guard let identifier = lockedCredentials.value.peripheralIdentifier,
              let central = bluetoothManager.centralManager,
              let peripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first,
              peripheral.state == .connected,
              bluetoothManager.managedPeripherals[identifier] == nil
        else { return }
        report("Picking up the link the system restored")
        bluetoothManager.handleDiscoveredPeripheral(peripheral)
        bluetoothManager.centralManager(central, didConnect: peripheral)
    }

    /// The phone's newest reading. While the phone is reading the sensor, it is
    /// alive and in range, so missed watch readings are not a reason to drop the
    /// watch's standing connection request and scan (which does nothing in the
    /// background anyway).
    func notePhoneReading(at date: Date) {
        bluetoothManager.noteReading(at: date)
    }

    // MARK: - Control (call from the main queue)

    /// Starts (or resumes) looking for the sensor.
    func resume() {
        lockedIsActive.value = true
        bluetoothManager.setActivePeripheralIdentifier(lockedCredentials.value.peripheralIdentifier)
        bluetoothManager.scanForPeripheral()
    }

    /// After untethered mode: resumes, then a fresh request once the other central has let go (`takeOverAcquisition`).
    func resumeAfterUntethered() {
        lockedIsActive.value = true
        bluetoothManager.setActivePeripheralIdentifier(lockedCredentials.value.peripheralIdentifier)
        // not `scanForPeripheral`: its connect would only be cancelled again a moment later
        bluetoothManager.takeOverAcquisition()
    }

    /// Lets go of the sensor and stops asking for it. The central stays alive,
    /// so a later `resume()` does not create a second one.
    func pause() {
        lockedIsActive.value = false
        bluetoothManager.disconnect()
    }

    /// On any wake: puts acquisition right if a lost Bluetooth callback left nothing standing.
    func recheck() {
        guard lockedIsActive.value else { return }
        bluetoothManager.recheckAcquisition()
    }

    /// The app's scene phase, for the acquisition: in front it holds in the app, behind it hands the wait to the daemon.
    func appBecameActive() {
        lockedIsInFront.value = true
        bluetoothManager.appBecameActive()
    }

    func appLeavingScreen() {
        lockedIsInFront.value = false
        // paused (untethered mode has the sensor): the acquisition still learns it is behind, or it would hold in
        // the app and scan as if in front once it resumes (22 October, 01:15 to 04:54: no reading)
        guard lockedIsActive.value else { return bluetoothManager.appNoteBackground() }
        bluetoothManager.appLeavingScreen()
    }

    func appNoteBackground() {
        lockedIsInFront.value = false
        bluetoothManager.appNoteBackground()
    }

    /// New credentials from the phone, or a reset. Drops the link so the next
    /// connection uses them.
    func update(credentials: WatchG7Credentials) {
        let old = lockedCredentials.value
        lockedCredentials.value = credentials
        guard old != credentials else { return }
        if old.peripheralIdentifier != credentials.peripheralIdentifier {
            bluetoothManager.setActivePeripheralIdentifier(credentials.peripheralIdentifier)
            if credentials.peripheralIdentifier == nil {
                bluetoothManager.forgetPeripheral()
            }
        }
        bluetoothManager.disconnect()
        if lockedIsActive.value {
            bluetoothManager.scanForPeripheral()
        }
    }

    // MARK: - Helpers

    private func report(_ line: String) {
        log.default("%{public}@", line)
        delegateQueue.async {
            self.delegate?.session(self, log: line)
        }
    }

    private func isOurSensor(_ peripheralManager: G7PeripheralManager) -> Bool {
        let credentials = lockedCredentials.value
        if let known = credentials.peripheralIdentifier {
            return peripheralManager.peripheral.identifier == known
        }
        guard let sensorName = credentials.sensorName, let name = peripheralManager.peripheral.name else {
            return false
        }
        return name.suffix(2) == sensorName.suffix(2)
    }

    private static func isSensorFamilyName(_ name: String) -> Bool {
        // "DXCMxx" (G7), "DX02xx" (ONE+), "DX01xx" (Stelo), or "Dexcomxx".
        name.hasPrefix("DXCM") || name.hasPrefix("DX02") || name.hasPrefix("DX01") || name.hasPrefix("Dexcom")
    }

    // MARK: - Authentication and session

    private func authenticate(_ peripheralManager: G7PeripheralManager) {
        let credentials = lockedCredentials.value
        guard credentials.canAuthenticate else {
            report("Not authenticating: no pairing code from the phone yet")
            return
        }
        // Behind the watch face the key exchange ran to the end, the system's pairing request couldn't show, and the
        // sensor refused the key at its next connection: four hours of that on 16 November (18:12 to 01:29), paired
        // within a minute once Trio was in front. Pairs at the sensor's next connection with Trio in front.
        guard credentials.sharedKey != nil || lockedIsInFront.value else {
            report("Pairing waits for Trio in front")
            return
        }

        let authenticator = G7Authenticator(
            pairingCode: credentials.pairingCode,
            storedSharedKey: credentials.sharedKey,
            stepTimeout: credentials.sharedKey == nil
                ? G7Authenticator.pairingStepTimeout
                : G7Authenticator.reconnectStepTimeout,
            displayType: .watch
        )
        authenticator.logHandler = { [weak self] line in
            self?.report(line)
        }

        authenticator.authenticate(peripheralManager: peripheralManager) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(authResult):
                if authResult.didExchangeKeys {
                    _ = self.lockedCredentials.mutate { $0.sharedKey = authResult.sharedKey }
                    self.delegateQueue.async {
                        self.delegate?.session(self, didAuthenticateWith: authResult.sharedKey)
                    }
                }
                self.beginSession(peripheralManager)
            case .failure(G7AuthenticatorError.linkLost):
                // Nothing wrong with the sensor; the next connection retries.
                break
            case let .failure(error):
                self.handleAuthenticationFailure(error)
            }
        }
    }

    private func handleAuthenticationFailure(_ error: Error) {
        report("Authentication failed: \(error)")

        // A stale key is recoverable: drop it, and the next connection pairs
        // again with the code. Without a code there is nothing to fall back
        // on, so the key stays.
        let keyIsStale: Bool
        switch error {
        case G7AuthenticatorError.challengeMismatch,
             G7AuthenticatorError.rejected(_, .noAppKey),
             G7AuthenticatorError.storedKeyNotBonded:
            keyIsStale = true
        default:
            keyIsStale = false
        }
        let credentials = lockedCredentials.value
        if keyIsStale, credentials.sharedKey != nil, credentials.pairingCode != nil {
            report("Discarding the watch's saved key; the next connection pairs again")
            _ = lockedCredentials.mutate { $0.sharedKey = nil }
            delegateQueue.async {
                self.delegate?.sessionDidInvalidateSharedKey(self)
            }
        }
    }

    /// Subscribes and asks for a reading straight away, as the official app does.
    private func beginSession(_ peripheralManager: G7PeripheralManager) {
        peripheralManager.perform { peripheral in
            guard peripheral.peripheral.state == .connected else {
                self.report("Link dropped before the session could open")
                return
            }
            do {
                try peripheral.setNotifyValue(true, for: .control)
                try peripheral.setNotifyValue(true, for: .backfill)
                self.backfillRequestPending = true
                try peripheral.writeValue(Data([G7Opcode.glucoseTx.rawValue]), for: .control, type: .withResponse)
            } catch {
                self.report("Could not open the session: \(error)")
            }
        }
    }

    private func requestBackfillIfNeeded(_ peripheral: G7PeripheralManager, activationDate: Date, latestReadingDate: Date?) {
        let now = Date()
        guard let latestReadingDate else {
            // Nothing to fill: the first reading starts the history.
            return
        }
        // A gap of under two readings is not worth a request.
        guard now.timeIntervalSince(latestReadingDate) > TimeInterval(minutes: 9) else { return }

        let earliest = max(activationDate, latestReadingDate, now.addingTimeInterval(-Self.maximumBackfillWindow))
        guard earliest < now else { return }
        let start = UInt32(max(0, earliest.timeIntervalSince(activationDate)))
        let end = UInt32(max(0, now.timeIntervalSince(activationDate)))
        guard start < end else { return }

        var request = Data([G7Opcode.backfillFinished.rawValue])
        request.append(start.littleEndian)
        request.append(end.littleEndian)
        do {
            report("Asking the sensor for the readings since \(DateFormatter.localizedString(from: latestReadingDate, dateStyle: .none, timeStyle: .short))")
            try peripheral.writeValue(request, for: .control, type: .withResponse)
        } catch {
            report("Backfill request failed: \(error)")
        }
    }

    private func flushBackfillBuffer() {
        guard !backfillBuffer.isEmpty, let activationDate = activationDate else {
            backfillBuffer = []
            return
        }
        let records = backfillBuffer
        backfillBuffer = []
        let readings: [WatchG7Reading] = records.compactMap { record in
            guard record.hasReliableGlucose, let glucose = record.glucose else { return nil }
            return WatchG7Reading(
                date: activationDate.addingTimeInterval(TimeInterval(record.timestamp)),
                glucose: Int(glucose),
                trendRate: record.trend
            )
        }
        if let newest = readings.map(\.date).max(), newest > (latestReadingDate ?? .distantPast) {
            latestReadingDate = newest
        }
        guard !readings.isEmpty else { return }
        delegateQueue.async {
            self.delegate?.session(self, didReadBackfill: readings)
        }
    }

    // MARK: - G7BluetoothManagerDelegate

    func bluetoothManager(_: G7BluetoothManager, readied peripheralManager: G7PeripheralManager) -> Bool {
        guard lockedIsActive.value, isOurSensor(peripheralManager) else { return false }
        delegateQueue.async {
            self.delegate?.session(self, didChangeConnection: true)
        }
        authenticate(peripheralManager)
        return true
    }

    func bluetoothManager(_: G7BluetoothManager, readyingFailed _: G7PeripheralManager, with error: Error) {
        report("Bluetooth: \(error.localizedDescription)")
    }

    func bluetoothManager(
        _ manager: G7BluetoothManager,
        shouldConnectPeripheral peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi _: NSNumber
    ) -> PeripheralConnectionCommand {
        guard lockedIsActive.value else { return .ignore }

        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let credentials = lockedCredentials.value

        guard credentials.canAuthenticate else {
            if let identifier = credentials.peripheralIdentifier, peripheral.identifier == identifier {
                manager.setNeedsCodeForSensor(peripheral.name ?? advertisedName ?? "sensor")
            }
            return .ignore
        }

        // Once found, only ever that peripheral.
        if let identifier = credentials.peripheralIdentifier {
            return peripheral.identifier == identifier ? .makeActive : .ignore
        }

        // Not found yet: the sensor the phone named, by its last two characters.
        guard let name = advertisedName, Self.isSensorFamilyName(name),
              let sensorName = credentials.sensorName,
              name.suffix(2) == sensorName.suffix(2)
        else {
            return .ignore
        }
        report("Found \(name)")
        return .makeActive
    }

    func bluetoothManagerShouldAcceptRestoredPeripherals(_: G7BluetoothManager) -> Bool {
        lockedIsActive.value
    }

    func bluetoothManager(
        _: G7BluetoothManager,
        peripheralManager: G7PeripheralManager,
        didReceiveControlResponse response: Data
    ) {
        guard let opcodeByte = response.first else { return }

        switch G7Opcode(rawValue: opcodeByte) {
        case .glucoseTx?:
            guard let message = WatchG7GlucoseMessage(data: response) else {
                report("Glucose reply not understood: \(response.hexadecimalString)")
                return
            }
            let now = Date()
            let activation = now.addingTimeInterval(-TimeInterval(message.messageTimestamp))
            activationDate = activation
            bluetoothManager.noteReading(at: now.addingTimeInterval(-TimeInterval(message.age)))

            if backfillRequestPending {
                backfillRequestPending = false
                let latest = latestReadingDate
                peripheralManager.perform { peripheral in
                    self.requestBackfillIfNeeded(peripheral, activationDate: activation, latestReadingDate: latest)
                }
            }
            if message.hasReliableGlucose, message.glucose != nil {
                latestReadingDate = now.addingTimeInterval(-TimeInterval(message.age))
            }
            delegateQueue.async {
                self.delegate?.session(self, didRead: message, receivedAt: now)
            }

        case .backfillFinished?:
            // The acknowledgement arrives after the records.
            flushBackfillBuffer()

        default:
            break
        }
    }

    func bluetoothManager(_: G7BluetoothManager, didReceiveBackfillResponse response: Data) {
        // Records are 9 bytes each; a G7 packs two to a notification.
        guard response.count % 9 == 0 else { return }
        let frame = Data(response) // re-based so offsets start at 0
        for offset in stride(from: 0, to: frame.count, by: 9) {
            if let record = WatchG7BackfillRecord(data: frame.subdata(in: offset ..< offset + 9)) {
                backfillBuffer.append(record)
            }
        }
    }

    func bluetoothManager(
        _: G7BluetoothManager,
        peripheralManager _: G7PeripheralManager,
        didReceiveAuthenticationResponse _: Data
    ) {
        // The authenticator collects these through its own handler.
    }

    func bluetoothManagerScanningStatusDidChange(_: G7BluetoothManager) {
        delegateQueue.async {
            self.delegate?.sessionStatusDidChange(self)
        }
    }

    func peripheralDidDisconnect(_: G7BluetoothManager, peripheralManager: G7PeripheralManager, wasRemoteDisconnect _: Bool) {
        guard isOurSensor(peripheralManager) else { return }
        // The backfill acknowledgement does not always arrive before the close.
        flushBackfillBuffer()
        backfillRequestPending = false
        delegateQueue.async {
            self.delegate?.session(self, didChangeConnection: false)
        }
    }

    func bluetoothManager(_: G7BluetoothManager, logEvent line: String) {
        delegateQueue.async {
            self.delegate?.session(self, log: line)
        }
    }

    func bluetoothManagerCanAuthenticate(_: G7BluetoothManager) -> Bool {
        lockedIsActive.value && lockedCredentials.value.canAuthenticate
    }

    func bluetoothManager(_ manager: G7BluetoothManager, didAdoptPeripheral identifier: UUID?) {
        // The watch keeps the peripheral it found itself; the phone's handle means nothing here.
        guard let identifier else { return }
        manager.setActivePeripheralIdentifier(identifier)
        guard lockedCredentials.value.peripheralIdentifier != identifier else { return }
        _ = lockedCredentials.mutate { $0.peripheralIdentifier = identifier }
        delegateQueue.async {
            self.delegate?.session(self, didAdoptPeripheral: identifier)
        }
    }

    func bluetoothManagerStatusDidChange(_: G7BluetoothManager) {
        delegateQueue.async {
            self.delegate?.sessionStatusDidChange(self)
        }
    }
}
