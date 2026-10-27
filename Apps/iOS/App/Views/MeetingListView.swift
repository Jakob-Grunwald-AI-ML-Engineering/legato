import LegatoMeetings
import SwiftUI

/// The meetings page: grouped by day, one card per meeting (title, one line of what it was about, the time),
/// a search over everything, and the language the next meeting records in. A meeting that records is the
/// first card.
struct MeetingListView: View {
    let controller: AppController
    @Binding var opened: UUID?

    @State private var query = ""
    @State private var matches: Set<UUID>?

    private var meetings: MeetingController { controller.meetings }

    /// (identifier, name) of the languages a meeting can record in; nil is Auto.
    static let languages: [(id: String, name: String)] = [
        "bg-BG", "hr-HR", "cs-CZ", "da-DK", "nl-NL", "en-US", "en-GB", "et-EE", "fi-FI", "fr-FR", "de-DE", "el-GR", "hu-HU",
        "it-IT", "lv-LV", "lt-LT", "mt-MT", "pl-PL", "pt-PT", "ro-RO", "sk-SK", "sl-SI", "es-ES", "sv-SE", "ru-RU", "uk-UA",
    ].map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }.sorted { $0.1 < $1.1 }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let notice = meetings.notice, !meetings.isActive {
                    Label(notice, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .accessibilityIdentifier("meetings.notice")
                }
                if let id = meetings.liveMeetingID, query.isEmpty {
                    liveCard(id)
                }
                ForEach(groups, id: \.day) { group in
                    Text(MeetingListLogic.dayLabel(group.day))
                        .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, 10).padding(.leading, 4)
                    ForEach(group.meetings) { meeting in card(meeting) }
                }
                if groups.isEmpty, meetings.liveMeetingID == nil {
                    ContentUnavailableView(
                        query.isEmpty ? "No meetings yet" : "No meeting matches",
                        systemImage: query.isEmpty ? "person.2.wave.2" : "magnifyingglass",
                        description: Text(query.isEmpty
                            ? "Record a meeting in the room. Legato transcribes it as it goes and writes a summary afterwards." : ""))
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 20)
        }
        .searchable(text: $query, prompt: "Search meetings")
        .task(id: "\(query)/\(meetings.revision)") {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                matches = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await meetings.search(trimmed)
            if !Task.isCancelled { matches = found }
        }
    }

    private var groups: [MeetingDayGroup] {
        let listed = meetings.meetings.filter { $0.id != meetings.liveMeetingID && $0.state != .recording }
        let filtered = query.trimmingCharacters(in: .whitespaces).isEmpty ? listed : listed.filter { matches?.contains($0.id) ?? false }
        return MeetingListLogic.groupByDay(filtered)
    }

    private func liveCard(_ id: UUID) -> some View {
        Button { opened = id } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(meetings.statusText, systemImage: "record.circle").foregroundStyle(.red).font(.headline)
                    Spacer()
                    Text(MeetingListLogic.clock(meetings.elapsed)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(meetings.live?.segments.last(where: { !$0.echo })?.text ?? "Listening…")
                    .lineLimit(2).foregroundStyle(.secondary)
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("meetings.live")
    }

    private func card(_ meeting: Meeting) -> some View {
        Button { opened = meeting.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(meeting.title).font(.headline).lineLimit(1)
                    Spacer()
                    if meetings.busy.contains(meeting.id) || meeting.state == .processing || meeting.state == .interrupted {
                        ProgressView().controlSize(.mini)
                    }
                    Text(meeting.date.formatted(date: .omitted, time: .shortened)).font(.callout).foregroundStyle(.secondary)
                }
                let line = meetings.cards[meeting.id] ?? ""
                if !line.isEmpty { Text(line).lineLimit(2).foregroundStyle(.secondary) }
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", role: .destructive) { Task { await meetings.delete(meeting) } }
        }
        .accessibilityIdentifier("meetings.card")
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}
