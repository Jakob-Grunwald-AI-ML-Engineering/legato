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
        case .held: "Mic ready"
        case .recovering: "Reconnecting microphone…"
        }
    }

    /// The live text, or a prompt while nothing has been recognized yet.
    var body: String {
        if !tail.isEmpty { return tail }
        return phase.isRunning ? String(localized: "Speak now…") : ""
    }
}

struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationAttributes.self) { context in
            LockScreenView(state: context.state, holdID: context.attributes.holdID)
        } dynamicIsland: { context in
            let state = context.state
            let holdID = context.attributes.holdID
            if state.phase == .held || state.phase == .recovering { return heldIsland(state: state, holdID: holdID) }
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LegatoActivityGlyph()
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.phase.isRunning {
                        StopButton(holdID: holdID)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.body)
                            .font(.callout)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } compactLeading: {
                LegatoActivityGlyph()
            } compactTrailing: {
                EmptyView()
            } minimal: {
                LegatoActivityGlyph()
            }
        }
    }
}

private struct LockScreenView: View {
    let state: DictationAttributes.ContentState
    let holdID: String?

    var body: some View {
        HStack {
            HeldGlyph(state: state)
            Text(state.title).font(.headline)
            Spacer()
            if state.phase == .held {
                ReleaseButton(holdID: holdID)
            } else {
                StopButton(holdID: holdID)
            }
        }
        .padding()
    }
}

/// Finishes the keyboard take and releases the microphone associated with this activity.
private struct StopButton: View {
    let holdID: String?

    var body: some View {
        Button(intent: StopDictationIntent(holdID: holdID)) {
            Text("Stop").font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(.indigo)
    }
}

// MARK: - Held microphone (#229)

/// The background hold: the app keeps the microphone open and no take runs. Calm and narrow on purpose; iOS
/// keeps its own privacy dot next to it.
private func heldIsland(state: DictationAttributes.ContentState, holdID: String?) -> DynamicIsland {
    DynamicIsland {
        DynamicIslandExpandedRegion(.leading) { HeldGlyph(state: state) }
        DynamicIslandExpandedRegion(.center) { HeldTitle(state: state) }
        DynamicIslandExpandedRegion(.trailing) { ReleaseButton(holdID: holdID) }
    } compactLeading: {
        LegatoActivityGlyph()
    } compactTrailing: {
        EmptyView()
    } minimal: {
        LegatoActivityGlyph()
    }
}

private struct HeldGlyph: View {
    let state: DictationAttributes.ContentState

    var body: some View {
        if state.phase == .recovering {
            Image(systemName: "arrow.clockwise").foregroundStyle(.orange)
        } else {
            LegatoActivityGlyph()
        }
    }
}

private struct LegatoActivityGlyph: View {
    var body: some View {
        Image(systemName: "waveform").foregroundStyle(.indigo)
    }
}

private struct HeldTitle: View {
    let state: DictationAttributes.ContentState

    var body: some View {
        VStack(spacing: 2) {
            Text(state.title).font(.headline)
            Text("Legato keyboard").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Lets go of the held microphone, which ends this activity.
private struct ReleaseButton: View {
    let holdID: String?

    var body: some View {
        Button(intent: ReleaseMicrophoneIntent(holdID: holdID)) {
            Text("Release").font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(.indigo)
    }
}
