import ActivityKit
import SwiftUI
import WidgetKit

extension MeetingActivityAttributes.ContentState {
    var title: LocalizedStringKey {
        switch phase {
        case .recording: "Recording meeting"
        case .muted: "Meeting muted"
        case .interrupted: "Meeting paused"
        case .saving: "Saving meeting…"
        }
    }

    var detail: LocalizedStringKey {
        switch phase {
        case .recording: "Recording on this iPhone."
        case .muted: "Your voice is not recorded until you unmute."
        case .interrupted: "Another app has the microphone. Legato resumes when it is free."
        case .saving: "The transcript and summary follow."
        }
    }

    var symbol: String {
        switch phase {
        case .recording: "record.circle.fill"
        case .muted: "mic.slash.fill"
        case .interrupted: "pause.circle.fill"
        case .saving: "square.and.arrow.down.fill"
        }
    }

    var tint: Color {
        switch phase {
        case .recording: .red
        case .muted: .orange
        case .interrupted: .yellow
        case .saving: .blue
        }
    }

    var isCounting: Bool { phase != .saving }
}

struct MeetingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetingActivityAttributes.self) { context in
            MeetingLockScreenView(state: context.state)
                .widgetURL(MeetingActivityAttributes.openURL)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.symbol).foregroundStyle(state.tint)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.isCounting {
                        Text(state.startedAt, style: .timer).monospacedDigit().frame(width: 64)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(state.detail)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
            } compactTrailing: {
                if state.isCounting {
                    Text(state.startedAt, style: .timer).monospacedDigit().frame(width: 44)
                }
            } minimal: {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
            }
            .widgetURL(MeetingActivityAttributes.openURL)
        }
    }
}

private struct MeetingLockScreenView: View {
    let state: MeetingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
                Text(state.title).font(.headline)
                Spacer()
                if state.isCounting {
                    Text(state.startedAt, style: .timer).font(.subheadline.monospacedDigit())
                }
            }
            Text(state.detail)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }
}
