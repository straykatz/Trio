import CoreData
import Foundation
import Swinject

class TrioRemoteControl: Injectable {
    // Container-scoped singleton; shared is a convenience accessor for APNS/App Intents entry points
    static var shared: TrioRemoteControl { TrioApp.resolver.resolve(TrioRemoteControl.self)! }

    @Injected() internal var tempTargetsStorage: TempTargetsStorage!
    @Injected() internal var carbsStorage: CarbsStorage!
    @Injected() internal var nightscoutManager: NightscoutManager!
    @Injected() internal var adjustmentManager: AdjustmentManager!
    @Injected() internal var settings: SettingsManager!
    @Injected() internal var bolusSafetyValidator: BolusSafetyValidator!
    @Injected() internal var carbEntryMutationService: CarbEntryMutationService!
    @Injected() internal var apsManager: APSManager!
    @Injected() internal var therapyProfileManager: TherapyProfileManager!

    private let timeWindow: TimeInterval = 600
    /// Command ids of profile commands, kept for twice the accepted clock skew.
    let seenProfileCommands = RemoteCommandReplayGuard(window: 1200)

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    func handleRemoteNotification(encryptedData: String) async throws {
        let isTrioRemoteControlEnabled = UserDefaults.standard.bool(forKey: "isTrioRemoteControlEnabled")
        guard isTrioRemoteControlEnabled else {
            await logError("Remote command received, but remote control is disabled in settings. Ignoring the command.")
            return
        }

        let storedSecret = UserDefaults.standard.string(forKey: "trioRemoteControlSharedSecret") ?? ""
        guard !storedSecret.isEmpty else {
            await logError("Command rejected: shared secret is missing in settings. Cannot authenticate the command.")
            return
        }

        guard let messenger = SecureMessenger(sharedSecret: storedSecret) else {
            await logError("Command rejected: Failed to initialize security module. The shared secret might be invalid.")
            return
        }

        let commandPayload: CommandPayload
        do {
            commandPayload = try messenger.decrypt(base64EncodedString: encryptedData)
        } catch {
            await logError(
                "Command rejected: Decryption failed. Mismatched shared secret or corrupted message. Error: \(error.localizedDescription)"
            )
            return
        }

        let currentTime = Date().timeIntervalSince1970
        let timeDifference = currentTime - commandPayload.timestamp

        if timeDifference > timeWindow {
            await logError(
                "Command rejected: the message is too old (sent \(Int(timeDifference)) seconds ago).",
                payload: commandPayload,
                ack: RemoteCommandAck(commandId: commandPayload.commandId, mealId: commandPayload.mealId, result: .rejected)
            )
            return
        } else if timeDifference < -timeWindow {
            await logError(
                "Command rejected: the message has an invalid future timestamp.",
                payload: commandPayload,
                ack: RemoteCommandAck(commandId: commandPayload.commandId, mealId: commandPayload.mealId, result: .rejected)
            )
            return
        }

        debug(.remote, "Command authenticated, sent \(Int(timeDifference)) s ago")

        guard UntetheredGate.state.session.isIdle else {
            switch commandPayload.commandType {
            case .bolus,
                 .meal:
                await forwardToWatch(commandPayload)
            case .startOverride,
                 .cancelOverride,
                 .tempTarget,
                 .cancelTempTarget:
                await forwardAdjustmentToWatch(commandPayload)
            default:
                await logError(
                    "Command rejected: the Apple Watch is running the loop (watch mode). Boluses, meals, overrides and temp targets reach it; this command doesn't.",
                    payload: commandPayload
                )
            }
            return
        }

        switch commandPayload.commandType {
        case .bolus:
            try await handleBolusCommand(commandPayload)
        case .tempTarget:
            try await handleTempTargetCommand(commandPayload)
        case .cancelTempTarget:
            await cancelTempTarget(commandPayload)
        case .meal:
            try await handleMealCommand(commandPayload)
        case .startOverride:
            await handleStartOverrideCommand(commandPayload)
        case .cancelOverride:
            await handleCancelOverrideCommand(commandPayload)
        case .deleteMeal:
            try await handleDeleteMealCommand(commandPayload)
        case .editMeal:
            try await handleEditMealCommand(commandPayload)
        case .switchProfile:
            await handleSwitchProfileCommand(commandPayload)
        case .saveProfile:
            await handleSaveProfileCommand(commandPayload)
        case .deleteProfile:
            await handleDeleteProfileCommand(commandPayload)
        case .saveScheduledSwitches:
            await handleSaveScheduledSwitchesCommand(commandPayload)
        case .unknown:
            await logError(
                "Command rejected: unsupported command type.",
                payload: commandPayload,
                ack: RemoteCommandAck(commandId: commandPayload.commandId, mealId: commandPayload.mealId, result: .rejected)
            )
        }
    }
}

