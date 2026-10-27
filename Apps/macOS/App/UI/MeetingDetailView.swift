import LegatoAudio
import LegatoCore
import LegatoMeetings
import SwiftUI

/// One meeting, recording or finished: the document on the left, the continuous transcript on the right
/// (search and Assign speakers above it), the player pill or the recording controls at the bottom.
struct MeetingDetailView: View {
    @Environment(MacAppController.self) private var app
    let meetingID: UUID
    let onBack: () -> Void

    @State private var current: Meeting?
    @State private var segments: [MeetingSegment] = []
    @State private var summaries: [MeetingStore.Summary] = []
    @State private var notes = ""
    @State private var notesLoaded = false
    @State private var showTranscript = true
    @State private var searching = false
    @State private var query = ""
    @State private var assigning = false
    @State private var player: MeetingPlayer?
    @State private var confirmClaude = false
    @State private var confirmEnd = false
    @State private var confirmDiscard = false

    private var meetings: MeetingController { app.meetings }
    private var isLive: Bool { meetings.liveMeetingID == meetingID }
    private var meeting: Meeting? { isLive ? meetings.live?.meeting ?? current : current }
    private var shownSegments: [MeetingSegment] { isLive ? meetings.live?.segments ?? [] : segments }
    private var working: Bool { meetings.busy.contains(meetingID) }

