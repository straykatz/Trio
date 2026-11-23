import Foundation

// Trio: only what Trio/Sources/Helpers/TimeInterval+Convenience.swift doesn't already declare;
// that file is in the watch target too (the untethered loop), and the shared members would be
// redeclared. `seconds(_:)`, `minutes(_: Double)`, `hours(_:)`, `init(minutes:)`, `init(hours:)`,
// `minutes` and `hours` come from there.
extension TimeInterval {
    static func minutes(_ minutes: Int) -> TimeInterval {
        self.init(minutes: Double(minutes))
    }

    static func milliseconds(_ milliseconds: Double) -> TimeInterval {
        self.init(milliseconds / 1000)
    }

    init(seconds: Double) {
        self.init(seconds)
    }

    init(milliseconds: Double) {
        self.init(milliseconds / 1000)
    }

    var milliseconds: Double {
        self * 1000
    }
}
