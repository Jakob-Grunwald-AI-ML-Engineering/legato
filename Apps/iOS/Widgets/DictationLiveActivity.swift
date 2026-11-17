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

    /// Tapping a `tapToCopy` activity opens the app, which copies the last transcript.
}

struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationAttributes.self) { context in
            LockScreenView(state: context.state)
        } dynamicIsland: { context in
            let state = context.state
            if state.phase == .held || state.phase == .recovering { return heldIsland(state: state) }
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LegatoActivityGlyph()
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.phase.isRunning {
                        StopButton()
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

    var body: some View {
        if state.phase == .held || state.phase == .recovering { HeldRow(state: state) } else { runBody }
    }

    private var runBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                LegatoActivityGlyph()
                Text(state.title).font(.headline)
                Spacer()
                if state.phase.isRunning {
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

// MARK: - Held microphone (#229)

/// The background hold: the app keeps the microphone open and no take runs. Calm and narrow on purpose; iOS
/// keeps its own privacy dot next to it.
private func heldIsland(state: DictationAttributes.ContentState) -> DynamicIsland {
    DynamicIsland {
        DynamicIslandExpandedRegion(.leading) { HeldGlyph(state: state) }
        DynamicIslandExpandedRegion(.center) { HeldTitle(state: state) }
        DynamicIslandExpandedRegion(.trailing) { ReleaseButton() }
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

/// One slim row: glyph, title, Release.
private struct HeldRow: View {
    let state: DictationAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            HeldGlyph(state: state).font(.title3)
            Text(state.title).font(.headline)
            Spacer()
            ReleaseButton()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

/// Lets go of the held microphone, which ends this activity.
private struct ReleaseButton: View {
    var body: some View {
        Button(intent: ReleaseMicrophoneIntent()) {
            Text("Release").font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(.indigo)
    }
}
