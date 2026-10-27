import LegatoCore
import LegatoMeetings
import SwiftUI

/// The colour of a speaker: the palette index the meeting stores.
enum SpeakerPalette {
    static let colors: [Color] = [.green, .blue, .purple, .orange, .pink, .teal, .yellow, .red]
    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }
}

/// The continuous transcript: a coloured speaker name over each run of one voice, a right-aligned timestamp
/// that seeks the player, the tentative text of the phrase in progress while recording.
struct MeetingTranscriptView: View {
    let segments: [MeetingSegment]
    let speakers: [PersonID: SpeakerInfo]
    /// Narrows the transcript to the segments containing this text.
    let query: String
    /// The phrase being spoken now (recording only).
    var partial = ""
    var following = false
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        let shown = visible
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, segment in
                        row(segment, showsName: index == 0 || shown[index - 1].speaker != segment.speaker || shown[index - 1].stream != segment.stream)
                    }
                    if !partial.isEmpty {
                        Text(partial).foregroundStyle(.secondary).italic()
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .overlay {
                if shown.isEmpty {
                    Text(query.isEmpty ? (following ? "Listening…" : "No transcript.") : "No match.")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: segments.count) { if following { proxy.scrollTo("end") } }
            .onChange(of: partial) { if following { proxy.scrollTo("end") } }
        }
    }

    private var visible: [MeetingSegment] {
        let kept = segments.filter { !$0.echo }
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return kept }
        return kept.filter { s in words.allSatisfy { s.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
    }

    private func row(_ segment: MeetingSegment, showsName: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                if showsName, let name = name(of: segment) {
                    Text(name).font(.callout.weight(.semibold)).foregroundStyle(color(of: segment))
                }
                Spacer()
                Button { onSeek(segment.start) } label: {
                    Text(MeetingListLogic.clock(segment.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Play from here")
            }
            Text(segment.text).textSelection(.enabled)
        }
    }

    /// The speaker's name; none when unknown (meetings from before speakers included).
    private func name(of segment: MeetingSegment) -> String? {
        segment.speaker.flatMap { speakers[$0]?.name }
    }

    private func color(of segment: MeetingSegment) -> Color {
        switch segment.stream {
        case .mic: .accentColor
        case .system: .secondary
        case .mixed: segment.speaker.flatMap { speakers[$0] }.map { SpeakerPalette.color($0.colorIndex) } ?? .secondary
        }
    }
}
