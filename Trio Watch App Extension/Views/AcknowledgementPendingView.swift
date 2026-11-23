import SwiftUI

struct AcknowledgementPendingView: View {
    @Binding var navigationPath: NavigationPath
    let state: WatchState
    @Binding var shouldNavigateToRoot: Bool

    var trioBackgroundColor = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    var statusIcon: some View {
        switch state.acknowledgementStatus {
        case .pending:
            return Image(systemName: "progress.indicator").foregroundStyle(Color.secondary)
        case .success:
            return Image(systemName: "checkmark.circle").foregroundStyle(Color.loopGreen)
        case .failure:
            return Image(systemName: "xmark").foregroundStyle(Color.loopRed)
        }
    }

    /// After this long without an answer the screen offers a way out: the request goes on, its answer still comes.
    private static let closeAfter: TimeInterval = 15

    @State private var showsClose = false

    /// Nothing to show: no answer pending, no banner, no meal-and-bolus step.
    private var isIdle: Bool {
        !state.isMealBolusCombo && !state.showAcknowledgmentBanner && !state.showCommsAnimation
    }

    private func returnToRoot() {
        guard !navigationPath.isEmpty else { return }
        navigationPath.removeLast(navigationPath.count)
    }

    var body: some View {
        Group {
            VStack {
                if state.isMealBolusCombo {
                    ProgressView()
                    Text(state.mealBolusStep.rawValue).multilineTextAlignment(.center)
                } else if state.showAcknowledgmentBanner {
                    statusIcon.padding()
                    Text(state.acknowledgmentMessage).multilineTextAlignment(.center)
                        .foregroundStyle(state.acknowledgementStatus == .failure ? Color.loopRed : Color.primary)
                } else if state.showCommsAnimation {
                    ProgressView()
                    Text("Processing…")
                }
                if showsClose {
                    Button(String(localized: "Close", comment: "Leave the screen waiting for a bolus or carbs answer")) {
                        returnToRoot()
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 8)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden)
        .background(trioBackgroundColor)
        // WatchState times out a missing answer by showing a banner (beginAwaitingAcknowledgment), so every
        // request ends here. A timer in this view never started: the flag is already true when the view appears.
        .onChange(of: state.showAcknowledgmentBanner) { _, newValue in
            if !newValue {
                // Navigate back to the root when acknowledgment banner disappears
                returnToRoot()
            }
        }
        // By what is shown, not only by changes: a change seen in the background is missed. The answer can come and
        // go while the wrist is down (26 October, second tester: "Bolus started." at 16:39:27, the app in the
        // background at 16:39:29, the banner gone the same second), and back in front the screen stayed an empty
        // blue with no way out. "Processing" is set before this screen opens, so its 5-second timeout never ran,
        // and an untethered bolus waits for the pod without a limit. Paused while the app is suspended, this goes on
        // when it's back in front.
        .task {
            let opened = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let waited = Date().timeIntervalSince(opened)
                if isIdle, waited >= 1.5 {
                    returnToRoot()
                    return
                }
                if waited >= Self.closeAfter, !state.showAcknowledgmentBanner { showsClose = true }
            }
        }
        .onDisappear {
            state.shouldNavigateToRoot = true
        }
    }
}
