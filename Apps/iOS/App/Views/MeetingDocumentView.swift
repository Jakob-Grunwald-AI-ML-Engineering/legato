import LegatoAppServices
import LegatoMeetings
import SwiftUI

/// The meeting as one scrolling document: the title, then Summary, Transcript and Notes as segments. The summary
/// has its sections as chips, Summarize, then Regenerate and the stale prompt; the private notes feed the summary.
struct MeetingDocumentView: View {
    let controller: AppController
    let meeting: Meeting
    let isLive: Bool
    let segments: [MeetingSegment]
    let summaries: [MeetingStore.Summary]
    @Binding var notes: String
    let canSeek: Bool
    let onSeek: (TimeInterval) -> Void
    let onSpeakers: () -> Void
    let onRename: (PersonID, String) -> Void

    private enum Segment: Hashable { case summary, transcript, notes }

    @State private var segment = Segment.summary
    @State private var title = ""
    @State private var query = ""
    @State private var started = false
    @State private var follow = TranscriptFollow()
    @State private var distanceFromBottom = 0.0
    @FocusState private var titleFocused: Bool

    private var meetings: MeetingController { controller.meetings }
    private var sections: [SummarySection] { meetings.settings.allSections }
    private var ticked: [SectionID] { meetings.tickedSections(of: meeting) }
    private var shown: MeetingStore.Summary? { MeetingListLogic.shownSummary(in: summaries) }
    /// Something runs on this meeting now: a step of the heavy chain, Regenerate, Claude.
    private var working: Bool { meetings.isWorking(meeting.id) }
    /// The summary being written, with its progress; hidden when it is not.
    private var summarizing: MeetingBanner { MeetingBanner.summarizing(stage: meetings.processing[meeting.id]) }
    private var processingBanner: MeetingBanner { meetings.banner(for: meeting) }

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
            // The live transcript follows its newest line until the user scrolls up; "Latest" brings it back.
            .onScrollGeometryChange(for: Double.self) { geometry in
                max(0, geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height)
            } action: { _, distance in
                distanceFromBottom = distance
            }
            .onScrollPhaseChange { _, phase in
                if phase == .idle { follow.scrollSettled(distanceFromBottom: distanceFromBottom) }
            }
            .overlay(alignment: .bottom) {
                if isLive, segment == .transcript, !follow.follows {
                    Button {
                        follow = TranscriptFollow()
                        proxy.scrollTo("end")
                    } label: { Label("Latest", systemImage: "arrow.down") }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .padding(.bottom, 8)
                        .accessibilityIdentifier("meeting.transcript.latest")
                }
            }
            .onChange(of: segments.count) { if isLive, segment == .transcript, follow.follows { proxy.scrollTo("end") } }
            .onChange(of: meetings.live?.volatile[.mixed] ?? "") { if isLive, segment == .transcript, follow.follows { proxy.scrollTo("end") } }
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
                Spacer(minLength: 0)
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
                .accessibilityIdentifier("meeting.waiting")
        case .waitingForRecording:
            banner(symbol: "record.circle", text: state.text, action: nil)
                .accessibilityIdentifier("meeting.waiting")
        case .working:
            HStack(spacing: 10) {
                if let progress = state.progress {
                    ProgressView(value: progress).progressViewStyle(.circular)
                } else {
                    ProgressView()
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
            if let action { Button(action.0, action: action.1).controlSize(.small).buttonStyle(.bordered) }
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                    .accessibilityIdentifier("meeting.notice.dismiss")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Segments

    @ViewBuilder private var summarySection: some View {
        if isLive {
            Text(
                meetings.settings.summarizeAutomatically
                    ? "The summary is written after the meeting, from the transcript and your notes."
                    : "After the meeting, name the speakers, tick the sections you want and tap Summarize. Your notes are used too."
            )
            .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                sectionChips
                if summarizing.kind == .working { summaryProgress }
                if let summary = shown {
                    let stale = MeetingListLogic.staleness(of: summary, ticked: ticked)
                    if let stale {
                        // The one Regenerate of a stale summary is in this banner.
                        banner(
                            symbol: stale == .sections ? "checklist" : "pencil.and.list.clipboard", text: stale.text,
                            action: working || ticked.isEmpty ? nil : ("Regenerate", { meetings.regenerate(meeting.id) }), tint: .orange)
                            .accessibilityIdentifier("meeting.stale")
                    }
                    SummaryMarkdownView(text: summary.text)
                    if stale == nil || working {
                        HStack {
                            Button { meetings.regenerate(meeting.id) } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                                .buttonStyle(.bordered).controlSize(.small)
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
    }

    /// The sections the summary holds, ticked for this meeting; a tap ticks or unticks one.
    private var sectionChips: some View {
        FlowLayout(spacing: 8) {
            ForEach(sections) { section in
                let on = ticked.contains(section.id)
                Button { Task { await meetings.toggleSection(section.id, for: meeting) } } label: {
                    Label(section.heading, systemImage: on ? "checkmark" : "plus")
                        .font(.subheadline)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(on ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.25)))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(working)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityHint(on ? "In the summary. Double-tap to leave it out." : "Not in the summary. Double-tap to add it.")
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
                ProgressView(value: progress).progressViewStyle(.circular)
            } else {
                ProgressView()
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
                Label("Summarize", systemImage: "sparkles").frame(maxWidth: .infinity)
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
        return "Writes the ticked sections on this iPhone, from the transcript, the speakers' names and your notes. Name the speakers first for a better summary."
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
                    .accessibilityHint(
                        isLive ? "Available after the meeting ends. Tap a speaker's name to rename it now."
                            : meeting.speakers.isEmpty ? "No speakers were told apart in this meeting" : "")
                    .accessibilityIdentifier("meeting.speakers")
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            MeetingTranscriptView(
                segments: segments, speakers: meeting.speakers, query: query,
                partial: isLive ? meetings.live?.volatile[.mixed] ?? "" : "", following: isLive, canSeek: canSeek && !isLive,
                onSeek: onSeek, onRename: onRename)
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
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map { row in row.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, row.count - 1)) }.max() ?? 0
        let height = rows.map { $0.map(\.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
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
