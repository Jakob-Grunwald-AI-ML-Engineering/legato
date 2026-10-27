import LegatoMeetings
import SwiftUI

/// One finished meeting: Summary and Transcript tabs, and the actions on it.
struct MeetingDetailView: View {
    @Environment(MacAppController.self) private var app
    let meeting: Meeting

    private enum Tab: Hashable { case summary, transcript }

    @State private var tab = Tab.summary
    @State private var current: Meeting?
    @State private var segments: [MeetingSegment] = []
    @State private var summaries: [MeetingStore.Summary] = []
    @State private var pickedBackend: String?
    @State private var confirmClaude = false
    @State private var showEchoes = false

    private var meetings: MeetingController { app.meetings }
    private var shown: Meeting { current ?? meeting }
    private var working: Bool {
        meetings.busy.contains(meeting.id) || shown.state == .processing || shown.state == .interrupted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let notice = meetings.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("", selection: $tab) {
                Text("Summary").tag(Tab.summary)
                Text("Transcript").tag(Tab.transcript)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            switch tab {
            case .summary: summaryTab
            case .transcript: transcriptTab
            }
        }
        .padding(16)
        .task(id: meetings.revision) { await reload() }
        .confirmationDialog(
            "Send this transcript to Claude?", isPresented: $confirmClaude, titleVisibility: .visible
        ) {
            Button("Send to Claude") {
                meetings.claudeDisclosureAccepted = true
                meetings.summarizeWithClaude(meeting.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Summarizing with Claude sends this meeting's transcript to Anthropic over the internet, using your own API key. Nothing else leaves this Mac, and the on-device summary never does. This note is shown once.")
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shown.title).font(.title2.bold())
                Text("\(shown.date.formatted(date: .abbreviated, time: .shortened)) · \(Self.duration(shown.duration))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if working { ProgressView().controlSize(.small) }
            Menu("Actions") {
                Button("Export Markdown…") { Task { await meetings.exportMarkdown(shown) } }
                Button("Show audio in Finder") { Task { await meetings.showAudio(shown) } }
                Divider()
                Button("Improve transcript") { meetings.improve(meeting.id) }
                    .disabled(working)
                Button("Summarize with Claude") {
                    if meetings.claudeDisclosureAccepted {
                        meetings.summarizeWithClaude(meeting.id)
                    } else {
                        confirmClaude = true
                    }
                }
                .disabled(working || !meetings.hasClaudeKey)
                if !meetings.hasClaudeKey {
                    Text("Add a Claude key in Settings > Meetings")
                }
            }
            .fixedSize()
        }
    }

    @ViewBuilder private var summaryTab: some View {
        if summaries.isEmpty {
            Text(working ? "Working on it…" : "No summary yet.")
                .foregroundStyle(.secondary)
            Spacer()
        } else {
            let chosen = summaries.first { $0.backendID == pickedBackend } ?? summaries[0]
            if summaries.count > 1 {
                Picker("Summary by", selection: Binding(get: { chosen.backendID }, set: { pickedBackend = $0 })) {
                    ForEach(summaries, id: \.backendID) { Text(Self.backendName($0.backendID)).tag($0.backendID) }
                }
                .frame(maxWidth: 320)
            }
            ScrollView {
                Text(Self.markdown(chosen.text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var transcriptTab: some View {
        let visible = segments.filter { showEchoes || !$0.echo }
        if segments.contains(where: \.echo) {
            Toggle("Show echoes of the speakers picked up by the mic", isOn: $showEchoes)
                .toggleStyle(.checkbox).font(.callout)
        }
        if visible.isEmpty {
            Text(working ? "Working on it…" : "No transcript.").foregroundStyle(.secondary)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visible) { segment in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(segment.stream == .mic ? "Me" : "Them")
                                .font(.caption.bold())
                                .foregroundStyle(segment.stream == .mic ? Color.accentColor : .secondary)
                                .frame(width: 36, alignment: .leading)
                            Text(Self.stamp(segment.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(segment.text)
                                .foregroundStyle(segment.echo ? .secondary : .primary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Data

    private func reload() async {
        current = meetings.meetings.first { $0.id == meeting.id }
        segments = await meetings.transcript(of: meeting.id)
        summaries = await meetings.summaries(of: meeting.id)
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private static func backendName(_ id: String) -> String {
        switch id {
        case "claude": "Claude"
        case "foundation-models", "apple-foundation-models": "Apple Foundation Models"
        default: id
        }
    }

    private static func stamp(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
