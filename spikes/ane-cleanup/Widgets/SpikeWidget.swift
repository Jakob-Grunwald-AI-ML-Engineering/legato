import ActivityKit
import SwiftUI
import WidgetKit

@main struct SpikeWidgets: WidgetBundle {
    var body: some Widget { RecordingWidget() }
}
struct RecordingWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpikeRecordingAttributes.self) { context in
            HStack {
                Text("ANE spike: \(context.state.phase)")
                Button(intent: SpikeToggleIntent()) { Image(systemName: "stop.circle") }
            }.padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) { Text("ANE spike: \(context.state.phase)") }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: SpikeToggleIntent()) { Image(systemName: "stop.circle") }
                }
            } compactLeading: { Image(systemName: "mic") }
              compactTrailing: { Text("39") }
              minimal: { Image(systemName: "mic") }
        }
    }
}
