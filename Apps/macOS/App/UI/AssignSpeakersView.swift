import LegatoAudio
import LegatoMeetings
import SwiftUI

/// Names the people of a meeting. Each shows its colour, a button that plays its first turn, and a name field.
/// Giving two people the same name merges them.
struct AssignSpeakersView: View {
    @Environment(MacAppController.self) private var app
    let meetingID: UUID
    let speakers: [PersonID: SpeakerInfo]
    let segments: [MeetingSegment]
    let player: MeetingPlayer?
    let onClose: () -> Void

    @State private var drafts: [PersonID: String] = [:]
    @State private var stopSample: Task<Void, Never>?
    @FocusState private var focused: PersonID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    commitAll()
                    onClose()
                } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help("Back to the transcript")
                    .accessibilityLabel("Back to the transcript")
                Text("Assign speakers").font(.headline)
            }
            .padding(.horizontal, 20).padding(.top, 12)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(people, id: \.id) { person in card(person.id, person.info) }
                    if people.isEmpty {
                        Text("No speakers were told apart in this meeting.").foregroundStyle(.secondary).padding(.top, 20)
                    }
                    Text("Speakers are named Speaker 1, 2, … Type a name to rename one. Two speakers with the same name become one.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
                .padding(.horizontal, 20)
            }
        }
        // A name typed without Return is kept when the field loses focus or the view goes away; the sample stops.
        .onChange(of: focused) { old, _ in
            if let old { commit(old, current: speakers[old]?.name ?? "") }
        }
        .onDisappear {
            stopSample?.cancel()
            player?.pause()
            commitAll()
        }
    }

    private var people: [(id: PersonID, info: SpeakerInfo)] {
        speakers.map { (id: $0.key, info: $0.value) }.sorted {
            (Int($0.id.dropFirst()) ?? 0) < (Int($1.id.dropFirst()) ?? 0)
        }
    }

    private func firstTurn(of person: PersonID) -> MeetingSegment? {
        segments.first { $0.speaker == person && !$0.echo }
    }

    private func card(_ id: PersonID, _ info: SpeakerInfo) -> some View {
        let color = SpeakerPalette.color(info.colorIndex)
        let sample = firstTurn(of: id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: Binding(get: { drafts[id] ?? info.name }, set: { drafts[id] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(color)
                    .focused($focused, equals: id)
                    .onSubmit { commit(id, current: info.name) }
                    .accessibilityLabel("Name of \(info.name)")
                Spacer()
                Button { if let sample { play(sample) } } label: { Image(systemName: "play.fill").foregroundStyle(color) }
                    .buttonStyle(.plain)
                    .disabled(sample == nil || player == nil)
                    .help(sample == nil ? "This speaker has no turn to play" : player == nil ? "There is no recording to play yet" : "Play this speaker's first turn")
                    .accessibilityLabel("Play \(info.name)'s first turn")
            }
            if let sample { Text(sample.text).lineLimit(2).font(.callout) }
        }
        .padding(12)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
    }

    private func commit(_ id: PersonID, current: String) {
        guard let draft = drafts[id], draft != current else { return }
        drafts[id] = nil
        Task { await app.meetings.renameSpeaker(id, to: draft, in: meetingID) }
    }

    /// Renames in order, one after the other: a merge changes the people the next rename sees.
    private func commitAll() {
        let changes = SpeakerDirectory.pendingRenames(drafts: drafts, speakers: speakers)
        drafts = [:]
        guard !changes.isEmpty else { return }
        let meetings = app.meetings, meetingID = meetingID
        Task { for change in changes { await meetings.renameSpeaker(change.id, to: change.name, in: meetingID) } }
    }

    /// Plays the segment, then stops at its end.
    private func play(_ segment: MeetingSegment) {
        guard let player else { return }
        stopSample?.cancel()
        player.seek(to: segment.start)
        player.play()
        let length = max(1, min(segment.end - segment.start, 20))
        stopSample = Task {
            try? await Task.sleep(for: .seconds(length))
            if !Task.isCancelled { player.pause() }
        }
    }
}
