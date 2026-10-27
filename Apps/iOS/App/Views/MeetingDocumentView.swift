import LegatoAppServices
import LegatoMeetings
import SwiftUI

/// The meeting as one scrolling document: the title, the template, then Summary, Transcript and Notes as
/// segments. The summary has Regenerate and the stale-notes prompt; the private notes feed the summary.
struct MeetingDocumentView: View {
    let controller: AppController
    let meeting: Meeting
    let isLive: Bool
    let segments: [MeetingSegment]
    let summaries: [MeetingStore.Summary]
    let working: Bool
    @Binding var notes: String
    let canSeek: Bool
    let onSeek: (TimeInterval) -> Void
    let onSpeakers: () -> Void

    private enum Segment: Hashable { case summary, transcript, notes }

    @State private var segment = Segment.summary
    @State private var title = ""
    @State private var query = ""
    @State private var processRequested = false
    @State private var started = false
    @FocusState private var titleFocused: Bool

    private var meetings: MeetingController { controller.meetings }
    private var templates: [SummaryTemplate] { meetings.settings.allTemplates }
    private var shown: MeetingStore.Summary? { MeetingListLogic.shownSummary(in: summaries, templateID: meeting.templateID) }
    private var waitingForHeavySteps: Bool { meeting.state == .processing || meeting.state == .interrupted }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    banners
                    Picker("", selection: $segment) {
                        Text("Summary").tag(Segment.summary)
                        Text("Transcript").tag(Segment.transcript)
                        Text("Notes").tag(Segment.notes)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("meeting.segments")
                    switch segment {
                    case .summary: summarySection
                    case .transcript: transcriptSection
                    case .notes: notesSection
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: segments.count) { if isLive, segment == .transcript { proxy.scrollTo("end") } }
            .onChange(of: meetings.live?.volatile[.mixed] ?? "") { if isLive, segment == .transcript { proxy.scrollTo("end") } }
        }
        .onAppear {
            title = meeting.title
            if !started {
                started = true
                segment = isLive ? .transcript : .summary
            }
        }
        .onChange(of: meeting.title) { _, new in if !titleFocused { title = new } }
        .onChange(of: isLive) { _, live in if !live { segment = .summary } }
    }

    // MARK: Header and banners

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $title)
                .font(.title2.bold())
                .focused($titleFocused)
                .submitLabel(.done)
                .onSubmit { Task { await meetings.rename(meeting, to: title) } }
                .onChange(of: titleFocused) { _, focused in
                    if !focused, title != meeting.title { Task { await meetings.rename(meeting, to: title) } }
                }
                .accessibilityIdentifier("meeting.title")
            HStack(spacing: 8) {
                Text("\(meeting.date.formatted(date: .abbreviated, time: .shortened)) · \(MeetingListLogic.clock(isLive ? meetings.elapsed : meeting.duration))")
                if let locale = meeting.locale {
                    Text("· \(Locale.current.localizedString(forIdentifier: locale) ?? locale)")
                }
                Spacer(minLength: 0)
            }
            .font(.callout).foregroundStyle(.secondary)
            if !isLive { templateMenu }
        }
    }

    private var templateMenu: some View {
        Menu {
            ForEach(templates) { template in
                Button {
                    Task { await meetings.setTemplate(template.id, for: meeting.id) }
                } label: {
                    if template.id == meeting.templateID { Label(template.name, systemImage: "checkmark") } else { Text(template.name) }
                }
            }
        } label: {
            Label(templates.first { $0.id == meeting.templateID }?.name ?? "Summary", systemImage: "doc.text")
        }
        .buttonStyle(.bordered).controlSize(.small)
        .accessibilityIdentifier("meeting.template")
    }

    @ViewBuilder private var banners: some View {
        if waitingForHeavySteps, !isLive {
            banner(
                symbol: "hourglass",
                text: processRequested || working
                    ? "Improving the transcript, speakers and summary…"
                    : "The summary and the speaker pass run when no meeting records and Legato is open. iOS can also finish them later in the background.",
                action: processRequested || working ? nil : ("Process now", {
                    processRequested = true
                    meetings.processNow(meeting.id)
                }))
        }
        if let notice = meetings.notice {
            banner(symbol: "info.circle", text: notice, action: nil)
        }
        if isLive {
            if meetings.interrupted {
                banner(
                    symbol: "pause.circle", text: "Paused: a call or another app has the microphone. Legato resumes when it is free.",
                    action: nil, tint: .orange)
                    .accessibilityIdentifier("meeting.interrupted")
            }
            if let reason = meetings.engineFallback { banner(symbol: "info.circle", text: reason, action: nil) }
            if let error = meetings.live?.audioError ?? meetings.live?.saveError {
                banner(symbol: "exclamationmark.octagon", text: "Recording problem: \(error)", action: nil, tint: .red)
            }
            if let error = meetings.live?.diarizerError {
                banner(symbol: "person.2.slash", text: "Speaker labels stopped: \(error)", action: nil, tint: .orange)
            }
            if let failure = meetings.live?.engineErrors[.mixed] {
                banner(
                    symbol: "exclamationmark.triangle",
                    text: "The speech engine stopped (\(failure)). The audio is still recorded.", action: nil, tint: .red)
            }
        }
    }

    private func banner(symbol: String, text: String, action: (String, () -> Void)?, tint: Color = .secondary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action { Button(action.0, action: action.1).controlSize(.small).buttonStyle(.bordered) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Segments

    @ViewBuilder private var summarySection: some View {
        if isLive {
            Text("The summary is written after the meeting, from the transcript and your notes.")
                .foregroundStyle(.secondary)
        } else if let summary = shown {
            if summary.isStale {
                banner(
                    symbol: "pencil.and.list.clipboard", text: "Your notes changed after this summary was written.",
                    action: working ? nil : ("Regenerate", { meetings.regenerate(meeting.id) }), tint: .orange)
                    .accessibilityIdentifier("meeting.stale")
            }
            SummaryMarkdownView(text: summary.text)
            HStack {
                Button { meetings.regenerate(meeting.id) } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(working)
                    .accessibilityIdentifier("meeting.regenerate")
                if working { ProgressView().controlSize(.small) }
                Spacer()
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(working ? "Writing the summary…" : "No summary for this template yet.").foregroundStyle(.secondary)
                if !working {
                    Button { meetings.regenerate(meeting.id) } label: { Label("Generate", systemImage: "sparkles") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(waitingForHeavySteps)
                }
            }
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search the transcript", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(action: onSpeakers) { Image(systemName: "person.2") }
                    .disabled(isLive || meeting.speakers.isEmpty)
                    .accessibilityLabel("Assign speakers")
                    .accessibilityIdentifier("meeting.speakers")
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            MeetingTranscriptView(
                segments: segments, speakers: meeting.speakers, query: query,
                partial: isLive ? meetings.live?.volatile[.mixed] ?? "" : "", following: isLive, canSeek: canSeek && !isLive,
                onSeek: onSeek)
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Private notes").font(.title3.bold()).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $notes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 240)
                    .accessibilityIdentifier("meeting.notes")
                if notes.isEmpty {
                    Text(isLive ? "Take notes during the meeting. They are given to the summary." : "Add notes. Changing them offers a new summary.")
                        .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                }
            }
        }
    }
}

/// A summary as the document shows it: headings, bullets, checklist items and paragraphs, with inline
/// Markdown (bold, italics, code, links).
struct SummaryMarkdownView: View {
    let text: String

    private enum Block: Hashable {
        case heading(String), bullet(String), todo(String), paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let t): Text(Self.inline(t)).font(.title3.bold()).padding(.top, 8)
                case .bullet(let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); Text(Self.inline(t)) }
                case .todo(let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Image(systemName: "circle").font(.caption); Text(Self.inline(t)) }
                case .paragraph(let t): Text(Self.inline(t))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [Block] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { return .heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)) }
            for prefix in ["- [ ] ", "- [x] ", "* [ ] "] where line.hasPrefix(prefix) { return .todo(String(line.dropFirst(prefix.count))) }
            for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) { return .bullet(String(line.dropFirst(prefix.count))) }
            return .paragraph(line)
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
