import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct MeetingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetingAttributes.self) { context in
            MeetingActivityView(state: context.state, startedAt: context.attributes.startedAt)
        } dynamicIsland: { context in
            MeetingActivityView(state: context.state, startedAt: context.attributes.startedAt).island
        }
    }
}

struct MeetingActivityView: View {
    let state: MeetingAttributes.ContentState
    let startedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.2.wave.2.fill").foregroundStyle(.red)
                Text(title(state.phase)).font(.headline)
                Spacer()
                if state.phase == .recording { Text(startedAt, style: .timer).monospacedDigit() }
                if state.phase == .recording { stop }
            }
            if !state.tail.isEmpty { Text(state.tail).font(.callout).lineLimit(3) }
        }.padding().widgetURL(MeetingAttributes.openURL)
    }

    var island: DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.leading) { Image(systemName: "person.2.wave.2.fill").foregroundStyle(.red) }
            DynamicIslandExpandedRegion(.center) { Text(title(state.phase)).font(.headline) }
            DynamicIslandExpandedRegion(.trailing) { if state.phase == .recording { stop } }
            DynamicIslandExpandedRegion(.bottom) {
                VStack(alignment: .leading) {
                    if state.phase == .recording { Text(startedAt, style: .timer).monospacedDigit() }
                    Text(state.tail).lineLimit(3)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } compactLeading: {
            Image(systemName: "person.2.wave.2.fill").foregroundStyle(.red)
        } compactTrailing: {
            if state.phase == .recording { Text(startedAt, style: .timer).monospacedDigit().frame(width: 44) }
            else { Image(systemName: "pause.circle") }
        } minimal: {
            Image(systemName: "person.2.fill").foregroundStyle(.red)
        }.widgetURL(MeetingAttributes.openURL)
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
