import Foundation
import SwiftUI
import WidgetKit

struct LiveActivityUpdatedLabelView: View {
    @Environment(\.isWatchOS) var isWatchOS

    var context: ActivityViewContext<LiveActivityAttributes>
    var isDetailedLayout: Bool

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    var body: some View {
        if context.state.watchMode == true {
            watchModeLabel
        } else {
            updatedLabel
        }
    }

    /// The watch loops: no time of the iPhone's last loop, which is old by design.
    @ViewBuilder private var watchModeLabel: some View {
        if isWatchOS || !isDetailedLayout {
            Label(String(localized: "Watch mode"), systemImage: "applewatch")
                .font(.subheadline)
                .bold()
                .foregroundStyle(.secondary)
        } else {
            VStack {
                Image(systemName: "applewatch")
                    .font(.title3)
                    .bold()
                Text("Watch mode")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder private var updatedLabel: some View {
        let dateText = Text("\((context.state.date != nil) ? dateFormatter.string(from: context.state.date!) : "--")")

        if isWatchOS {
            dateText
                .font(.subheadline)
                .bold()
                .foregroundStyle(context.isStale ? .red.opacity(0.6) : .secondary)
                .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

        } else if isDetailedLayout {
            VStack {
                dateText
                    .font(.title3)
                    .bold()
                    .foregroundStyle(context.isStale ? .red.opacity(0.6) : .primary)
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

                Text("Updated")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        } else {
            HStack {
                Text("Updated:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                dateText
                    .font(.subheadline)
                    .bold()
                    .foregroundStyle(context.isStale ? .red.opacity(0.6) : .secondary)
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
            }
        }
    }
}
