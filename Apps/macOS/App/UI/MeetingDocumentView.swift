import LegatoAppServices
import LegatoMeetings
import SwiftUI

/// The left pane: the title, the template, the summary (with Regenerate and the stale-notes prompt) and the
/// private notes, which feed the summary.
struct MeetingDocumentView: View {
    @Environment(MacAppController.self) private var app
    let meeting: Meeting
    let isLive: Bool
    let summaries: [MeetingStore.Summary]
    @Binding var notes: String

    @State private var title = ""
    @FocusState private var titleFocused: Bool

    private var meetings: MeetingController { app.meetings }
    private var templates: [SummaryTemplate] { meetings.settings.allTemplates }
    private var shown: MeetingStore.Summary? { MeetingListLogic.shownSummary(in: summaries, templateID: meeting.templateID) }
    /// Something runs on this meeting now: a step of the heavy chain, Regenerate, Claude.
    private var working: Bool { meetings.isWorking(meeting.id) }
    /// The summary step itself runs, so "Writing the summary…" is true.
    private var writingSummary: Bool {
        if case .running(let step, _)? = meetings.processing[meeting.id] { return step == .summary }
        return false
    }
    private var processingBanner: MeetingBanner { meetings.banner(for: meeting) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                banners
                if isLive {
                    Text("The summary is written after the meeting, from the transcript and your notes.")
                        .foregroundStyle(.secondary)
                } else {
                    summarySection
                }
                notesSection
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .onAppear { title = meeting.title }
        .onChange(of: meeting.title) { _, new in if !titleFocused { title = new } }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.title.bold())
                .focused($titleFocused)
                .onSubmit { commitTitle() }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { commitTitle() }
                }
                .accessibilityIdentifier("meeting.title")
            HStack(spacing: 8) {
                Text("\(meeting.date.formatted(date: .abbreviated, time: .shortened)) · \(MeetingListLogic.clock(isLive ? meetings.elapsed : meeting.duration))")
                if let locale = meeting.locale {
                    Text("· \(Locale.current.localizedString(forIdentifier: locale) ?? locale)")
                }
                Spacer()
                if !isLive { templateMenu }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// A new title is saved; a blank one is not, and the field goes back to the name the meeting has.
    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            title = meeting.title
        } else if trimmed != meeting.title {
            title = trimmed
            Task { await meetings.rename(meeting, to: trimmed) }
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
        .menuStyle(.button).buttonStyle(.bordered).controlSize(.small).fixedSize()
        .help("The summary template for this meeting")
        .accessibilityIdentifier("meeting.template")
    }

    @ViewBuilder private var banners: some View {
        if !isLive { processingBannerView }
        ForEach(meetings.notices.notices(for: meeting.id)) { notice in
            banner(symbol: "info.circle", text: notice.text, action: nil, dismiss: { meetings.dismissNotice(notice.id) })
        }
        if isLive {
            if let warning = meetings.systemAudioWarning { banner(symbol: "exclamationmark.triangle", text: warning, action: nil, tint: .orange) }
            if let reason = meetings.engineFallback { banner(symbol: "info.circle", text: reason, action: nil) }
            if let error = meetings.live?.audioError ?? meetings.live?.saveError {
                banner(symbol: "exclamationmark.octagon", text: "Recording problem: \(error)", action: nil, tint: .red)
            }
            if let error = meetings.live?.diarizerError {
                banner(symbol: "person.2.slash", text: "Speaker labels stopped: \(error)", action: nil, tint: .orange)
            }
        }
    }

    /// Waiting (with Process now, or the recording that is in the way) or working (the step, with its progress).
    @ViewBuilder private var processingBannerView: some View {
        let state = processingBanner
        switch state.kind {
        case .hidden:
            EmptyView()
        case .waitingForIdle:
            banner(
                symbol: "hourglass", text: state.text,
                action: state.offersProcessNow ? ("Process now", { meetings.processNow(meeting.id) }) : nil)
        case .waitingForRecording:
            banner(symbol: "record.circle", text: state.text, action: nil)
        case .working:
            HStack(spacing: 10) {
                if let progress = state.progress {
                    ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(state.text).font(.callout)
                Spacer(minLength: 8)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("meeting.progress")
        }
    }

    private func banner(
        symbol: String, text: String, action: (String, () -> Void)?, tint: Color = .secondary, dismiss: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action { Button(action.0, action: action.1).controlSize(.small) }
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var summarySection: some View {
        if let summary = shown {
            if summary.isStale {
                // The one Regenerate of a stale summary is in this banner.
                banner(
                    symbol: "pencil.and.list.clipboard", text: "Your notes changed after this summary was written.",
                    action: working ? nil : ("Regenerate", { meetings.regenerate(meeting.id) }), tint: .orange)
            }
            SummaryMarkdownView(text: summary.text)
            if !summary.isStale || working {
                HStack {
                    Button { meetings.regenerate(meeting.id) } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                        .controlSize(.small)
                        .disabled(working)
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(summaryPlaceholder).foregroundStyle(.secondary)
                if !working {
                    Button { meetings.regenerate(meeting.id) } label: { Label("Generate", systemImage: "sparkles") }
                        .controlSize(.small)
                }
            }
        }
    }

    private var summaryPlaceholder: String {
        if writingSummary { return "Writing the summary…" }
        if working { return "The summary is written after the other steps." }
        let waiting = processingBanner.kind == .waitingForIdle || processingBanner.kind == .waitingForRecording
        return waiting ? "The summary is written when processing runs. You can also generate it now." : "No summary for this template yet."
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Private notes").font(.title3.bold()).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $notes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160)
                if notes.isEmpty {
                    Text(isLive ? "Take notes during the meeting. They are given to the summary." : "Add notes. Changing them offers a new summary.")
                        .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                }
            }
        }
    }
}

/// A summary as the document shows it: headings, nested bullets, numbered lists, checklist items and paragraphs,
/// with inline Markdown (bold, italics, code, links).
struct SummaryMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(SummaryMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let t):
                    Text(Self.inline(t)).font(level <= 1 ? .title2.bold() : .title3.bold()).padding(.top, 8)
                case .bullet(let level, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); Text(Self.inline(t)) }
                        .padding(.leading, CGFloat(level) * 18)
                case .todo(let checked, let level, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: checked ? "checkmark.circle.fill" : "circle").font(.caption)
                            .accessibilityLabel(checked ? "Done" : "Open")
                        Text(Self.inline(t)).strikethrough(checked).foregroundStyle(checked ? .secondary : .primary)
                    }
                    .padding(.leading, CGFloat(level) * 18)
                case .numbered(let number, let level, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("\(number).").monospacedDigit(); Text(Self.inline(t)) }
                        .padding(.leading, CGFloat(level) * 18)
                case .paragraph(let t): Text(Self.inline(t))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
