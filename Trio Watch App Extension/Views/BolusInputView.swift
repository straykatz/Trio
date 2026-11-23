import Foundation
import SwiftUI
import WatchKit

// MARK: - Bolus Input View

struct BolusInputView: View {
    @Binding var navigationPath: NavigationPath
    @State private var bolusAmount = 0.0
    /// The phone's Reduced Bolus and Super Bolus for this meal, when the phone has the option on; one at a time.
    @State private var reducedBolus = false
    @State private var superBolus = false
    @State private var showsReminderPicker = false

    let state: WatchState

    @FocusState private var isCrownFocused: Bool

    private var effectiveBolusLimit: Double {
        Double(truncating: state.maxBolus as NSNumber)
    }

    var trioBackgroundColor = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        let bolusIncrement = Double(truncating: state.bolusIncrement as NSNumber)
        let adjustedBolusAmount = floor(bolusAmount / bolusIncrement) * bolusIncrement

        // In the "Meal & Bolus" flow the user can dial insulin down to zero (or the
        // recommendation itself is zero). In that case there is nothing to bolus, so
        // offer a plain "Log Carbs" action instead of a dead-end disabled button.
        let isCarbsOnly = state.carbsAmount > 0 && adjustedBolusAmount <= 0
        let actionButtonLabel = isCarbsOnly
            ? String(localized: "No Bolus, Log Carbs", comment: "Button Label to Log Carbs on Watch")
            : String(localized: "Enact Bolus")

