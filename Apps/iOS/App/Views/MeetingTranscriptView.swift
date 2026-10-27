import LegatoCore
import LegatoMeetings
import SwiftUI

/// The colour of a speaker: the palette index the meeting stores. Each colour is mixed toward the text colour so it
/// reads on a light screen as well as a dark one (system yellow and green alone do not).
enum SpeakerPalette {
    static let colors: [Color] = [.green, .blue, .purple, .orange, .pink, .teal, .brown, .red]
    static func color(_ index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count].mix(with: .primary, by: 0.35)
    }
}

/// The continuous transcript: a coloured speaker name over each run of one voice (tap it to rename), a right-aligned
/// timestamp that seeks the player, and the tentative text of the phrase in progress while recording. It does not
/// scroll by itself: the document's scroll view carries it.
struct MeetingTranscriptView: View {
    let segments: [MeetingSegment]
    let speakers: [PersonID: SpeakerInfo]
    /// Narrows the transcript to the segments containing this text.
    let query: String
    /// The phrase being spoken now (recording only).
    var partial = ""
    var following = false
    var canSeek = false
    let onSeek: (TimeInterval) -> Void
    /// Gives a person a new name (the same name as another person's merges them).
    let onRename: (PersonID, String) -> Void

    @State private var renaming: PersonID?
    @State private var draft = ""

    var body: some View {
        let shown = visible
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, segment in
                row(
                    segment,
                    showsName: index == 0 || shown[index - 1].speaker != segment.speaker || shown[index - 1].stream != segment.stream)
            }
            if !partial.isEmpty {
                Text(partial).foregroundStyle(.secondary).italic()
            }
            if shown.isEmpty, partial.isEmpty {
                Text(query.isEmpty ? (following ? "Listening…" : "No transcript.") : "No match.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("meeting.transcript")
        .alert("Rename speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draft)
            Button("Rename") {
                if let person = renaming { onRename(person, draft) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("The same name as another speaker merges the two.")
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
                if showsName, let person = segment.speaker, let name = name(of: segment) {
                    Button {
                        draft = name
                        renaming = person
                    } label: {
                        Text(name).font(.callout.weight(.semibold)).foregroundStyle(color(of: segment))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rename \(name)")
                    .accessibilityIdentifier("meeting.speaker.name")
                }
                Spacer()
                Button { onSeek(segment.start) } label: {
                    Text(MeetingListLogic.clock(segment.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSeek)
                .accessibilityLabel("Play from \(MeetingListLogic.clock(segment.start))")
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
