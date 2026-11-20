//
//  G7WatchAcquisition.swift
//  G7SensorKit
//
//  watchOS target only. The watch app sleeps between readings, its background scanning is
//  rationed, and a reconnect into the sensor's advertising tail counts against it, so the stock
//  rescan after every close does not work there. G7BluetoothManager hands its acquisition steps
//  to this arm; elsewhere there is no arm and the stock steps run.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//  Trio: the acquisition design is Jeremy Barnum's, from his G7SensorKit on the watch (LoopKit/G7SensorKit#80).
//

import CoreBluetooth
import Foundation
import os.log

/// The watch's one acquisition design: a single daemon-held request per burst, re-lodged after each
/// close by holding the process 35 s past link-up, then a plain connect (measured 33 in 33). State
/// restoration relaunches the app for each link. Runs on the bluetooth manager's queue.
public final class G7WatchAcquisition: G7AcquisitionArm {
    /// Link-up → the ~3.5-s read, the sensor's close, and its 20–24-s advertising tail all sit inside
    /// 35 s. A request that lands after this never reconnects into the tail.
    public static let tailClearanceSeconds: TimeInterval = 35
    /// The sensor's own cadence: one reading every 300 s.
    public static let period: TimeInterval = 300
    public static let missedBurstsBeforeBootstrap = 3
    /// One full window plus jitter: a scan pass that cannot span a burst proves nothing.
    public static let bootstrapScanCap: TimeInterval = 330
    /// OmnipodKit's heartbeatFailureBackoffSeconds.
    public static let refusalBackoffSeconds: TimeInterval = 30
    /// A didFailToConnect this soon after the call is the daemon declining the request itself.
    public static let synchronousRefusalWindow: TimeInterval = 2

    /// How long the hold keeps the process, counted from link-up; never below half a second.
    public static func holdWait(sinceLinkUp: TimeInterval) -> TimeInterval {
        max(0.5, tailClearanceSeconds - sinceLinkUp)
    }
    /// The hold before the next plain connect; nil = past the clearance, nothing to wait for.
    public static func relodgeHold(sinceLinkUp: TimeInterval) -> TimeInterval? {
        sinceLinkUp < tailClearanceSeconds ? holdWait(sinceLinkUp: sinceLinkUp) : nil
    }
    public enum FailureAction: Equatable { case backOff(TimeInterval), relodge }
    /// A synchronous refusal waits before asking again. A late failure (the request went live and
    /// could not connect) re-lodges through the arm.
    public static func onConnectFailure(sinceLodge: TimeInterval) -> FailureAction {
        sinceLodge < synchronousRefusalWindow ? .backOff(refusalBackoffSeconds) : .relodge
    }
    /// Whole bursts elapsed since `reference` (the last reading, or the last bootstrap pass).
    public static func missedBursts(since reference: Date?, now: Date = Date()) -> Int {
        reference.map { max(0, Int(now.timeIntervalSince($0) / period)) } ?? 0
    }

    private unowned let manager: G7BluetoothManager
    private let log = OSLog(category: "G7BluetoothManager")

    /// didConnect stamp; the tail clearance counts from here.
    private var linkUpAt: Date?
    /// Exactly one daemon-held request in flight.
    private var lodged = false
    private var lodgedAt: Date?
    /// A hold-then-connect is running; its end lodges.
    private var holdPending = false
    /// Trio: set from the app's scene phase (`G7BluetoothManager.appBecameActive` / `appLeavingScreen`): a scan pass
    /// waits for the app in front, as xDrip4iOS 7.2.0 keeps discovery to the foreground.
    private var isForeground = false
    /// The one scan pass.
    private var bootstrapPass = false
    /// Trio: background time held from the link-up until the sensor closes the link (or 15 s).
    private var linkHold: (() -> Void)?
    private var bootstrapTimer: DispatchSourceTimer?
    /// When the last bootstrap pass started: a silent sensor is scanned for once per three bursts.
    private var lastBootstrapAt: Date?
    /// The last reading's sensor timestamp, for the 3-miss test. Seeded at launch from the
    /// manager's persisted `latestReadingTimestamp`.
    private var lastReadingAt: Date?
    /// Trio: a link came up since the reader took the sensor back from untethered mode (`takeOver`).
    private var linkedSinceTakeOver = true

