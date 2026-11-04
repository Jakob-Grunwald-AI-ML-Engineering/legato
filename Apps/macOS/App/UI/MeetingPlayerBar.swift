import LegatoAudio
import LegatoMeetings
import SwiftUI

/// Play, pause and seek in a meeting's recording. The time moves by itself while playing, so a timer reads it.
struct MeetingPlayerBar: View {
    let player: MeetingPlayer
    @State private var scrubbing = false
    @State private var position = 0.0

    var body: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Text(MeetingListLogic.clock(scrubbing ? position : player.currentTime))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            Slider(value: Binding(get: { scrubbing ? position : player.currentTime }, set: { position = $0 }),
                   in: 0...max(player.duration, 1)) { scrubbing = $0; if !$0 { player.seek(to: position) } }
                .controlSize(.mini)
                .accessibilityLabel("Playback position")
            Text(MeetingListLogic.clock(player.duration))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .background(.bar)
        .task {
            while !Task.isCancelled {
                player.sync()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
