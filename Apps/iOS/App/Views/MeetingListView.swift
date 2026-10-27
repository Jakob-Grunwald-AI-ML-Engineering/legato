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
    /// The query `matches` answers; a different one means the scan is still running.
    @State private var matchedQuery = ""
    @State private var pendingDelete: Meeting?

    private var meetings: MeetingController { controller.meetings }

    /// (identifier, name) of the languages a meeting can record in; nil is Auto.
    static let languages: [(id: String, name: String)] = [
        "bg-BG", "hr-HR", "cs-CZ", "da-DK", "nl-NL", "en-US", "en-GB", "et-EE", "fi-FI", "fr-FR", "de-DE", "el-GR", "hu-HU",
        "it-IT", "lv-LV", "lt-LT", "mt-MT", "pl-PL", "pt-PT", "ro-RO", "sk-SK", "sl-SI", "es-ES", "sv-SE", "ru-RU", "uk-UA",
    ].map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }.sorted { $0.1 < $1.1 }

    var body: some View {
        List {
            ForEach(meetings.notices.global) { notice in
                HStack(spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(notice.text).font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button { meetings.dismissNotice(notice.id) } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                }
                .accessibilityIdentifier("meetings.notice")
                .rowStyle()
            }
            if meetings.phase == .starting {
                startingCard.rowStyle()
            }
            if let id = meetings.liveMeetingID, query.isEmpty {
                liveCard(id).rowStyle()
            }
            ForEach(groups, id: \.day) { group in
                Section {
                    ForEach(group.meetings) { meeting in
                        card(meeting)
                            .rowStyle()
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = meeting } label: { Label("Delete", systemImage: "trash") }
                                    .disabled(meetings.isWorking(meeting.id))
                            }
                    }
                } header: {
                    Text(MeetingListLogic.dayLabel(group.day))
                        .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay { emptyState }
        .searchable(text: $query, prompt: "Search meetings")
        .confirmationDialog(
            "Delete this meeting?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible, presenting: pendingDelete
        ) { meeting in
            Button("Delete \"\(meeting.title)\"", role: .destructive) { Task { await meetings.delete(meeting) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The recording, the transcript, the summary and your notes are deleted. This cannot be undone.")
        }
        .task(id: "\(query)/\(meetings.revision)") {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                matches = nil
                matchedQuery = ""
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await meetings.search(trimmed)
            if !Task.isCancelled {
                matches = found
                matchedQuery = trimmed
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = MeetingListLogic.emptyState(
            shownCount: groups.reduce(0) { $0 + $1.meetings.count }, hasLive: meetings.liveMeetingID != nil || meetings.phase == .starting,
            query: query, searchReady: matches != nil && matchedQuery == trimmed)
        switch state {
        case .none:
            EmptyView()
        case .noMeetings:
            ContentUnavailableView(
                "No meetings yet", systemImage: "person.2.wave.2",
                description: Text("Record a meeting in the room. Legato transcribes it as it goes; afterwards you name the speakers and summarize it."))
        case .searching:
            ProgressView("Searching…")
        case .noMatch:
            ContentUnavailableView("No meeting matches", systemImage: "magnifyingglass")
        }
    }

    /// Between the tap on Start and the first words: the speech model loads, the audio session opens.
    private var startingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Starting meeting…").font(.headline)
            Spacer()
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meetings.starting")
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
                    if meetings.isWorking(meeting.id) {
                        ProgressView().controlSize(.mini)
                    } else if meeting.state == .processing || meeting.state == .interrupted {
                        Image(systemName: "hourglass").font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("Waiting to be processed")
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
            Button("Delete…", role: .destructive) { pendingDelete = meeting }
                .disabled(meetings.isWorking(meeting.id))
        }
        .accessibilityIdentifier("meetings.card")
    }
}

private extension View {
    /// A card in a list: no separator, no row background, a little air.
    func rowStyle() -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }

    func cardStyle() -> some View {
        padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}