extension TrioRemoteControl {
    /// While the Apple Watch has the pump the phone can't dose: a remote bolus or meal goes on to the watch, which checks
    /// it against its own IOB, history and limits (the phone's are behind) and delivers it. The phone checks what only it
    /// knows (the fat and protein limits) first. The answer goes back to the sender.
    func forwardToWatch(_ payload: CommandPayload) async {
        let carbs = payload.carbs.map { Decimal($0) }
        let fat = payload.fat.map { Decimal($0) }
        let protein = payload.protein.map { Decimal($0) }
        switch payload.commandType {
        case .bolus:
            guard let amount = payload.bolusAmount, amount > 0 else {
                await logError("Command rejected: bolus amount is missing or invalid.", payload: payload)
                return
            }
        default:
            guard carbs != nil || fat != nil || protein != nil else {
                await logError("Command rejected: meal data is incomplete or invalid.", payload: payload)
                return
            }
            let limits = settings.settings
            if let carbs, carbs > limits.maxCarbs {
                await logError(
                    "Command rejected: carbs amount (\(carbs)g) exceeds the maximum allowed (\(limits.maxCarbs)g).",
                    payload: payload
                )
                return
            }
            if let fat, fat > limits.maxFat {
                await logError(
                    "Command rejected: fat amount (\(fat)g) exceeds the maximum allowed (\(limits.maxFat)g).",
                    payload: payload
                )
                return
            }
            if let protein, protein > limits.maxProtein {
                await logError(
                    "Command rejected: protein amount (\(protein)g) exceeds the maximum allowed (\(limits.maxProtein)g).",
                    payload: payload
                )
                return
            }
        }
        guard let manager = TrioApp.resolver.resolve(UntetheredPhoneManager.self) else {
            await logError("Command rejected: the Apple Watch is running the loop and can't be reached.", payload: payload)
            return
        }
        // the same id as the copy LoopFollow sends straight to the watch: the watch acts on whichever comes first
        let treatment = UntetheredRemoteTreatment(
            id: UntetheredRemoteTreatment.id(
                sentAt: payload.timestamp,
                commandType: payload.commandType.rawValue,
                bolus: payload.bolusAmount,
                carbs: payload.carbs,
                fat: payload.fat,
                protein: payload.protein
            ),
            sentAt: Date(timeIntervalSince1970: payload.timestamp),
            bolus: payload.bolusAmount,
            carbs: payload.commandType == .meal ? carbs : nil,
            fat: payload.commandType == .meal ? fat : nil,
            protein: payload.commandType == .meal ? protein : nil,
            carbsDate: payload.scheduledTime.map { Date(timeIntervalSince1970: $0) }
        )
        let answer = await manager.forwardRemoteTreatment(treatment) { [weak self] late in
            Task { await self?.reportWatchAnswer(late, payload: payload, late: true) }
        }
        await reportWatchAnswer(answer, payload: payload, late: false)
    }

    /// An override or temp target while the watch has the pump: started or cancelled on the watch's own loop, which the
    /// phone takes over with the watch's history when it has the pump back.
    func forwardAdjustmentToWatch(_ payload: CommandPayload) async {
        let action: UntetheredRemoteAdjustment.Action
        switch payload.commandType {
        case .startOverride:
            guard let name = payload.overrideName, !name.isEmpty else {
                await logError("Command rejected: override name is missing.", payload: payload)
                return
            }
            action = .startOverride(name: name)
        case .tempTarget:
            guard let target = payload.target, let duration = payload.duration else {
                await logError("Command rejected: temp target data is incomplete or invalid.", payload: payload)
                return
            }
            action = .startTempTarget(targetMgdl: Decimal(target), minutes: Decimal(duration))
        case .cancelOverride:
            action = .cancelOverride
        default:
            action = .cancelTempTarget
        }
        guard let manager = TrioApp.resolver.resolve(UntetheredPhoneManager.self) else {
            await logError("Command rejected: the Apple Watch is running the loop and can't be reached.", payload: payload)
            return
        }
        let adjustment = UntetheredRemoteAdjustment(
            id: UntetheredRemoteAdjustment.id(
                sentAt: payload.timestamp,
                commandType: payload.commandType.rawValue,
                overrideName: payload.overrideName,
                target: payload.target,
                duration: payload.duration
            ),
            sentAt: Date(timeIntervalSince1970: payload.timestamp),
            action: action
        )
        let answer = await manager.forwardRemoteAdjustment(adjustment) { [weak self] late in
            Task { await self?.reportWatchAnswer(late, payload: payload, late: true) }
        }
        await reportWatchAnswer(answer, payload: payload, late: false)
    }

    private func reportWatchAnswer(
        _ answer: UntetheredPhoneManager.RemoteTreatmentAnswer,
        payload: CommandPayload,
        late: Bool
    ) async {
        switch answer {
        case .delivered(""):
            // the copy sent straight to the watch came first, and the watch answered the sender itself
            debug(.remote, "Remote command handled on the Apple Watch from its own push")
        case let .delivered(message):
            await logSuccess(
                "Remote command processed on the Apple Watch\(late ? " (late answer)" : ""). \(payload.humanReadableDescription())",
                payload: payload,
                customNotificationMessage: message
            )
        case let .refused(message):
            await logError(message, payload: payload)
        case .noAnswer:
            // not a failure: the watch may still get it, and acts on it until the command is 10 minutes old
            await logError(
                "No answer from the Apple Watch yet. It may still carry this out within 10 minutes of sending: check before sending again.",
                payload: payload
            )
        }
    }
}
