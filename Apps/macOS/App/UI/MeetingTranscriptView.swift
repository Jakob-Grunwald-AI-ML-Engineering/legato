import LegatoMeetings
import SwiftUI

/// What marks a speaker: one colour of a small palette, by the meeting's own index.
enum SpeakerPalette {
    static let colors: [Color] = [.blue, .orange, .green, .pink, .teal, .indigo, .brown, .mint]
    static func color(_ info: SpeakerInfo?) -> Color { colors[abs(info?.colorIndex ?? 0) % colors.count] }
}

/// The speakers of a meeting, in order of appearance, each one a chip that renames the person.
struct SpeakerStrip: View {
    let meeting: Meeting
    let rename: (PersonID, String) -> Void

    var body: some View {
        if !meeting.speakers.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(people, id: \.0) { id, info in SpeakerName(person: id, info: info, rename: rename, chip: true) }
            }
        }
    }

    private var people: [(PersonID, SpeakerInfo)] {
        meeting.speakers.sorted { (Int($0.key.dropFirst()) ?? 0) < (Int($1.key.dropFirst()) ?? 0) }.map { ($0.key, $0.value) }
    }
}

/// A speaker's name; a click opens the field that renames them. A name that another person has merges the two.
struct SpeakerName: View {
    let person: PersonID
    let info: SpeakerInfo
    let rename: (PersonID, String) -> Void
    var chip = false
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        Button { draft = info.name; editing = true } label: {
            HStack(spacing: 5) {
                Circle().fill(SpeakerPalette.color(info)).frame(width: 8, height: 8)
                Text(info.name).fontWeight(.semibold)
                if chip { Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, chip ? 9 : 0).padding(.vertical, chip ? 4 : 0)
            .background(chip ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Rename \(info.name)")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Who is this?").font(.headline)
                TextField("Name", text: $draft).frame(width: 220).onSubmit(save)
                Text("Giving two speakers the same name merges them.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                    Button("Rename", action: save).keyboardShortcut(.defaultAction).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)
        }
    }

    private func save() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        editing = false
        if !name.isEmpty, name != info.name { rename(person, name) }
    }
}

/// The transcript: speech under its speaker with the time it started, the stretches the connection missed, and while
/// recording the words still being recognised. A click on a time moves the recording there.
struct MeetingTranscriptView: View {
    let meeting: Meeting
    let segments: [MeetingSegment]
    /// The tentative text of the segment in progress; recording only.
    let volatile: String
    let live: Bool
    let seek: ((TimeInterval) -> Void)?
    let rename: (PersonID, String) -> Void

    fileprivate enum Item: Identifiable {
        case spoken(MeetingSegment, showsName: Bool)
        case gap(TranscriptGap)
        var id: String {
            switch self {
            case .spoken(let segment, _): segment.id.uuidString
            case .gap(let gap): "gap-\(gap.start)"
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                SpeakerStrip(meeting: meeting, rename: rename).padding(.bottom, 4)
                ForEach(items) { item in
                    switch item {
                    case .spoken(let segment, let showsName): line(segment, showsName: showsName)
                    case .gap(let gap): gapRow(gap)
                    }
                }
                if !volatile.isEmpty {
                    Text(volatile).foregroundStyle(.secondary).padding(.leading, 58)
                } else if live && segments.isEmpty {
                    Text("Listening…").foregroundStyle(.secondary)
                } else if !live && segments.isEmpty {
                    Text("Nothing was transcribed.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .textSelection(.enabled)
        }
        .defaultScrollAnchor(live ? .bottom : .top, for: .sizeChanges)
    }

    /// Segments and gaps in time order; a speaker's name is shown when the speaker changes and after a gap.
    private var items: [Item] {
        enum Entry { case segment(MeetingSegment), gap(TranscriptGap) }
        let entries = (segments.map(Entry.segment) + meeting.gaps.map(Entry.gap)).sorted {
            func start(_ e: Entry) -> TimeInterval { switch e { case .segment(let s): s.start; case .gap(let g): g.start } }
            return start($0) < start($1)
        }
        var items: [Item] = []
        var lastSpeaker: PersonID?
        var showName = true
        for entry in entries {
            switch entry {
            case .gap(let gap):
                items.append(.gap(gap))
                showName = true
            case .segment(let segment):
                items.append(.spoken(segment, showsName: showName || segment.speaker != lastSpeaker))
                lastSpeaker = segment.speaker
                showName = false
            }
        }
        return items
    }

    private func line(_ segment: MeetingSegment, showsName: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button { seek?(segment.start) } label: {
                Text(MeetingListLogic.clock(segment.start)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain).frame(width: 46, alignment: .trailing).disabled(seek == nil)
            VStack(alignment: .leading, spacing: 2) {
                if showsName, let person = segment.speaker, let info = meeting.speakers[person] {
                    SpeakerName(person: person, info: info, rename: rename)
                }
                Text(segment.text)
            }
        }
    }

    private func gapRow(_ gap: TranscriptGap) -> some View {
        Label("Transcript missing \(MeetingListLogic.clock(gap.start)) to \(MeetingListLogic.clock(gap.end)). The audio was recorded.",
              systemImage: "wifi.slash")
            .font(.callout).foregroundStyle(.orange)
            .padding(.leading, 58)
    }
}
