import Foundation
import SwiftUI
import WidgetKit

struct LiveActivityCOBLabelView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var additionalState: LiveActivityAttributes.ContentAdditionalState

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(context.state.watchMode == true ? "--" : "\(additionalState.cob)" as String)
                    .fontWeight(.bold)
                    .font(.title3)
                    .foregroundStyle(context.isStale || context.state.watchMode == true ? .secondary : .primary)
                    .strikethrough(context.isStale && context.state.watchMode != true, pattern: .solid, color: .red.opacity(0.6))

                Text(String(localized: "g", comment: "gram of carbs"))
                    .font(.headline).fontWeight(.bold)
                    .foregroundStyle(context.isStale || context.state.watchMode == true ? .secondary : .primary)
                    .strikethrough(context.isStale && context.state.watchMode != true, pattern: .solid, color: .red.opacity(0.6))
            }
            Text("COB")
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }
}
