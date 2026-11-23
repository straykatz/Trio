//
//  NSTimeInterval.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 1/9/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation

// Trio: only what Trio/Sources/Helpers/TimeInterval+Convenience.swift doesn't already declare;
// that file is in the watch target too (the untethered loop), and the shared members would be
// redeclared. `seconds(_:)`, `minutes(_: Double)`, `hours(_:)`, `init(minutes:)`, `init(hours:)`,
// `minutes` and `hours` come from there.
extension TimeInterval {
    static func minutes(_ minutes: Int) -> TimeInterval {
        return self.init(minutes: Double(minutes))
    }

    static func milliseconds(_ milliseconds: Double) -> TimeInterval {
        return self.init(milliseconds / 1000)
    }

    init(seconds: Double) {
        self.init(seconds)
    }

    init(milliseconds: Double) {
        self.init(milliseconds / 1000)
    }

    var milliseconds: Double {
        return self * 1000
    }
}
