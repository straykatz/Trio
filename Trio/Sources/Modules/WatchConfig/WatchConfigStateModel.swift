import Combine
import ConnectIQ
import SwiftUI

extension WatchConfig {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var garmin: GarminManager!

        @Published var units: GlucoseUnits = .mgdL
        @Published var devices: [IQDevice] = []
        @Published var confirmBolusFaster = false
        @Published var showForecastWatch = false
        @Published var allowUntetheredStartWithoutPhoneWatch = false
        @Published var fallbackLoopWatch = false
        @Published var untetheredWorkoutWatch = false
        @Published var watchGlanceLayout: WatchGlanceLayout = .standard
        @Published var watchGlanceEnabled = true
        @Published var untetheredModeWatch = true
        @Published var nightscoutUploadWatch = false
        @Published var untetheredTintHomeWatch = true

        /// Garmin watch settings containing all watch-related configuration
        @Published var garminSettings = GarminWatchSettings()

        private(set) var preferences = Preferences()

        override func subscribe() {
            preferences = provider.preferences
            units = settingsManager.settings.units

            // Subscribe to the entire garminSettings struct from TrioSettings
            subscribeSetting(\.garminSettings, on: $garminSettings) { garminSettings = $0 }
            subscribeSetting(\.confirmBolusFaster, on: $confirmBolusFaster) { confirmBolusFaster = $0 }
            subscribeSetting(\.showForecastWatch, on: $showForecastWatch) { showForecastWatch = $0 }
            subscribeSetting(\.allowUntetheredStartWithoutPhoneWatch, on: $allowUntetheredStartWithoutPhoneWatch) {
                allowUntetheredStartWithoutPhoneWatch = $0
            }
            subscribeSetting(\.fallbackLoopWatch, on: $fallbackLoopWatch) { fallbackLoopWatch = $0 }
            subscribeSetting(\.untetheredWorkoutWatch, on: $untetheredWorkoutWatch) { untetheredWorkoutWatch = $0 }
            subscribeSetting(\.watchGlanceLayout, on: $watchGlanceLayout) { watchGlanceLayout = $0 }
            subscribeSetting(\.watchGlanceEnabled, on: $watchGlanceEnabled) { watchGlanceEnabled = $0 }
            subscribeSetting(\.untetheredModeWatch, on: $untetheredModeWatch) { untetheredModeWatch = $0 }
            subscribeSetting(\.nightscoutUploadWatch, on: $nightscoutUploadWatch) { nightscoutUploadWatch = $0 }
            subscribeSetting(\.untetheredTintHomeWatch, on: $untetheredTintHomeWatch) { untetheredTintHomeWatch = $0 }

            devices = garmin.devices
        }

        /// Prompts the user to select Garmin devices and updates the device list
        func selectGarminDevices() {
            garmin.selectDevices()
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.devices, on: self)
                .store(in: &lifetime)
        }

        /// Updates the Garmin manager with the current device list
        func deleteGarminDevice() {
            garmin.updateDeviceList(devices)
        }

        /// Handles watchface selection changes by automatically disabling data transmission
        /// to allow the user to switch watchfaces on their Garmin device without data conflicts
        func handleWatchfaceChange() {
            garminSettings.isWatchfaceDataEnabled = false
        }

        /// Resumes data transmission after user confirms they have switched watchface on their device
        func resumeDataTransmission() {
            garminSettings.isWatchfaceDataEnabled = true
        }
    }
}

extension WatchConfig.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
