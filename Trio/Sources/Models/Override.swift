import Foundation

struct Override: Codable, Equatable {
    let name: String
    let enabled: Bool
    let date: Date
    let duration: Decimal
    let indefinite: Bool
    let percentage: Double
    let smbIsOff: Bool
    let isPreset: Bool
    let id: String
    let overrideTarget: Bool
    let target: Decimal
    let advancedSettings: Bool
    let isfAndCr: Bool
    let isf: Bool
    let cr: Bool
    let smbIsScheduledOff: Bool
    let start: Decimal
    let end: Decimal
    let smbMinutes: Decimal
    let uamMinutes: Decimal
    /// Offers untethered watch mode next to the override's cancel button on the home screen.
    var showUntetheredButton = false
}
