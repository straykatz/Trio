import Foundation
import G7SensorKit
import LoopKit
import OmnipodKit

// The only place the watch names device kits, keyed by `pluginIdentifier` (what an export carries).
// A pump or CGM missing here makes the watch refuse the grant with a clear reason.
// ponytail: Omnipod Eros needs a RileyLink the watch doesn't have; its takeover fails within the lease
// and the phone keeps the pod.

/// The kits' `pluginIdentifier`s. On LoopKit next-dev it is an instance property only, so the names are written out;
/// they have to match the kits' (OmniPumpManager: "Omni", G7CGMManager: "G7CGMManager").
enum WatchPluginIdentifier {
    static let omnipod = "Omni"
    static let g7 = "G7CGMManager"
}

let watchPumpManagers: [String: (PumpManager & ExclusiveDeviceControl).Type] = [
    WatchPluginIdentifier.omnipod: OmniPumpManager.self
]

let watchCGMManagers: [String: (CGMManager & DeviceConfigurationSharing).Type] = [
    WatchPluginIdentifier.g7: G7CGMManager.self
]

/// Why the sensor's newest message brought no reading the loop can use, when the sensor itself says so: the watch is
/// in contact with it then, and "keep it near the sensor" points the wrong way (27 October, second tester: a
/// temporary sensor issue at 19:05 and 19:10, and "No Sensor Readings … keep it near the sensor" at 19:12).
enum WatchSensorProblem {
    case temporaryIssue
    case failed
    case warmup
}

func watchCGMSensorProblem(_ manager: CGMManager?, now: Date = Date()) -> WatchSensorProblem? {
    guard let g7 = manager as? G7CGMManager, let message = g7.latestReading, let at = g7.latestReadingTimestamp,
          now.timeIntervalSince(at) < 11 * 60
    else { return nil }
    let state = message.algorithmState
    if state.sensorFailed { return .failed }
    if state.isInWarmup { return .warmup }
    if state.hasTemporaryError { return .temporaryIssue }
    return nil
}

/// On a wake that isn't the sensor's own, the G7's acquisition re-checks itself: a lost Bluetooth
/// callback can leave no connect standing and nothing that notices.
func watchCGMRecheckAcquisition(_ manager: CGMManager?) {
    (manager as? G7CGMManager)?.recheckAcquisition()
}

/// The sensor's link is up right now: a reading or its backfill is on the radio.
func watchCGMIsConnected(_ manager: CGMManager?) -> Bool {
    (manager as? G7CGMManager)?.isConnected ?? false
}

/// The pod's reservoir as the phone shows it: the measured level up to 50 U, above that the phone's "50+ U"
/// marker; nil for a pump without one.
func watchPumpReservoir(_ pump: PumpManager?) -> Decimal? {
    guard let pod = (pump as? OmniPumpManager)?.state.podState else { return nil }
    if let level = pod.lastInsulinMeasurements?.reservoirLevel, level <= 50 { return Decimal(level) }
    return Decimal(UInt32(0xDEAD_BEEF))
}

/// When the pod expires; nil for a pump without one.
func watchPumpExpiresAt(_ pump: PumpManager?) -> Date? {
    (pump as? OmniPumpManager)?.state.podState?.expiresAt
}

/// When the pod was activated; nil for a pump without one.
func watchPumpActivatedAt(_ pump: PumpManager?) -> Date? {
    (pump as? OmniPumpManager)?.state.podState?.activatedAt
}

/// The state the CGM kit's adopt would build from another controller's export, for the session that takes the watch
/// reader's key instead: built here as a plain state, because building the adopted manager to read its state opens a
/// Bluetooth central, and a second manager's central under the same restore identifier never came up (1 November,
/// 20:33). Nil for a kit the reader doesn't serve.
func watchCGMReaderState(_ configuration: SharedDeviceConfiguration) -> [String: Any]? {
    guard configuration.managerIdentifier == WatchPluginIdentifier.g7 else { return nil }
    var state = configuration.state
    state["configuredByAnotherController"] = true
    state["sessionMode"] = G7SessionMode.direct.rawValue
    state["pairedAt"] = Date()
    return state
}

/// When the sensor's session ends, as the phone's home header counts it (into the grace period once expired).
func watchCGMExpiresAt(_ manager: CGMManager?) -> Date? {
    guard let g7 = manager as? G7CGMManager else { return nil }
    if let expires = g7.sensorExpiresAt, expires > Date() { return expires }
    return g7.sensorEndsAt ?? g7.sensorExpiresAt
}

/// Deactivates and forgets the pod, as the phone's deactivate screen does; false for a pump this can't do.
func watchDeactivatePod(_ pump: PumpManager, completion: @escaping (Error?) -> Void) -> Bool {
    guard let omni = pump as? OmniPumpManager else { return false }
    omni.deactivateAndForgetPod(completion: completion)
    return true
}

/// Forgets a pod that doesn't answer; false for a pump this can't do.
func watchDiscardPod(_ pump: PumpManager, completion: @escaping () -> Void) -> Bool {
    guard let omni = pump as? OmniPumpManager else { return false }
    omni.discardPod(completion: completion)
    return true
}
