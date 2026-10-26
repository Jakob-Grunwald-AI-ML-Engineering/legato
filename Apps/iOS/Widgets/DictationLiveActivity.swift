import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

extension DictationAttributes.ContentState {
    var title: LocalizedStringKey {
        switch phase {
        case .starting: "Starting…"
        case .listening: "Listening"
        case .finishing: "Finishing…"
        case .copied: "Copied"
        case .tapToCopy: "Tap to copy"
        case .failed: "Nothing recognized"
        }
    }

    var symbol: String {
        switch phase {
        case .starting, .listening, .finishing: "mic.fill"
        case .copied: "checkmark.circle.fill"
        case .tapToCopy: "doc.on.clipboard"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch phase {
        case .starting, .listening, .finishing: .red
        case .copied: .green
        case .tapToCopy: .blue
        case .failed: .orange
        }
    }

    /// The live text, or a prompt while nothing has been recognized yet.
    var body: String {
        if !tail.isEmpty { return tail }
        return phase.isRunning ? String(localized: "Speak now…") : ""
    }

    /// Tapping a `tapToCopy` activity opens the app, which copies the last transcript.
    var tapURL: URL? { phase == .tapToCopy ? DictationAttributes.copyLastURL : nil }
}

struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationAttributes.self) { context in
            LockScreenView(state: context.state)
                .widgetURL(context.state.tapURL)
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
                    if state.phase.isRunning {
                        StopButton()
                    } else {
                        Text(state.startedAt, style: .timer).monospacedDigit().hidden()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(state.body)
                        .font(.callout)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
            } compactTrailing: {
                if state.phase.isRunning {
                    Text(state.startedAt, style: .timer).monospacedDigit().frame(width: 44)
                } else {
                    Image(systemName: state.symbol).foregroundStyle(state.tint)
                }
            } minimal: {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
            }
            .widgetURL(state.tapURL)
        }
    }
}

private struct LockScreenView: View {
    let state: DictationAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
                Text(state.title).font(.headline)
                Spacer()
                if state.phase.isRunning {
                    Text(state.startedAt, style: .timer).font(.subheadline.monospacedDigit())
                    StopButton()
                }
            }
            Text(state.body)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }
}

/// Stops the running dictation. A stop-only intent, not the toggle: a press that lands after the run ended
/// (a stale activity, a double tap) must do nothing, never start a new dictation.
private struct StopButton: View {
    var body: some View {
        Button(intent: StopDictationIntent()) {
            Image(systemName: "stop.circle.fill").font(.title)
        }
        .buttonStyle(.plain)
    }
}
