import AppKit
import LegatoAudio
import LegatoMeetings
import SwiftUI

/// One meeting: its title and filing on top, then the summary or the transcript, and the recording to play.
/// The meeting that records shows the live transcript in the same place.
struct MeetingDetailView: View {
    let meeting: Meeting
    @Environment(MeetingController.self) private var controller
    @Environment(\.openSettings) private var openSettings
    @State private var segments: [MeetingSegment] = []
    @State private var summary: String?
    @State private var markdown = ""
    @State private var player: MeetingPlayer?
    @State private var copied: MeetingController.DetailTab?
    @State private var confirmDelete = false

    private struct LoadKey: Hashable { var id: UUID; var revision: Int; var summarizing: Bool }

    private var live: MeetingController.Live? { controller.live?.meetingID == meeting.id ? controller.live : nil }
    private var isLive: Bool { live != nil }
    private var summarizing: Bool { controller.services.summarizing.contains(meeting.id) }
    private var processing: Bool { controller.services.processing.contains(meeting.id) || meeting.state == .processing }

    /// The meeting with what the session knows while it records: the people, the gaps, the length so far.
    private var shown: Meeting {
        guard let live else { return meeting }
        var shown = meeting
        shown.speakers = live.speakers
        shown.gaps = live.gaps
        shown.duration = controller.elapsed
        return shown
    }

    var body: some View {
        @Bindable var bindable = controller
        // The geometry reader gives the column the window's height whatever its content needs, so a long summary or a
        // banner cannot push the window's minimum height up.
        GeometryReader { proxy in
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                MeetingMetadataEditor(meeting: shown, known: controller.meetings) { controller.updateMetadata(meeting.id, $0) }
                statusLine
                banners
                Picker("View", selection: $bindable.detailTab) {
                    ForEach(MeetingController.DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
            Divider()
            Group {
                switch controller.detailTab {
                case .summary: ScrollView { summaryTab.padding(24) }
                case .transcript:
                    MeetingTranscriptView(
                        meeting: shown, segments: live?.segments ?? segments, volatile: live?.volatile ?? "",
                        live: isLive, seek: player.map { player in { player.seek(to: $0); player.play() } },
                        rename: { controller.renameSpeaker(meeting.id, person: $0, to: $1) })
                }
            }
            if let player, !isLive {
                Divider()
                MeetingPlayerBar(player: player)
            }
        }
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .toolbar { toolbar }
        .task(id: LoadKey(id: meeting.id, revision: controller.revision, summarizing: summarizing)) { await load() }
        .onDisappear { player?.pause() }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete meeting", role: .destructive) { controller.delete(meeting.id) }
        } message: {
            Text("The transcript, summary and audio are removed from this Mac.")
        }
    }

    // MARK: Header

    private var statusLine: some View {
        HStack(spacing: 8) {
            if isLive {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Recording").foregroundStyle(.red)
                Text(MeetingListLogic.clock(controller.elapsed)).monospacedDigit()
            } else {
                Text(meeting.date.formatted(date: .complete, time: .shortened))
                if meeting.duration > 0 { Text("·"); Text(MeetingListLogic.clock(meeting.duration)) }
            }
        }
        .font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder private var banners: some View {
        if isLive, let warning = controller.liveWarning {
            Banner(text: warning, symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
        if meeting.state == .interrupted {
            Banner(text: "Legato quit while this meeting recorded. The transcript and the audio up to then were kept.",
                   symbol: "exclamationmark.arrow.triangle.2.circlepath", tint: .orange)
        }
        if processing && !summarizing {
            Banner(text: "Finishing the recording…", symbol: "hourglass", tint: .secondary, spinning: true)
        }
        if !isLive && !shown.gaps.isEmpty {
            Banner(text: shown.gaps.count == 1 ? "The transcript misses one stretch where the connection was down."
                : "The transcript misses \(shown.gaps.count) stretches where the connection was down.",
                symbol: "wifi.slash", tint: .orange)
        }
    }

    // MARK: Summary

    @ViewBuilder private var summaryTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let failure = meeting.summaryFailure, !summarizing {
                VStack(alignment: .leading, spacing: 10) {
                    Banner(text: failure, symbol: "exclamationmark.triangle.fill", tint: .orange)
                    HStack {
                        Button("Try again") { controller.summarize(meeting.id) }
                        Button("Open Settings") { NSApp.activate(); openSettings() }
                    }
                }
            }
            if isLive {
                placeholder("The summary is written when you stop the meeting.", symbol: "text.badge.checkmark")
            } else if summarizing {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Writing the summary…").foregroundStyle(.secondary) }
            } else if let summary {
                MeetingSummaryView(text: summary)
            } else if meeting.summaryFailure == nil && !processing {
                if segments.isEmpty {
                    placeholder("Nothing was transcribed, so there is nothing to summarize.", symbol: "text.page.slash")
                } else {
                    placeholder("This meeting has no summary yet.", symbol: "text.badge.plus")
                    Button("Summarize") { controller.summarize(meeting.id) }.buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).foregroundStyle(.secondary)
    }

    // MARK: Actions

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { copy(.summary) } label: {
                Label(copied == .summary ? "Copied" : "Copy Summary", systemImage: copied == .summary ? "checkmark" : "doc.on.doc")
            }
            .disabled(summary == nil).help("Copy the summary")
            Button { copy(.transcript) } label: {
                Label(copied == .transcript ? "Copied" : "Copy Transcript", systemImage: copied == .transcript ? "checkmark" : "text.quote")
            }
            .help("Copy the transcript")
            ShareLink(item: markdown, subject: Text(meeting.title)) { Label("Share", systemImage: "square.and.arrow.up") }
                .disabled(markdown.isEmpty).help("Share the meeting as Markdown")
            Menu {
                Button("Show in Finder") {
                    Task { NSWorkspace.shared.activateFileViewerSelecting([await controller.services.store.folder(for: meeting.id)]) }
                }
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }.disabled(isLive)
            } label: { Label("More", systemImage: "ellipsis.circle") }
        }
    }

    private func copy(_ kind: MeetingController.DetailTab) {
        Task {
            let services = controller.services
            let text = kind == .summary
                ? try? await services.summaryText(meetingID: meeting.id)
                : try? await services.transcriptMarkdown(meetingID: meeting.id)
            guard let text, !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = kind
            try? await Task.sleep(for: .seconds(1.5))
            copied = nil
        }
    }

    // MARK: Loading

    private func load() async {
        let services = controller.services
        let id = meeting.id
        segments = (try? await services.store.segments(for: id)) ?? []
        summary = (try? await services.summaryText(meetingID: id)) ?? nil
        markdown = (try? await services.markdown(meetingID: id)) ?? ""
        guard !isLive else { return }
        let folder = await services.store.folder(for: id)
        if player == nil {
            guard MeetingPlayer.audioURL(in: folder) != nil else { return }
            let next = MeetingPlayer(folder: folder)
            try? next.load()
            player = next
        } else {
            try? player?.refresh()
        }
    }
}

/// A line of news about a meeting: a symbol and a sentence.
struct Banner: View {
    let text: String
    let symbol: String
    let tint: Color
    var spinning = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if spinning { ProgressView().controlSize(.small) } else { Image(systemName: symbol).foregroundStyle(tint) }
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
