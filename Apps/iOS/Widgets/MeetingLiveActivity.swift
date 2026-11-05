import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct MeetingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetingAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "person.2.wave.2.fill").foregroundStyle(.red)
                    Text(title(context.state.phase)).font(.headline)
                    Spacer()
                    if context.state.phase == .recording { Text(context.attributes.startedAt, style: .timer).monospacedDigit() }
                    if context.state.phase == .recording { stop }
                }
                if !context.state.tail.isEmpty { Text(context.state.tail).font(.callout).lineLimit(3) }
            }.padding().widgetURL(MeetingAttributes.openURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "person.2.wave.2.fill").foregroundStyle(.red) }
                DynamicIslandExpandedRegion(.center) { Text(title(context.state.phase)).font(.headline) }
                DynamicIslandExpandedRegion(.trailing) { if context.state.phase == .recording { stop } }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading) {
                        if context.state.phase == .recording { Text(context.attributes.startedAt, style: .timer).monospacedDigit() }
                        Text(context.state.tail).lineLimit(3)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "person.2.wave.2.fill").foregroundStyle(.red)
            } compactTrailing: {
                if context.state.phase == .recording { Text(context.attributes.startedAt, style: .timer).monospacedDigit().frame(width: 44) }
                else { Image(systemName: "pause.circle") }
            } minimal: {
                Image(systemName: "person.2.fill").foregroundStyle(.red)
            }.widgetURL(MeetingAttributes.openURL)
        }
    }
    private var stop: some View {
        Button(intent: StopMeetingIntent()) { Image(systemName: "stop.circle.fill").font(.title) }.buttonStyle(.plain)
    }
    private func title(_ phase: MeetingAttributes.ContentState.Phase) -> String {
        switch phase {
        case .starting: "Starting meeting…"
        case .recording: "Meeting recording"
        case .stopping: "Saving meeting…"
        case .interrupted: "Meeting interrupted"
        }
    }
}
