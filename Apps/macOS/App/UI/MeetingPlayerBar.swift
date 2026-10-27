import LegatoAudio
import LegatoMeetings
import SwiftUI

/// The player pill at the bottom of a meeting: play or pause, a position slider and the time. No speed control.
struct MeetingPlayerBar: View {
    let player: MeetingPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? "Pause" : "Play")
            Slider(
                value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 0.1))
                .controlSize(.small)
            Text("\(MeetingListLogic.clock(player.currentTime)) / \(MeetingListLogic.clock(player.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 460)
        .glassEffect(.regular, in: Capsule())
        // The time moves by itself while playing; read it a few times a second.
        .task {
            while !Task.isCancelled {
                player.sync()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
