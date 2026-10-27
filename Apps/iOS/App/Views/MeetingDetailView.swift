import LegatoAudio
import LegatoCore
import LegatoMeetings
import SwiftUI

/// One meeting, recording or finished: the document, the speakers sheet, the player bar or the recording
/// controls at the bottom, and the actions on it.
struct MeetingDetailView: View {
    let controller: AppController
    let meetingID: UUID
    let onClose: () -> Void

    @State private var current: Meeting?
    @State private var segments: [MeetingSegment] = []
    @State private var summaries: [MeetingStore.Summary] = []
    @State private var notes = ""
    @State private var notesLoaded = false
    /// The notes as last handed to the store, so a leave or a debounce saves only what changed.
    @State private var notesSaved = ""
    /// The meeting is being discarded: nothing of it is saved any more.
    @State private var discarded = false
    @State private var player: MeetingPlayer?
    @State private var exportItems: [URL] = []
    @State private var showSpeakers = false
    @State private var confirmClaude = false
    @State private var confirmEnd = false
    @State private var confirmDiscard = false

    private var meetings: MeetingController { controller.meetings }
    private var isLive: Bool { meetings.liveMeetingID == meetingID }
    private var meeting: Meeting? { isLive ? meetings.live?.meeting ?? current : current }
    private var shownSegments: [MeetingSegment] { isLive ? meetings.live?.segments ?? [] : segments }
    private var working: Bool { meetings.isWorking(meetingID) }

    var body: some View {
        Group {
            if let meeting {
                MeetingDocumentView(
                    controller: controller, meeting: meeting, isLive: isLive, segments: shownSegments, summaries: summaries,
                    notes: $notes, canSeek: player != nil,
                    onSeek: { time in
                        guard let player else { return }
                        Task {
                            await meetings.preparePlayback()
                            player.seek(to: time)
                            player.play()
                        }
                    },
                    onSpeakers: { showSpeakers = true },
                    onRename: { person, name in Task { await meetings.renameSpeaker(person, to: name, in: meetingID) } })
                    .safeAreaInset(edge: .bottom) { bottomBar }
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if !isLive, meeting != nil { ToolbarItem(placement: .primaryAction) { actions } } }
        .task(id: meetings.revision) { await reload() }
        // A new task per edit: the last edit saves after 600 ms, and leaving the view cancels it (and flushes below).
        .task(id: notes) {
            guard notesLoaded, !discarded, notes != notesSaved else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, !discarded else { return }
            flushNotes()
        }
        .onDisappear {
            player?.pause()
            meetings.endPlayback()
            flushNotes()
        }
        .sheet(isPresented: $showSpeakers) {
            if let meeting {
                SpeakersSheet(
                    controller: meetings, meetingID: meetingID, speakers: meeting.speakers, segments: shownSegments, player: player,
                    onClose: { showSpeakers = false })
                    .presentationDetents([.medium, .large])
            }
        }
        .confirmationDialog("End this meeting?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End meeting") { Task { await meetings.stop() } }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("The recording is saved and the summary is prepared.")
        }
        .confirmationDialog("Discard this meeting?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard meeting", role: .destructive) {
                discarded = true  // a note typed a moment ago must not bring the folder back
                Task {
                    await meetings.discard()
                    onClose()
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
            Text("Summarizing with Claude sends this meeting's transcript and your notes to Anthropic over the internet, using your own API key. Nothing else leaves this iPhone, and the on-device summary never does. This note is shown once.")
        }
    }

    // MARK: Bottom bar

    @ViewBuilder private var bottomBar: some View {
        if isLive {
            recordingBar
        } else if let player {
            MeetingPlayerBar(player: player, beforePlay: { await meetings.preparePlayback() })
                .padding(.bottom, 6)
        }
    }

    /// Mute, pause, end, discard and the clock while recording.
    private var recordingBar: some View {
        let state = meetings.pillState
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(state.paused ? Color.orange : Color.red).frame(width: 9, height: 9)
                Text(MeetingListLogic.clock(meetings.elapsed)).font(.title3.monospacedDigit().weight(.semibold))
                Text(state.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let engine = meetings.engineName { Text(engine).font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 8) {
                Button { meetings.toggleManualMute() } label: {
                    Label(meetings.manualMute ? "Unmute" : "Mute", systemImage: meetings.isMuted ? "mic.slash.fill" : "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("meeting.mute")
                Button { meetings.togglePause() } label: {
                    Label(state.paused ? "Resume" : "Pause", systemImage: state.paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("meeting.pause")
                Button { confirmEnd = true } label: {
                    Label("End", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .tint(.red)
                .accessibilityIdentifier("meeting.stop")
                Button(role: .destructive) { confirmDiscard = true } label: {
                    Image(systemName: "trash").frame(minWidth: 24)
                }
                .accessibilityLabel("Discard")
                .accessibilityIdentifier("meeting.discard")
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            .controlSize(.regular)
            .disabled(!state.controlsEnabled)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 12).padding(.bottom, 4)
    }

    // MARK: Actions

    private var actions: some View {
        Menu {
            if !exportItems.isEmpty {
                ShareLink(items: exportItems) { Label("Export…", systemImage: "square.and.arrow.up") }
            }
            Divider()
            Button("Improve transcript") { meetings.improve(meetingID) }
                .disabled(working)
            Button("Summarize with Claude") {
                if meetings.claudeDisclosureAccepted {
                    meetings.summarizeWithClaude(meetingID)
                } else {
                    confirmClaude = true
                }
            }
            .disabled(working || !meetings.hasClaudeKey)
            if !meetings.hasClaudeKey {
                Text("Add a Claude key in Settings > Meetings")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("meeting.actions")
    }

    // MARK: Data

    private func reload() async {
        current = meetings.meetings.first { $0.id == meetingID }
        if !isLive {
            segments = await meetings.transcript(of: meetingID)
        }
        summaries = await meetings.summaries(of: meetingID)
        if !notesLoaded || !isLive {
            // Notes are the user's own: reload only when not typing (the first load, and after a finished chain).
            let stored = await meetings.notes(of: meetingID)
            if !notesLoaded {
                notesSaved = stored
                notes = stored
            }
            notesLoaded = true
        }
        if !isLive {
            await preparePlayer()
            if let current { exportItems = await meetings.exportItems(for: current) }
        }
    }

    /// Hands changed notes to the store now (the debounce fired, or the view is going away). Never after a discard.
    private func flushNotes() {
        guard notesLoaded, !discarded, notes != notesSaved else { return }
        let text = notes
        notesSaved = text
        Task { await meetings.saveNotes(text, for: meetingID) }
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
