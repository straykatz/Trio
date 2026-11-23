import CoreData
import Foundation

extension NSPredicate {
    static var allOverridePresets: NSPredicate {
        NSPredicate(format: "isPreset == %@", true as NSNumber)
    }

    static var lastActiveOverride: NSPredicate {
        // For non-indefinite overrides, we still want to filter by date
        // For indefinite overrides, we want them regardless of date
        NSPredicate(
            format: "(date >= %@ OR indefinite == %@) AND enabled == %@",
            Date.oneDayAgo as NSDate,
            true as NSNumber,
            true as NSNumber
        )
    }
}

extension OverrideStored {
    static func fetch(_ predicate: NSPredicate, ascending: Bool, fetchLimit: Int? = nil) -> NSFetchRequest<OverrideStored> {
        let request = OverrideStored.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: ascending)]
        request.predicate = predicate
        if let fetchLimit = fetchLimit {
            request.fetchLimit = fetchLimit
        }
        return request
    }
}

extension OverrideStored {
    enum EventType: String, JSON {
        case nsExercise = "Exercise"
    }
}

extension OverrideStored {
    private static let untetheredButtonKey = "untetheredButtonOverrideIDs"

    /// Offers untethered watch mode next to this override's cancel button. Kept outside Core Data,
    /// so a build without untethered mode still opens the same store.
    var showUntetheredButton: Bool {
        get {
            guard let id else { return false }
            return (UserDefaults.standard.stringArray(forKey: Self.untetheredButtonKey) ?? []).contains(id)
        }
        set {
            guard let id else { return }
            var ids = Set(UserDefaults.standard.stringArray(forKey: Self.untetheredButtonKey) ?? [])
            if newValue { ids.insert(id) } else { ids.remove(id) }
            UserDefaults.standard.set(Array(ids), forKey: Self.untetheredButtonKey)
        }
    }
}
