import LegatoMeetings
import SwiftUI

/// The meetings page: grouped by day, one card per meeting (title, one line of what it was about, the time),
/// and a search over everything.
struct MeetingListView: View {
    @Environment(MacAppController.self) private var app
    @Binding var selection: UUID?

    @State private var searching = false
    @State private var query = ""
    @State private var matches: Set<UUID>?
    /// The query `matches` answers; a different one means the scan is still running.
    @State private var matchedQuery = ""
    @State private var pendingDelete: Meeting?
    @FocusState private var searchFocused: Bool

    private var meetings: MeetingController { app.meetings }

    /// (identifier, name) of the languages a meeting can record in; nil is Auto.
    static let languages: [(id: String, name: String)] = [
        "bg-BG", "hr-HR", "cs-CZ", "da-DK", "nl-NL", "en-US", "en-GB", "et-EE", "fi-FI", "fr-FR", "de-DE", "el-GR", "hu-HU",
        "it-IT", "lv-LV", "lt-LT", "mt-MT", "pl-PL", "pt-PT", "ro-RO", "sk-SK", "sl-SI", "es-ES", "sv-SE", "ru-RU", "uk-UA",
    ].map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }.sorted { $0.1 < $1.1 }

    var body: some View {
        VStack(spacing: 0) {
            if searching {
                TextField("Search titles, summaries, notes, speakers and transcripts", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .padding(.horizontal, 20).padding(.top, 12)
                    .accessibilityIdentifier("meetings.search")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let id = meetings.liveMeetingID, query.isEmpty {
                        liveCard(id)
                    }
                    ForEach(groups, id: \.day) { group in
                        Text(MeetingListLogic.dayLabel(group.day))
                            .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.top, 10).padding(.leading, 4)
                        ForEach(group.meetings) { meeting in card(meeting) }
                    }
                    emptyState
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
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
        .confirmationDialog(
            "Delete this meeting?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible, presenting: pendingDelete
        ) { meeting in
            Button("Delete \"\(meeting.title)\"", role: .destructive) { Task { await meetings.delete(meeting) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The recording, the transcript, the summary and your notes move to the Trash.")
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { Text("Meetings").font(.headline) }
            ToolbarItem {
                Button {
                    searching.toggle()
                    if searching { searchFocused = true } else { query = "" }
                } label: { Label("Search", systemImage: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command)
                    .help("Search the meetings (⌘F)")
                    .accessibilityIdentifier("meetings.search.toggle")
            }
            ToolbarItem {
                Button {
                    if meetings.phase == .starting { meetings.cancelStart() } else if meetings.phase == .idle { Task { await meetings.start() } }
                } label: {
                    Label(meetings.phase == .starting ? "Cancel start" : "New meeting", systemImage: meetings.phase == .starting ? "xmark.circle" : "plus")
                }
                .disabled(meetings.isRecording && meetings.phase != .starting)
                .help("Start a meeting")
                .accessibilityIdentifier("meetings.start")
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = MeetingListLogic.emptyState(
            shownCount: groups.reduce(0) { $0 + $1.meetings.count }, hasLive: meetings.liveMeetingID != nil, query: query,
            searchReady: matches != nil && matchedQuery == trimmed)
        switch state {
        case .none:
            EmptyView()
        case .noMeetings:
            Text("No meetings yet.\nStart one with the + button or from the menu bar.")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.top, 60)
        case .searching:
            ProgressView("Searching…").controlSize(.small).frame(maxWidth: .infinity).padding(.top, 60)
        case .noMatch:
            Text("No meeting matches.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 60)
        }
    }

    private var groups: [MeetingDayGroup] {
        let listed = meetings.meetings.filter { $0.id != meetings.liveMeetingID && $0.state != .recording }
        let filtered = query.trimmingCharacters(in: .whitespaces).isEmpty ? listed : listed.filter { matches?.contains($0.id) ?? false }
        return MeetingListLogic.groupByDay(filtered)
    }

    private func liveCard(_ id: UUID) -> some View {
        Button { selection = id } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Recording", systemImage: "record.circle").foregroundStyle(.red).font(.headline)
                    Spacer()
                    Text(MeetingListLogic.clock(meetings.elapsed)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(meetings.live?.segments.last(where: { !$0.echo })?.text ?? "Listening…")
                    .lineLimit(2).foregroundStyle(.secondary)
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    private func card(_ meeting: Meeting) -> some View {
        Button { selection = meeting.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(meeting.title).font(.headline).lineLimit(1)
                    Spacer()
                    if meetings.isWorking(meeting.id) {
                        ProgressView().controlSize(.mini)
                    } else if meeting.state == .processing || meeting.state == .interrupted {
                        Image(systemName: "hourglass").font(.caption).foregroundStyle(.secondary).help("Waiting to be processed")
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
        }
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
