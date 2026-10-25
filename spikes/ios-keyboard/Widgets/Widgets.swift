import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct LegatoWidgets: WidgetBundle {
    var body: some Widget {
        SessionLiveActivity()
        StartSessionControl()
        StopSessionControl()
    }
}

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionAttributes.self) { context in
            HStack {
                Image(systemName: "mic.fill").foregroundStyle(.red)
                VStack(alignment: .leading) {
                    Text("Legato session listening").font(.headline)
                    Text(context.state.startedAt, style: .timer).font(.caption.monospacedDigit())
                }
                Spacer()
                Button(intent: StopSessionIntent()) { Image(systemName: "stop.circle.fill").font(.title) }
                    .buttonStyle(.plain)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "mic.fill").foregroundStyle(.red) }
                DynamicIslandExpandedRegion(.center) { Text(context.state.startedAt, style: .timer) }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: StopSessionIntent()) { Image(systemName: "stop.circle.fill") }
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

struct StartSessionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "de.gruenwald.legato.spike1.start") {
            ControlWidgetButton(action: StartSessionIntent()) {
                Label("Start session", systemImage: "mic.fill")
            }
        }
        .displayName("Legato: start session")
        .description("Starts the Legato mic session without opening the app.")
    }
}

struct StopSessionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "de.gruenwald.legato.spike1.stop") {
            ControlWidgetButton(action: StopSessionIntent()) {
                Label("Stop session", systemImage: "mic.slash.fill")
            }
        }
        .displayName("Legato: stop session")
    }
}
