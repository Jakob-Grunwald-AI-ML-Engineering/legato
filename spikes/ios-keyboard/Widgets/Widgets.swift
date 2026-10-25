import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct LegatoWidgets: WidgetBundle {
    var body: some Widget {
        SessionLiveActivity()
        ToggleDictationControl()
    }
}

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionAttributes.self) { context in
            HStack {
                Image(systemName: "mic.fill").foregroundStyle(.red)
                VStack(alignment: .leading) {
                    Text("Legato dictating").font(.headline)
                    Text(context.state.startedAt, style: .timer).font(.caption.monospacedDigit())
                }
                Spacer()
                Button(intent: ToggleDictationIntent(source: "live-activity")) { Image(systemName: "stop.circle.fill").font(.title) }
                    .buttonStyle(.plain)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "mic.fill").foregroundStyle(.red) }
                DynamicIslandExpandedRegion(.center) { Text(context.state.startedAt, style: .timer) }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: ToggleDictationIntent(source: "live-activity")) { Image(systemName: "stop.circle.fill") }
                }
            } compactLeading: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer).frame(width: 44)
            } minimal: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            }
        }
    }
}

struct ToggleDictationControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "de.gruenwald.legato.spike1.toggle") {
            ControlWidgetButton(action: ToggleDictationIntent(source: "control-center")) {
                Label("Toggle dictation", systemImage: "mic.fill")
            }
        }
        .displayName("Legato: toggle dictation")
        .description("Starts dictation, or stops it when already running.")
    }
}
