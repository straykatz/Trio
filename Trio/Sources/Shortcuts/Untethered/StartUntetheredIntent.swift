import AppIntents
import Foundation

/// Starts untethered watch mode from Shortcuts or an automation, without opening Trio on the phone. Trio must be
/// open on the watch: the phone can't wake it.
struct StartUntetheredIntent: AppIntent {
    static var title = LocalizedStringResource("Start Watch Mode")

    static var description = IntentDescription(.init(
        "Hands the pump and the CGM to the watch, which loops on its own until the pump is handed back. Trio must be open on the watch."
    ))

    /// A shortcut waits about this long for the watch to report the takeover.
    private static let resultWait = 25

    @MainActor func perform() async throws -> some ProvidesDialog {
        let manager = TrioApp.resolver.resolve(UntetheredPhoneManager.self)!
        if let refusal = await manager.start() {
            return .result(dialog: IntentDialog(stringLiteral: refusal))
        }
        for _ in 0 ..< Self.resultWait {
            switch manager.state.session.phase {
            case .active:
                return .result(dialog: IntentDialog(stringLiteral: String(
                    localized: "The watch has the pump and loops on its own."
                )))
            case .idle:
                return .result(dialog: IntentDialog(stringLiteral: manager.state.lastError ?? String(
                    localized: "The watch did not take over the pump."
                )))
            case .ending,
                 .preparing,
                 .starting:
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return .result(dialog: IntentDialog(stringLiteral: String(
            localized: "The watch is still taking over the pump. Trio on the phone shows when it has."
        )))
    }
}
