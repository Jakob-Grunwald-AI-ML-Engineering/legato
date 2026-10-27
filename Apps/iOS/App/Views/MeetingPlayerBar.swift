import LegatoAudio
import LegatoMeetings
import SwiftUI

/// The player pill at the bottom of a meeting: play or pause, a position slider and the time. No speed control.
struct MeetingPlayerBar: View {
    let player: MeetingPlayer
    /// Runs before playback starts (audio session for playing).
    let beforePlay: () async -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if player.isPlaying {
                    player.pause()
                } else {
                    Task {
                        await beforePlay()
                        player.play()
                    }
                }
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("meeting.player.toggle")
            Slider(
                value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 0.1))
            Text("\(MeetingListLogic.clock(player.currentTime)) / \(MeetingListLogic.clock(player.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 16)
        // The time moves by itself while playing; read it a few times a second.
        .task {
            while !Task.isCancelled {
                player.sync()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