    var body: some View {
        Group {
            if let meeting {
                content(meeting)
            } else {
                ProgressView()
            }
        }
        .toolbar { toolbar }
        .task(id: meetings.revision) { await reload() }
        .onChange(of: notes) { _, text in
            guard notesLoaded else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, text == notes else { return }
                await meetings.saveNotes(text, for: meetingID)
            }
        }
        .onDisappear { player?.pause() }
        .confirmationDialog("End this meeting?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End meeting") { Task { await meetings.stop() } }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("The recording is saved and the summary is prepared.")
        }
        .confirmationDialog("Discard this meeting?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard meeting", role: .destructive) {
                Task {
                    await meetings.discard()
                    onBack()
                }
            }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("The recording, the transcript and your notes are deleted. This cannot be undone.")
        }
        .confirmationDialog("Send this transcript to Claude?", isPresented: $confirmClaude, titleVisibility: .visible) {
            Button("Send to Claude") {
                meetings.claudeDisclosureAccepted = true
                meetings.summarizeWithClaude(meetingID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Summarizing with Claude sends this meeting's transcript and your notes to Anthropic over the internet, using your own API key. Nothing else leaves this Mac, and the on-device summary never does. This note is shown once.")
        }
    }

    // MARK: Layout

    private func content(_ meeting: Meeting) -> some View {
        HStack(spacing: 0) {
            MeetingDocumentView(meeting: meeting, isLive: isLive, summaries: summaries, working: working, notes: $notes)
                .overlay(alignment: .bottom) { bottomBar }
            if showTranscript {
                Divider()
                transcriptPane(meeting)
                    .frame(minWidth: 280, idealWidth: 380, maxWidth: 520)
            }
        }
    }

    @ViewBuilder private var bottomBar: some View {
        if isLive {
            recordingBar
        } else if let player {
            MeetingPlayerBar(player: player).padding(.bottom, 14)
        }
    }

    private func transcriptPane(_ meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            if assigning, !isLive {
                AssignSpeakersView(
                    meetingID: meetingID, speakers: meeting.speakers, segments: shownSegments, player: player,
                    onClose: { assigning = false })
            } else {
                HStack(spacing: 6) {
                    if searching {
                        TextField("Search the transcript", text: $query).textFieldStyle(.roundedBorder)
                    }
                    Spacer(minLength: 0)
                    Button {
                        searching.toggle()
                        if !searching { query = "" }
                    } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).help("Search the transcript")
                    Button { assigning = true } label: { Image(systemName: "person.2") }
                        .buttonStyle(.borderless).help("Assign speakers")
                        .disabled(isLive || meeting.speakers.isEmpty)
                }
                .padding(.horizontal, 16).padding(.top, 10)
                MeetingTranscriptView(
                    segments: shownSegments, speakers: meeting.speakers, query: query,
                    partial: isLive ? meetings.live?.volatile[.mixed] ?? "" : "", following: isLive,
                    onSeek: { time in
                        player?.seek(to: time)
                        player?.play()
                    })
            }
        }
    }

    /// Mute, pause, end, discard and the clock, over the document while recording.
    private var recordingBar: some View {
        let state = meetings.pillState
        return HStack(spacing: 12) {
            Circle().fill(state.paused ? Color.orange : Color.red).frame(width: 9, height: 9)
            Text(MeetingListLogic.clock(meetings.elapsed)).font(.body.monospacedDigit().weight(.medium))
            Text(state.label).font(.caption).foregroundStyle(.secondary)
            Divider().frame(height: 16)
            Button { meetings.toggleManualMute() } label: {
                Label(meetings.isMuted ? "Unmute" : "Mute", systemImage: meetings.isMuted ? "mic.slash.fill" : "mic.fill")
            }
            Button { meetings.togglePause() } label: {
                Label(state.paused ? "Resume" : "Pause", systemImage: state.paused ? "play.fill" : "pause.fill")
            }
            Button { confirmEnd = true } label: { Label("End", systemImage: "stop.fill") }
                .tint(.red)
            Button(role: .destructive) { confirmDiscard = true } label: { Label("Discard", systemImage: "trash") }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.plain)
        .disabled(!state.controlsEnabled)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .padding(.bottom, 14)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: onBack) { Label("Meetings", systemImage: "chevron.left") }
                .help("Back to the list")
        }
        ToolbarItem(placement: .principal) {
            Text(meeting?.title ?? "Meeting").font(.headline).foregroundStyle(.secondary)
        }
        if isLive {
            ToolbarItem {
                Button { meetings.togglePill() } label: { Label("Shrink to pill", systemImage: "rectangle.compress.vertical") }
                    .help("Shrink to a floating pill (⌃⌘M)")
            }
        } else if let meeting {
            ToolbarItem {
                Menu {
                    Button("Export Markdown…") { Task { await meetings.exportMarkdown(meeting) } }
                    Button("Show audio in Finder") { Task { await meetings.showAudio(meeting) } }
                    Divider()
                    Button("Improve transcript") { meetings.improve(meetingID) }
                        .disabled(working)
                    Button("Summarize with Claude") {
                        if meetings.claudeDisclosureAccepted { meetings.summarizeWithClaude(meetingID) } else { confirmClaude = true }
                    }
                    .disabled(working || !meetings.hasClaudeKey)
                    if !meetings.hasClaudeKey { Text("Add a Claude key in Settings > Meetings") }
                } label: { Label("More", systemImage: "ellipsis") }
            }
        }
        ToolbarItem {
            Button { showTranscript.toggle() } label: { Label("Transcript", systemImage: "sidebar.right") }
                .help(showTranscript ? "Hide the transcript" : "Show the transcript")
        }
    }

    // MARK: Data

    private func reload() async {
        current = meetings.meetings.first { $0.id == meetingID }
        if !isLive {
            segments = await meetings.transcript(of: meetingID)
            if assigning, current?.speakers.isEmpty == true { assigning = false }
        }
        summaries = await meetings.summaries(of: meetingID)
        if !notesLoaded || !isLive {
            // Notes are the user's own: reload only when not typing (the first load, and after a finished chain).
            let stored = await meetings.notes(of: meetingID)
            if !notesLoaded { notes = stored }
            notesLoaded = true
        }
        if !isLive { await preparePlayer() }
    }

    private func preparePlayer() async {
        let folder = await meetings.folder(of: meetingID)
        if let player {
            try? player.refresh()
        } else if MeetingPlayer.audioURL(in: folder) != nil {
            let made = MeetingPlayer(folder: folder)
            try? made.load()
            player = made
        }
    }
}
