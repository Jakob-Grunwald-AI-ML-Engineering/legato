import LegatoCore
import LegatoMeetings
import SwiftUI

/// The colour of a speaker: the palette index the meeting stores. Each colour is mixed toward the text colour so it
/// reads on a light window as well as a dark one (system yellow and green alone do not).
enum SpeakerPalette {
    static let colors: [Color] = [.green, .blue, .purple, .orange, .pink, .teal, .brown, .red]
    static func color(_ index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count].mix(with: .primary, by: 0.35)
    }
}

/// The continuous transcript: a coloured speaker name over each run of one voice (click it to rename), a
/// right-aligned timestamp that seeks the player, the tentative text of the phrase in progress while recording.
/// A live transcript follows its newest line until the user scrolls up.
struct MeetingTranscriptView: View {
    let segments: [MeetingSegment]
    let speakers: [PersonID: SpeakerInfo]
    /// Narrows the transcript to the segments containing this text.
    let query: String
    /// The phrase being spoken now (recording only).
    var partial = ""
    var following = false
    /// There is audio to play: without it the timestamps are plain text.
    var canSeek = false
    let onSeek: (TimeInterval) -> Void
    /// Gives a person a new name (the same name as another person's merges them).
    let onRename: (PersonID, String) -> Void

    @State private var follow = TranscriptFollow()
    @State private var distanceFromBottom = 0.0
    @State private var renaming: PersonID?
    @State private var draft = ""

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
            .onScrollGeometryChange(for: Double.self) { geometry in
                max(0, geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height)
            } action: { _, distance in
                distanceFromBottom = distance
            }
            .onScrollPhaseChange { _, phase in
                if phase == .idle { follow.scrollSettled(distanceFromBottom: distanceFromBottom) }
            }
            .overlay {
                if shown.isEmpty {
                    Text(query.isEmpty ? (following ? "Listening…" : "No transcript.") : "No match.")
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottom) {
                if following, !follow.follows {
                    Button {
                        follow = TranscriptFollow()
                        proxy.scrollTo("end")
                    } label: { Label("Latest", systemImage: "arrow.down") }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .padding(.bottom, 10)
                        .accessibilityIdentifier("meeting.transcript.latest")
                }
            }
            .onChange(of: segments.count) { if following, follow.follows { proxy.scrollTo("end") } }
            .onChange(of: partial) { if following, follow.follows { proxy.scrollTo("end") } }
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
                    nameButton(person, name: name, color: color(of: segment))
                }
                Spacer()
                Button { onSeek(segment.start) } label: {
                    Text(MeetingListLogic.clock(segment.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSeek)
                .help(canSeek ? "Play from here" : "There is no recording to play yet")
                .accessibilityLabel("Play from \(MeetingListLogic.clock(segment.start))")
            }
            Text(segment.text).textSelection(.enabled)
        }
    }

    /// The name is a button: it opens a small field to rename the speaker, while recording too.
    private func nameButton(_ person: PersonID, name: String, color: Color) -> some View {
        Button {
            draft = name
            renaming = person
        } label: {
            Text(name).font(.callout.weight(.semibold)).foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .help("Rename this speaker")
        .accessibilityLabel("Rename \(name)")
        .accessibilityIdentifier("meeting.speaker.name")
        .popover(isPresented: Binding(get: { renaming == person }, set: { if !$0 { renaming = nil } })) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rename speaker").font(.headline)
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { commitRename(person) }
                Text("The same name as another speaker merges the two.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button("Rename") { commitRename(person) }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }

    private func commitRename(_ person: PersonID) {
        renaming = nil
        onRename(person, draft)
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