        VStack {
            if state.showBolusCalculationProgress {
                ProgressView(String(
                    localized: "Calculating Bolus...",
                    comment: "Progress view text on watch when calculating bolus"
                ))
                Spacer()
            } else {
                if effectiveBolusLimit <= 0 {
                    VStack(spacing: 8) {
                        Text("Bolus limit cannot be fetched from phone!").font(.headline)
                        Text("Check device settings, connect to phone, and try again.").font(.caption)
                    }
                    .scenePadding()
                } else {
                    if state.carbsAmount > 0 {
                        // Display the current carb amount
                        HStack {
                            Text("Carbs:").bold().font(.subheadline).padding(.leading)
                            Text("\(state.carbsAmount) g").font(.subheadline).foregroundStyle(Color.orange)
                            Spacer()
                        }
                    }

                    Spacer()

                    HStack {
                        // "-" Button
                        Button(action: {
                            if bolusAmount > 0 { bolusAmount -= Double(truncating: state.bolusIncrement as NSNumber) }
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .font(.title3)
                                .tint(Color.insulin)
                        }
                        .buttonStyle(.borderless)
                        .disabled(bolusAmount <= 0)

                        Spacer()

                        Text(String(format: "%.2f \(String(localized: "U", comment: "Insulin unit"))", adjustedBolusAmount))
                            .fontWeight(.bold)
                            .font(.system(.title2, design: .rounded))
                            .foregroundColor(bolusAmount > 0.0 && bolusAmount >= effectiveBolusLimit ? .loopRed : .primary)
                            .focusable(true)
                            .focused($isCrownFocused)
                            .digitalCrownRotation(
                                $bolusAmount,
                                from: 0,
                                through: effectiveBolusLimit,
                                by: Double(truncating: state.bolusIncrement as NSNumber),
                                sensitivity: .medium,
                                isContinuous: false,
                                isHapticFeedbackEnabled: true
                            )

                        Spacer()

                        // "+" Button
                        Button(action: {
                            bolusAmount = min(
                                effectiveBolusLimit,
                                bolusAmount + Double(truncating: state.bolusIncrement as NSNumber)
                            )
                        }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .tint(Color.insulin)
                        }
                        .buttonStyle(.borderless)
                        .disabled(bolusAmount >= effectiveBolusLimit)
                    }.padding(.horizontal)

                    Text("Insulin")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.bottom, showsOptions ? 2 : nil)

                    if showsOptions {
                        HStack(spacing: 5) {
                            if state.offersReducedBolus {
                                optionButton(String(localized: "Reduced", comment: "Reduced bolus option on the watch"), isOn: reducedBolus) {
                                    reducedBolus.toggle()
                                    if reducedBolus { superBolus = false }
                                    state.requestBolusRecommendation(reducedBolus: reducedBolus, superBolus: superBolus)
                                }
                            }
                            if state.offersSuperBolus {
                                optionButton(String(localized: "Super", comment: "Super bolus option on the watch"), isOn: superBolus) {
                                    superBolus.toggle()
                                    if superBolus { reducedBolus = false }
                                    state.requestBolusRecommendation(reducedBolus: reducedBolus, superBolus: superBolus)
                                }
                            }
                            if offersReminder {
                                // Remind Me to Eat: the phone's presets to choose from, or none
                                optionButton(reminderLabel, isOn: state.mealTimeReminderMinutes > 0) {
                                    showsReminderPicker = true
                                }
                                .accessibilityLabel(String(localized: "Remind Me to Eat", comment: "Meal-time reminder on the watch"))
                                .confirmationDialog(
                                    String(localized: "Remind Me to Eat", comment: "Meal-time reminder on the watch"),
                                    isPresented: $showsReminderPicker,
                                    titleVisibility: .visible
                                ) {
                                    ForEach(state.mealTimeReminderPresets.filter { $0 > 0 }.sorted(), id: \.self) { minutes in
                                        Button(
                                            (minutes == state.mealTimeReminderMinutes ? "✓ " : "")
                                                + String(localized: "In \(minutes) min", comment: "Meal-time reminder preset on the watch")
                                        ) {
                                            state.mealTimeReminderMinutes = minutes
                                        }
                                    }
                                    Button(
                                        (state.mealTimeReminderMinutes == 0 ? "✓ " : "")
                                            + String(localized: "No Reminder", comment: "Meal-time reminder off on the watch")
                                    ) {
                                        state.mealTimeReminderMinutes = 0
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 4)
                    }

                    Spacer()

                    if bolusAmount > 0.0 && bolusAmount >= effectiveBolusLimit {
                        Text("Bolus Limit Reached!")
                            .font(.footnote)
                            .foregroundColor(.loopRed)
                    }

                    Button(actionButtonLabel) {
                        if isCarbsOnly {
                            state.sendCarbsEntry(state.carbsAmount, remindAfter: offersReminder ? state.mealTimeReminderMinutes : 0)
                            navigationPath.append(NavigationDestinations.acknowledgmentPending)
                        } else {
                            state.bolusAmount = min(bolusAmount, effectiveBolusLimit)
                            navigationPath.append(NavigationDestinations.bolusConfirm)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.insulin)
                    .disabled(!isCarbsOnly && (!(bolusAmount > 0.0) || bolusAmount > effectiveBolusLimit))

                    Text(String(
                        format: "\(String(localized: "Recommended:", comment: "Recommended bolus on Watch")) %.1f \(String(localized: "U", comment: "Insulin unit"))",
                        NSDecimalNumber(decimal: state.recommendedBolus).doubleValue
                    ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .background(trioBackgroundColor)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Image(systemName: "syringe.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .padding()
                    .background(Color.insulin)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
        }
        // The entry's 2 min clock restarts whenever the amount changes, including a recommendation landing
        .onChange(of: bolusAmount) { state.markEntryEdited() }
        .onAppear {
            state.markEntryEdited()
            // Set initial bolus amount to recommended value
            // Only do this if user has not updated amount previously, e.g., when navigating to next and then back to this view
            if bolusAmount == 0 {
                // a new meal: its reminder starts off, as on the phone
                state.mealTimeReminderMinutes = 0
                state.requestBolusRecommendation(reducedBolus: reducedBolus, superBolus: superBolus)
                bolusAmount = Double(truncating: NSDecimalNumber(decimal: state.recommendedBolus))
            }
        }
        // Add onChange to update bolus amount when recommendation changes
        .onChange(of: state.recommendedBolus) { oldValue, newValue in
            // Only update if user hasn't modified the value OR if recommendation hasn't changed
            if bolusAmount == 0 || oldValue != newValue {
                bolusAmount = Double(truncating: NSDecimalNumber(decimal: newValue))
            }
        }
    }

    /// The meal-time reminder, with carbs entered and the reminder on on the phone.
    private var offersReminder: Bool {
        state.mealTimeReminderEnabled && state.carbsAmount > 0 && state.mealTimeReminderPresets.contains { $0 > 0 }
    }

    private var showsOptions: Bool { state.offersReducedBolus || state.offersSuperBolus || offersReminder }

    private var reminderLabel: String {
        let minutes = state.mealTimeReminderMinutes
        return minutes > 0 ? "⏰ \(minutes)′" : "⏰"
    }

    /// A reduced or super bolus, on or off: the recommendation follows.
    private func optionButton(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2)
                .fontWeight(isOn ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(isOn ? Color.insulin : Color.gray.opacity(0.3)))
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
