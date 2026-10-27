import LegatoAppServices
import LegatoMeetings
import SwiftUI

/// The left pane: the title, the summary's sections as chips, the summary (Summarize, then Regenerate and the
/// stale prompt) and the private notes, which feed the summary.
struct MeetingDocumentView: View {
    @Environment(MacAppController.self) private var app
    let meeting: Meeting
    let isLive: Bool
    let summaries: [MeetingStore.Summary]
    @Binding var notes: String

    @State private var title = ""
    @FocusState private var titleFocused: Bool

    private var meetings: MeetingController { app.meetings }
    private var sections: [SummarySection] { meetings.settings.allSections }
    private var ticked: [SectionID] { meetings.tickedSections(of: meeting) }
    private var shown: MeetingStore.Summary? { MeetingListLogic.shownSummary(in: summaries) }
    /// Something runs on this meeting now: a step of the heavy chain, Regenerate, Claude.
    private var working: Bool { meetings.isWorking(meeting.id) }
    /// The summary being written, with its progress; hidden when it is not.
    private var summarizing: MeetingBanner { MeetingBanner.summarizing(stage: meetings.processing[meeting.id]) }
    private var processingBanner: MeetingBanner { meetings.banner(for: meeting) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                banners
                if isLive {
                    Text(
                        meetings.settings.summarizeAutomatically
                            ? "The summary is written after the meeting, from the transcript and your notes."
                            : "After the meeting, name the speakers, tick the sections you want and click Summarize. Your notes are used too."
                    )
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
        VStack(alignment: .leading, spacing: 12) {
            sectionChips
            if summarizing.kind == .working { summaryProgress }
            if let summary = shown {
                if let stale = MeetingListLogic.staleness(of: summary, ticked: ticked) {
                    // The one Regenerate of a stale summary is in this banner.
                    banner(
                        symbol: stale == .sections ? "checklist" : "pencil.and.list.clipboard", text: stale.text,
                        action: working || ticked.isEmpty ? nil : ("Regenerate", { meetings.regenerate(meeting.id) }), tint: .orange)
                }
                SummaryMarkdownView(text: summary.text)
                if MeetingListLogic.staleness(of: summary, ticked: ticked) == nil || working {
                    HStack {
                        Button { meetings.regenerate(meeting.id) } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                            .controlSize(.small)
                            .disabled(working || ticked.isEmpty)
                            .accessibilityIdentifier("meeting.regenerate")
                        Spacer()
                    }
                }
            } else if summarizing.kind != .working {
                summarizeButton
            }
        }
    }

    /// The sections the summary holds, ticked for this meeting; a tap ticks or unticks one.
    private var sectionChips: some View {
        FlowLayout(spacing: 6) {
            ForEach(sections) { section in
                let on = ticked.contains(section.id)
                Button { Task { await meetings.toggleSection(section.id, for: meeting) } } label: {
                    Label(section.heading, systemImage: on ? "checkmark" : "plus")
                        .font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(on ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.25)))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(working)
                .accessibilityAddTraits(on ? .isSelected : [])
                .help(on ? "In the summary. Click to leave it out." : "Not in the summary. Click to add it.")
                .accessibilityIdentifier("meeting.section.\(section.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Summary sections")
        .accessibilityIdentifier("meeting.sections")
    }

    private var summaryProgress: some View {
        HStack(spacing: 10) {
            if let progress = summarizing.progress {
                ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(summarizing.text).font(.callout)
            Spacer(minLength: 8)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meeting.summary.progress")
    }

    /// Where the summary goes, before there is one: Summarize, with what it will do.
    private var summarizeButton: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { meetings.regenerate(meeting.id) } label: {
                Label("Summarize", systemImage: "sparkles").padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(working || ticked.isEmpty)
            .accessibilityIdentifier("meeting.summarize")
            Text(summaryHint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var summaryHint: String {
        if ticked.isEmpty { return "Tick at least one section above." }
        if working { return "Summarize is ready once the current step is done." }
        let waiting = processingBanner.kind == .waitingForIdle || processingBanner.kind == .waitingForRecording
        if waiting { return "The transcript and speakers are not final yet. You can summarize now, or after processing." }
        return "Writes the ticked sections on this Mac, from the transcript, the speakers' names and your notes. Name the speakers first for a better summary."
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

/// Lays its children out in rows, left to right, wrapping to a new row when one is full (the section chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        var width: CGFloat = 0
        var height: CGFloat = 0
        for row in rows {
            let gaps = spacing * CGFloat(max(0, row.count - 1))
            let rowWidth: CGFloat = row.reduce(0) { $0 + $1.width } + gaps
            let rowHeight: CGFloat = row.reduce(0) { max($0, $1.height) }
            width = max(width, rowWidth)
            height += rowHeight
        }
        height += spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        var index = 0
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            let height = row.map(\.height).max() ?? 0
            for size in row {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += height + spacing
        }
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [[CGSize]] {
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(size)
            x += size.width + spacing
        }
        return rows
    }
}
