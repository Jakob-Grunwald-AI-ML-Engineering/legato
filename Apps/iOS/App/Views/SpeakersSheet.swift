import LegatoAudio
import LegatoMeetings
import SwiftUI

/// Names the people of a meeting. Each shows its colour, a button that plays its first turn, and a name field.
/// Giving two people the same name merges them.
struct SpeakersSheet: View {
    let controller: MeetingController
    let meetingID: UUID
    let speakers: [PersonID: SpeakerInfo]
    let segments: [MeetingSegment]
    let player: MeetingPlayer?
    let onClose: () -> Void

    @State private var drafts: [PersonID: String] = [:]
    @State private var stopSample: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(people, id: \.id) { person in card(person.id, person.info) }
                    if people.isEmpty {
                        Text("No speakers were told apart in this meeting.").foregroundStyle(.secondary).padding(.top, 20)
                    }
                    Text("Speakers are named Speaker 1, 2, … Type a name to rename one. Two speakers with the same name become one.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
                .padding()
            }
            .navigationTitle("Assign speakers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        commitAll()
                        onClose()
                    }
                    .accessibilityIdentifier("speakers.done")
                }
            }
        }
        .onDisappear {
            stopSample?.cancel()
            player?.pause()
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
                Circle().fill(color).frame(width: 10, height: 10)
                TextField("Name", text: Binding(get: { drafts[id] ?? info.name }, set: { drafts[id] = $0 }))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(color)
                    .submitLabel(.done)
                    .onSubmit { commit(id, current: info.name) }
                Spacer()
                Button { if let sample { play(sample) } } label: {
                    Image(systemName: "play.fill").foregroundStyle(color).frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(sample == nil || player == nil)
                .accessibilityLabel("Play this speaker's first turn")
            }
            if let sample { Text(sample.text).lineLimit(2).font(.callout) }
        }
        .padding(12)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
    }

    private func commit(_ id: PersonID, current: String) {
        guard let draft = drafts[id], draft != current else { return }
        drafts[id] = nil
        Task { await controller.renameSpeaker(id, to: draft, in: meetingID) }
    }

    /// Renames in order, one after the other: a merge changes the people the next rename sees.
    private func commitAll() {
        let changes = speakers.compactMap { id, info -> (PersonID, String)? in
            guard let draft = drafts[id], draft != info.name else { return nil }
            return (id, draft)
        }
        drafts = [:]
        let controller = controller, meetingID = meetingID
        Task { for (id, name) in changes { await controller.renameSpeaker(id, to: name, in: meetingID) } }
    }

    /// Plays the segment, then stops at its end.
    private func play(_ segment: MeetingSegment) {
        guard let player else { return }
        stopSample?.cancel()
        stopSample = Task {
            await controller.preparePlayback()
            player.seek(to: segment.start)
            player.play()
            let length = max(1, min(segment.end - segment.start, 20))
            try? await Task.sleep(for: .seconds(length))
            if !Task.isCancelled { player.pause() }
        }
    }
}
