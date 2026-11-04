import LegatoMeetings
import SwiftUI

/// What marks a speaker: one colour of a small palette, by the meeting's own index.
enum SpeakerPalette {
    static let colors: [Color] = [.blue, .orange, .green, .pink, .teal, .indigo, .brown, .mint]
    static func color(_ info: SpeakerInfo?) -> Color { colors[abs(info?.colorIndex ?? 0) % colors.count] }
}

/// A speaker's name; a click opens the field that renames them. A name that another person has merges the two.
struct SpeakerName: View {
    let person: PersonID
    let info: SpeakerInfo
    let rename: (PersonID, String) -> Void
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        Button { draft = info.name; editing = true } label: {
            Text(info.name).font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.plain)
        .help("Rename \(info.name)")
        .accessibilityLabel("Speaker \(info.name), rename")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Who is this?").font(.headline)
                TextField("Name", text: $draft).textFieldStyle(.roundedBorder).frame(width: 220).onSubmit(save)
                    .accessibilityIdentifier("meeting.speaker.name")
                Text("Giving two speakers the same name merges them.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                    Button("Rename", action: save).keyboardShortcut(.defaultAction).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("meeting.speaker.rename")
                }
            }
            .padding(16)
        }
    }

    private func save() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        editing = false
        if !name.isEmpty, name != info.name { rename(person, name) }
    }
}

/// The transcript, one row per turn: the speaker and the time the turn began, then what was said. The stretches the
/// connection missed are marked where they fall, and while recording the words still being recognised follow the last
/// turn. A click on a time moves the recording there.
///
/// A live transcript follows its newest line until the reader scrolls up, and follows again once they come back to the
/// bottom (`TranscriptFollow`). Growth of the content never counts as the reader's scroll.
struct MeetingTranscriptView: View {
    let meeting: Meeting
    let segments: [MeetingSegment]
    /// The tentative text of the segment in progress; recording only.
    let volatile: String
    let live: Bool
    let seek: ((TimeInterval) -> Void)?
    let rename: (PersonID, String) -> Void

    @State private var follow = TranscriptFollow()

    private enum Item: Identifiable {
        case turn(MeetingTurn)
        case gap(TranscriptGap)
        var id: String {
            switch self {
            case .turn(let turn): turn.id.uuidString
            case .gap(let gap): "gap-\(gap.start)"
            }
        }
        var start: TimeInterval {
            switch self {
            case .turn(let turn): turn.start
            case .gap(let gap): gap.start
            }
        }
    }

    private struct Metrics: Equatable { var offset: Double; var content: Double; var container: Double }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(items) { item in
                        switch item {
                        case .turn(let turn): row(turn)
                        case .gap(let gap): gapRow(gap)
                        }
                    }
                    if !volatile.isEmpty {
                        // What is still being recognised: lighter and italic until it settles into a turn.
                        Text(volatile).font(.body.italic()).lineSpacing(4).foregroundStyle(.tertiary)
                    } else if segments.isEmpty {
                        Text(live ? "Listening…" : "Nothing was transcribed.").foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .textSelection(.enabled)
            }
            // Starts at the top, so a short transcript is not pushed down; a live one follows its newest line once it
            // is longer than the pane.
            .task { if live { try? await Task.sleep(for: .milliseconds(150)); proxy.scrollTo("end", anchor: .bottom) } }
            .onScrollGeometryChange(for: Metrics.self) { geometry in
                Metrics(offset: geometry.contentOffset.y, content: geometry.contentSize.height, container: geometry.containerSize.height)
            } action: { old, new in
                if new.content != old.content || new.container != old.container {
                    // After the layout that grew the content, or the end it scrolls to is the old one.
                    if live && follow.follows { Task { @MainActor in proxy.scrollTo("end", anchor: .bottom) } }
                } else if new.offset != old.offset && new.container > 0 {
                    follow.scrollSettled(distanceFromBottom: new.content - new.offset - new.container)
                }
            }
        }
    }

    /// Turns and gaps in time order. A gap ends a turn.
    private var items: [Item] {
        let turns = MeetingTurns.merge(segments, breakingAt: meeting.gaps.map(\.start)).map(Item.turn)
        return (turns + meeting.gaps.map(Item.gap)).sorted { $0.start < $1.start }
    }

    private func row(_ turn: MeetingTurn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let person = turn.speaker, let info = meeting.speakers[person] {
                    Circle().fill(SpeakerPalette.color(info)).frame(width: 6, height: 6)
                    SpeakerName(person: person, info: info, rename: rename)
                }
                Button { seek?(turn.start) } label: {
                    Text(MeetingListLogic.clock(turn.start)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain).disabled(seek == nil)
                .accessibilityLabel("Play from \(MeetingListLogic.clock(turn.start))")
            }
            Text(turn.text).font(.body).lineSpacing(4)
        }
    }

    private func gapRow(_ gap: TranscriptGap) -> some View {
        Label("Transcript missing \(MeetingListLogic.clock(gap.start)) to \(MeetingListLogic.clock(gap.end)). The audio was recorded.",
              systemImage: "wifi.slash")
            .font(.callout).foregroundStyle(.orange)
    }
}