    init(manager: G7BluetoothManager) {
        self.manager = manager
        _ = G7WatchAcquisition.buildChanged   // noted at every launch, restored or not
    }

    /// Trio: true when this process runs a different build than the last one that ran. A connect restored
    /// across an app update is one bluetoothd no longer serves (2026-10-18: build 565 installed at 18:42, its
    /// restored request kept, no link for 45 minutes).
    static let buildChanged: Bool = {
        let key = "trio.g7watch.lastProcessBuild"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
            + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        let last = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(build, forKey: key)
        return last != nil && last != build
    }()

    private var central: CBCentralManager { manager.centralManager }
    private var queue: DispatchQueue { manager.managerQueue }

    private func watchLog(_ line: String) {
        log.default("[g7-watch] %{public}@", line)
        manager.delegate?.bluetoothManager(manager, logEvent: "[g7-watch] " + line)      // into the host's device log
    }

    // MARK: - Hooks

    /// The stock scan entry on the watch (poweredOn, resumeScanning, after a forget or a bootstrap
    /// pass).
    func scan() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard central.state == .poweredOn else { return }
        guard let id = manager.activePeripheralIdentifier,
              let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first else {
            startBootstrapPass(reason: "no adopted peripheral")
            return
        }
        adopt(peripheral)
        // Three bursts missed with a request standing: presume the identifier stale and scan once.
        // A pass restarts the count, so an absent sensor is scanned for once per three bursts.
        let reference = [lastReadingAt, lastBootstrapAt].compactMap { $0 }.max()
        let missed = G7WatchAcquisition.missedBursts(since: reference)
        if !bootstrapPass, peripheral.state != .connected, missed >= G7WatchAcquisition.missedBurstsBeforeBootstrap {
            let wasConnecting = peripheral.state == .connecting
            guard isForeground else {
                // Trio: in the background only the known sensor is asked for again; a scan pass there depends on a
                // timer that stops with the app (2026-10-20 06:32: 18 minutes). The pass waits for the app in front,
                // as xDrip4iOS 7.2.0 keeps discovery to the foreground. Counted like a pass: next try in three bursts.
                lastBootstrapAt = Date()
                watchLog("\(missed) bursts missed in the background — asking for the known sensor again (scan waits for the app in front)")
                if wasConnecting { central.cancelPeripheralConnection(peripheral) }
                lodged = false; lodgedAt = nil
                lodgeFresh(peripheral.identifier, after: wasConnecting ? 2 : 0, why: "retrying the known sensor")
                return
            }
            if wasConnecting { central.cancelPeripheralConnection(peripheral) }
            lodged = false; lodgedAt = nil
            startBootstrapPass(reason: "\(missed) bursts missed on the lodged request")
            // Trio: a scan in the background is rationed and found nothing for 22 minutes (2026-10-18, 19:03 to
            // 19:25, the app suspended through the pass); a request with the daemon is served while it sleeps.
            // Lodge a fresh one alongside the scan, after the cancel has gone through.
            lodgeFresh(peripheral.identifier, after: wasConnecting ? 2 : 0, why: "fresh connect alongside the scan pass")
            return
        }
        let sinceLinkUp = linkUpAt.map { Date().timeIntervalSince($0) } ?? .infinity
        relodge(peripheral, sinceLinkUp: sinceLinkUp, why: "acquisition armed")
    }

    /// What `scan()` does at launch, on any wake. Callbacks are the only thing that update `lodged`; one
    /// that never comes (2026-10-05: a cancelled restored connect went unanswered for an hour) leaves
    /// nothing lodged and nothing scheduled to notice. A pass in progress already owns acquisition.
    func recheck() {
        guard !bootstrapPass else { return }
        // Trio: a request that stood through a whole burst without a link is lost, not waiting: after the hand-backs of
        // 24 October (20:08) and 25 October (06:33) the reader's request stood for 83 and 12 minutes with no link and
        // nothing renewed it, as `scan` keeps a standing request. A fresh one at the next wake.
        if lodged, !holdPending, let at = lodgedAt,
           Date().timeIntervalSince(at) > G7WatchAcquisition.period + 90,
           let id = manager.activePeripheralIdentifier
        {
            freshLodge(id, why: String(format: "lodged %.0f s ago without a link", Date().timeIntervalSince(at)))
            return
        }
        scan()
    }

    /// Trio: the reader takes the sensor back after untethered mode, whose own central (G7SensorKit's framework) read
    /// it. After both hand-backs above the reader lodged its connect and no link came, in front (20:08) and behind
    /// (06:33): the other central's cancel and release, which run on its own queue and may come seconds later, seem
    /// to take the reader's request with them. So: a fresh request now, and once more after 40 s if no link came by
    /// then, when untethered mode's acquisition (holding its process up to 35 s) is surely gone.
    func takeOver() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard central.state == .poweredOn else { return }
        guard let id = manager.activePeripheralIdentifier,
              central.retrievePeripherals(withIdentifiers: [id]).first != nil
        else {
            // no handle from untethered mode: the stock way, a search
            scan()
            return
        }
        // the session's silence is no reason to scan: the reader knows its sensor
        lastBootstrapAt = Date()
        linkedSinceTakeOver = false
        freshLodge(id, why: "taking the sensor back from watch mode")
        let release = holdProcess(reason: "G7 takeover check", upTo: 42)
        queue.asyncAfter(deadline: .now() + 40) { [weak self] in
            defer { release() }
            guard let self, !self.linkedSinceTakeOver, !self.holdPending, !self.bootstrapPass else { return }
            self.freshLodge(id, why: "no link 40 s after taking the sensor back")
        }
    }

    /// Trio: cancels whatever stands for the sensor in this process and asks afresh, after the cancel has gone through.
    private func freshLodge(_ id: UUID, why: String) {
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first, p.state != .connected else { return }
        adopt(p)
        watchLog("\(why): sensor \(p.state.rawValue), lodged=\(lodged) — cancelling and connecting afresh")
        if p.state != .disconnected { central.cancelPeripheralConnection(p) }
        lodged = false; lodgedAt = nil
        lodgeFresh(id, after: 2, why: why)
    }

    func found(_ peripheral: CBPeripheral) {
        lodge(peripheral, why: "adopted on discovery")   // handles .connecting/.connected/no-code
    }

    func connected(_ peripheral: CBPeripheral) {
        // Trio: the Bluetooth wake that brings the link up is often granted no time at all (2026-10-18: "expired
        // after 0.0 s" 11 of 12 times), and at 16:20 the app was suspended right after "link up", before the
        // handshake: no reading for 20 minutes. Ask for time of our own until the sensor closes the link.
        linkHold?()
        linkHold = holdProcess(reason: "G7 link: handshake and reading", upTo: 15)
        let waited = lodgedAt.map { Date().timeIntervalSince($0) }
        lodged = false; lodgedAt = nil
        linkUpAt = Date()
        linkedSinceTakeOver = true
        if bootstrapPass { endBootstrapPass(reason: "connected") }
        watchLog(String(format: "link up %@ %@ · pid %d", peripheral.name ?? "unnamed",
                        waited.map { String(format: "%.0f s after the lodge", $0) } ?? "(restored launch)",
                        ProcessInfo.processInfo.processIdentifier))
    }

    /// Returns true when the arm owns what happens next (the adopted sensor closed the link).
    func disconnected(_ peripheral: CBPeripheral, error: Error?) -> Bool {
        guard peripheral.identifier == manager.activePeripheralIdentifier else { return false }
        linkHold?()
        linkHold = nil
        let sinceLinkUp = linkUpAt.map { Date().timeIntervalSince($0) } ?? 0
        linkUpAt = nil; lodged = false; lodgedAt = nil
        guard !bootstrapPass else { return false }
        let code = (error as NSError?).map { " [\($0.domain)#\($0.code)] \($0.localizedDescription)" } ?? ""
        relodge(peripheral, sinceLinkUp: sinceLinkUp, why: String(format: "sensor closed %.1f s after link-up%@", sinceLinkUp, code))
        return true
    }

    func failedToConnect(_ peripheral: CBPeripheral, error: Error?) -> Bool {
        guard lodged, peripheral.identifier == manager.activePeripheralIdentifier else { return false }
        lodged = false
        let sinceLodge = lodgedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        lodgedAt = nil
        let code = (error as NSError?).map { "\($0.domain)#\($0.code) \($0.localizedDescription)" } ?? "no error"
        switch G7WatchAcquisition.onConnectFailure(sinceLodge: sinceLodge) {
        case .backOff(let s):
            watchLog(String(format: "REFUSED %.2f s after the lodge (%@) — lodging again in %.0f s", sinceLodge, code, s))
            let id = peripheral.identifier
            queue.asyncAfter(deadline: .now() + s) { [weak self] in
                guard let self, !self.lodged,
                      let p = self.central.retrievePeripherals(withIdentifiers: [id]).first, p.state == .disconnected else { return }
                self.lodge(p, why: "after the refusal backoff")
            }
        case .relodge:
            watchLog(String(format: "connect failed %.0f s after the lodge (%@) — re-lodging", sinceLodge, code))
            relodge(peripheral, sinceLinkUp: 0, why: "after a late connect failure")
        }
        return true
    }

    /// The daemon drops every request with the radio: a request still believed lodged would block
    /// the next lodge until the 3-miss test, and a scan the next one. Start clean at poweredOn.
    func radioDown() {
        lodged = false; lodgedAt = nil; linkUpAt = nil
        bootstrapPass = false
        bootstrapTimer?.cancel(); bootstrapTimer = nil
    }

    /// An already-connected peripheral gets no second didConnect: run that path now so the
    /// handshake starts on the link the system brought us back for.
    func restored(_ peripheral: CBPeripheral) {
        if peripheral.state == .connected { manager.centralManager(central, didConnect: peripheral) }
        // Trio: a connect restored under this central's own identifier was lodged by this app's previous
        // process, which watchOS ended while the request stood. Cancelling it as foreign ended the very link
        // the system was bringing up, at every relaunch (Trio 2026-10-18: 07:46 and 07:51, "sensor closed
        // 0.0 s after link-up", no reading for 35 minutes). Keep it; three missed bursts still cancel it
        // and scan (the 2026-09-16 case of a request bluetoothd no longer held).
        // Not across an app update, though: that request went unserved; the lodge cancels it and asks afresh.
        else if peripheral.state == .connecting, !lodged, G7WatchAcquisition.buildChanged {
            watchLog("restored with a connect from before this app was updated — replacing it")
        } else if peripheral.state == .connecting, !lodged {
            lodged = true; lodgedAt = Date()
            watchLog("restored with this app's own connect still standing — keeping it")
        }
    }

    func noteReading(at timestamp: Date) {
        lastReadingAt = timestamp
    }

    /// Trio: the app is in front: its own hold waits out the sensor's tail, and a scan pass can run.
    func becameActive() {
        isForeground = true
    }

    /// Trio: the app is not in front, but the arm must not act on it (the reader stands aside for untethered mode).
    func noteBackground() {
        isForeground = false
    }

    /// Trio: the app leaves the screen (wrist down or another app), and watchOS may freeze it within seconds, also
    /// inside a hold (2026-10-20 06:51, no connect for 34 minutes). A running hold ends now and what's left of its wait
    /// goes with the request as a start delay; otherwise a request goes in if none stands.
    func leavingScreen() {
        isForeground = false
        guard central.state == .poweredOn else { return }
        if holdPending {
            // Pete Schwamb's take (LoopKit/G7SensorKit#80): no connect into the sensor's advertising tail as the app
            // leaves the screen, and no start delay. The hold keeps waiting out the tail; if watchOS ends it first,
            // its end lodges at once (`relodge`).
            watchLog("app leaving the screen — the hold keeps waiting out the sensor's tail (no start delay)")
            return
        }
        guard !lodged, !bootstrapPass, let p = manager.activePeripheral, p.state == .disconnected else { return }
        lodge(p, why: "app leaving the screen")
    }

    // MARK: - The request

    private func adopt(_ peripheral: CBPeripheral) {
        if let pm = manager.activePeripheralManager { pm.peripheral = peripheral } else {
            manager.activePeripheralManager = G7PeripheralManager(peripheral: peripheral, configuration: .dexcomG7, centralManager: central)
            manager.activePeripheralManager?.delegate = manager
        }
        manager.managedPeripherals[peripheral.identifier] = manager.activePeripheralManager
    }

    /// Every close, late connect failure and wake: hold the process until the sensor's tail has
    /// cleared, then a plain connect. A `sinceLinkUp` of 0 counts the tail clearance from now.
    private func relodge(_ peripheral: CBPeripheral, sinceLinkUp: TimeInterval, why: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !lodged, !holdPending else { return }
        guard let wait = G7WatchAcquisition.relodgeHold(sinceLinkUp: sinceLinkUp) else {
            // A wake past the clearance: nothing to wait for, a plain request now.
            lodge(peripheral, why: "\(why) · nothing to wait for")
            return
        }
        holdPending = true
        watchLog(String(format: "%@ · holding the process %.1f s past the sensor's tail, then a plain connect", why, wait))
        _ = holdProcess(reason: "G7 re-lodge after the sensor's tail", upTo: wait) { [weak self] systemEnded in
            self?.queue.async {
                guard let self, self.holdPending else { return }
                self.holdPending = false
                self.lodge(peripheral, why: systemEnded ? "hold ended by the system" : "hold over")
            }
        }
    }

    /// ONE plain connect with the daemon. Never held, never withdrawn by us.
    private func lodge(_ peripheral: CBPeripheral, why: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard central.state == .poweredOn, !lodged else { return }
        switch peripheral.state {
        case .connected:     return
        case .connecting:
            // Not ours (ours sets `lodged`): a restored request bluetoothd no longer held cost eight hours
            // with no link (2026-09-16). Cancel it and lodge our own; the timer covers a silent cancel.
            watchLog("restored as connecting with no request of ours — cancelling it and lodging a fresh connect")
            central.cancelPeripheralConnection(peripheral)
            lodgeFresh(peripheral.identifier, after: 2, why: "after cancelling a restored connect the daemon did not hold")
            return
        case .disconnecting: return   // the close callback lodges: a connect issued during a cancel is lost inside CoreBluetooth
        default:             break
        }
        if let delegate = manager.delegate, !delegate.bluetoothManagerCanAuthenticate(manager) {
            // A link we cannot authenticate is one the sensor closes unencrypted ~10 s later — a
            // tally count every burst for nothing. Stand down until a configuration brings a code.
            manager.setNeedsCodeForSensor(peripheral.name ?? "sensor")
            watchLog("no pairing code for \(peripheral.name ?? "sensor") — not lodging")
            return
        }
        manager.setNeedsCodeForSensor(nil)
        lodged = true; lodgedAt = Date()
        central.connect(peripheral, options: nil)
        watchLog("lodged — \(why) · the app may suspend")
    }

    /// Trio: a plain connect `delay` seconds from now (after a cancel has gone through), the process held
    /// meanwhile so a relaunch's few seconds don't end before it is lodged.
    private func lodgeFresh(_ id: UUID, after delay: TimeInterval, why: String) {
        let release = holdProcess(reason: "G7 fresh connect", upTo: delay + 2)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            defer { release() }
            // Trio: not for a sensor forgotten meanwhile (16 November, 19:05: the old sensor, asked for again in the
            // second the phone named a new one, connected 9 minutes later)
            guard let self, !self.lodged, self.manager.activePeripheralIdentifier == id,
                  let p = self.central.retrievePeripherals(withIdentifiers: [id]).first else { return }
            switch p.state {
            case .disconnected:
                self.lodge(p, why: why)
            case .connected:
                return
            default:
                // Trio: a cancel that never answers leaves the sensor 'connecting' in this process for good, and each
                // retry cancelled again and lodged nothing (2026-10-22 21:02 to 22:10, and 02:15 to 04:34 on 23 October:
                // no reading until the app was relaunched). Connect anyway; the request goes to the daemon.
                guard self.central.state == .poweredOn else { return }
                if let delegate = self.manager.delegate, !delegate.bluetoothManagerCanAuthenticate(self.manager) { return }
                self.lodged = true; self.lodgedAt = Date()
                self.central.connect(p, options: nil)
                self.watchLog("lodged — \(why) · the cancel went unanswered (state \(p.state.rawValue)), connecting anyway · the app may suspend")
            }
        }
    }

    /// performExpiringActivity, once-only: `onEnd` runs when `wait` elapses, when the system ends the
    /// hold, or when the returned release closure is called — whichever first, exactly once.
    @discardableResult
    private func holdProcess(reason: String, upTo wait: TimeInterval, onEnd: @escaping (_ systemEnded: Bool) -> Void = { _ in }) -> () -> Void {
        let gate = DispatchSemaphore(value: 0)
        let once = NSLock(); var done = false
        let end: (Bool) -> Void = { s in once.lock(); let first = !done; done = true; once.unlock(); if first { onEnd(s) } }
        // granted before the caller goes on: asked for on another queue, a hold could come too late for a wake
        // that is ending (Trio, 26 October 19:55: a hold that never ran, the app suspended for 4.5 minutes)
        let begun = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
                begun.signal()
                if expired { end(true); gate.signal(); return }
                _ = gate.wait(timeout: .now() + wait); end(false)
            }
        }
        _ = begun.wait(timeout: .now() + 0.5)
        return { gate.signal() }
    }

    // MARK: - Bootstrap: the one scan pass (fresh install / sensor change / 3 misses)

    private func startBootstrapPass(reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard central.state == .poweredOn, !bootstrapPass else { return }
        bootstrapPass = true
        lastBootstrapAt = Date()
        // With no identifier there is nothing else to fall back on, so the scan stays up until the
        // sensor is found. With one, a short pass and then the daemon-held connect is the better bet.
        let untilFound = manager.activePeripheralIdentifier == nil
        watchLog(untilFound
                 ? "BOOTSTRAP scan — \(reason) (no identifier yet: scanning until the sensor is found)"
                 : "BOOTSTRAP scan pass — \(reason) (one pass, \(Int(G7WatchAcquisition.bootstrapScanCap)) s cap)")
        let services = [SensorServiceUUID.advertisement.cbUUID, SensorServiceUUID.cgmService.cbUUID]
        for p in central.retrieveConnectedPeripherals(withServices: services) { manager.handleDiscoveredPeripheral(p) }
        central.registerForConnectionEvents(options: [CBConnectionEventMatchingOption.serviceUUIDs: services])
        central.scanForPeripherals(withServices: [SensorServiceUUID.advertisement.cbUUID], options: nil)
        manager.delegate?.bluetoothManagerScanningStatusDidChange(manager)
        guard !untilFound else {
            manager.setIsSearchingForSensor(true)
            return
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + G7WatchAcquisition.bootstrapScanCap)
        t.setEventHandler { [weak self] in self?.endBootstrapPass(reason: "cap reached") }
        t.resume()
        bootstrapTimer = t
    }

    private func endBootstrapPass(reason: String) {
        guard bootstrapPass else { return }
        bootstrapPass = false
        bootstrapTimer?.cancel(); bootstrapTimer = nil
        manager.managerQueue_stopScanning()
        manager.setIsSearchingForSensor(false)
        watchLog("bootstrap pass over — \(reason)")
        guard reason != "connected" else { return }
        // Trio: the fresh connect lodged with the pass stays; only a request of unknown standing is cancelled.
        if !lodged, let p = manager.activePeripheral, p.state == .connecting { central.cancelPeripheralConnection(p); lodgedAt = nil }
        // Nothing adopted: stand down until the next wake (poweredOn / foreground / the phone's code).
        if manager.activePeripheralIdentifier != nil { scan() }
    }
}
