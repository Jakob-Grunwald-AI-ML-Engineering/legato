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
    /// The notes as last handed to the store, so a leave or a debounce saves only what changed.
    @State private var notesSaved = ""
    /// The meeting is being discarded: nothing of it is saved any more.
    @State private var discarded = false
    @FocusState private var searchFocused: Bool
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
    private var working: Bool { meetings.isWorking(meetingID) }

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
        // A new task per edit: the last edit saves after 600 ms, and leaving the view cancels it (and flushes below).
        .task(id: notes) {
            guard notesLoaded, !discarded, notes != notesSaved else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, !discarded else { return }
            flushNotes()
        }
        .onDisappear {
            player?.pause()
            flushNotes()
        }
        .confirmationDialog("End this meeting?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End meeting") { Task { await meetings.stop() } }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text(
                meetings.settings.summarizeAutomatically
                    ? "The recording is saved and the summary is prepared."
                    : "The recording is saved. Name the speakers, then summarize it.")
        }
        .confirmationDialog("Discard this meeting?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard meeting", role: .destructive) {
                discarded = true  // a note typed a moment ago must not bring the folder back
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
            MeetingDocumentView(meeting: meeting, isLive: isLive, summaries: summaries, notes: $notes)
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
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
                        TextField("Search the transcript", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .focused($searchFocused)
                            .accessibilityIdentifier("meeting.transcript.search")
                    }
                    Spacer(minLength: 0)
                    Button {
                        searching.toggle()
                        if searching { searchFocused = true } else { query = "" }
                    } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).help("Search the transcript (⌘F)")
                        .keyboardShortcut("f", modifiers: .command)
                        .accessibilityLabel("Search the transcript")
                    Button { assigning = true } label: { Image(systemName: "person.2") }
                        .buttonStyle(.borderless)
                        .help(assignHelp(meeting))
                        .disabled(isLive || meeting.speakers.isEmpty)
                        .accessibilityLabel("Assign speakers")
                        .accessibilityIdentifier("meeting.speakers")
                }
                .padding(.horizontal, 16).padding(.top, 10)
                MeetingTranscriptView(
                    segments: shownSegments, speakers: meeting.speakers, query: query,
                    partial: isLive ? meetings.live?.volatile[.mixed] ?? "" : "", following: isLive,
                    canSeek: player != nil && !isLive,
                    onSeek: { time in
                        player?.seek(to: time)
                        player?.play()
                    },
                    onRename: { person, name in Task { await meetings.renameSpeaker(person, to: name, in: meetingID) } })
            }
        }
    }

    /// Why Assign speakers is off, or what it does.
    private func assignHelp(_ meeting: Meeting) -> String {
        if isLive { return "Available after the meeting ends. Click a speaker's name in the transcript to rename it now." }
        if meeting.speakers.isEmpty { return "No speakers were told apart in this meeting" }
        return "Assign speakers"
    }

    /// Mute, pause, end, discard and the clock, below the document while recording. At a narrow width the buttons
    /// shrink to their icons (the names stay in the tooltips and for VoiceOver).
    private var recordingBar: some View {
        let state = meetings.pillState
        return VStack(spacing: 8) {
            liveCaptureControls
            ViewThatFits(in: .horizontal) {
                recordingControls(state, compact: false)
                recordingControls(state, compact: true)
            }
        }
        .padding(.bottom, 14)
    }

    private var liveCaptureControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    liveMicrophonePicker
                    liveLanguageMenu
                }
                VStack(alignment: .leading, spacing: 6) {
                    liveMicrophonePicker
                    liveLanguageMenu
                }
            }
            Text(meetings.isMuted ? "All microphones muted · meeting audio continues" : "Microphone and meeting audio are always combined")
                .font(.caption).foregroundStyle(.secondary)
            if meetings.inputSelection == .auto, let uid = meetings.activeInputUID,
                let input = meetings.availableInputs.first(where: { $0.uid == uid }) {
                Text("Auto is using \(input.name)").font(.caption).foregroundStyle(.secondary)
            }
            if meetings.liveLanguageCodes != nil {
                Text("Language changes apply to the next sentence.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .disabled(meetings.phase != .recording)
    }

    private var liveMicrophonePicker: some View {
        Picker("Microphone", selection: Binding(
            get: { meetings.inputSelection },
            set: { selection in Task { await meetings.setMicrophoneSelection(selection) } }
        )) {
            Text("Auto — strongest microphone").tag(MeetingMicrophoneSelection.auto)
            Text("All microphones").tag(MeetingMicrophoneSelection.all)
            ForEach(meetings.availableInputs, id: \.uid) { input in
                Text(input.name).tag(MeetingMicrophoneSelection.device(input.uid))
            }
            if case .device(let uid) = meetings.inputSelection,
                !meetings.availableInputs.contains(where: { $0.uid == uid }) {
                Text("Selected microphone disconnected").tag(MeetingMicrophoneSelection.device(uid))
            }
        }
        .accessibilityIdentifier("meeting.microphone")
        .help("Change microphones while recording. Auto uses the strongest input; All combines every available microphone.")
        .frame(maxWidth: 360)
    }

    private var liveLanguageMenu: some View {
        Menu {
            Button { Task { await meetings.setLiveLanguage(nil) } } label: {
                if meetings.liveLanguage == nil { Label("Auto", systemImage: "checkmark") }
                else { Text("Auto") }
            }
            ForEach(meetings.liveLanguageCodes ?? [], id: \.self) { code in
                Button { Task { await meetings.setLiveLanguage(code) } } label: {
                    let name = Locale.current.localizedString(forLanguageCode: code) ?? code
                    if meetings.liveLanguage.flatMap({ Locale(identifier: $0).language.languageCode?.identifier }) == code {
                        Label(name, systemImage: "checkmark")
                    } else { Text(name) }
                }
            }
        } label: {
            Label(meetings.changingLanguage ? "Updating…" : liveLanguageName, systemImage: "globe")
        }
        .disabled(meetings.liveLanguageCodes == nil || meetings.changingLanguage)
        .help(meetings.liveLanguageCodes == nil
            ? "This model cannot change language without restarting. Set the default in Settings for your next meeting."
            : "Language changes apply to the next sentence without reloading the model.")
        .accessibilityIdentifier("meeting.language")
    }

    private var liveLanguageName: String {
        meetings.liveLanguage.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 } ?? "Auto language"
    }

    private func recordingControls(_ state: MeetingPillState, compact: Bool) -> some View {
        HStack(spacing: 12) {
            Circle().fill(state.paused ? Color.orange : Color.red).frame(width: 9, height: 9)
            Text(MeetingListLogic.clock(meetings.elapsed)).font(.body.monospacedDigit().weight(.medium))
            if !compact { Text(state.label).font(.caption).foregroundStyle(.secondary) }
            Divider().frame(height: 16)
            Button { meetings.toggleManualMute() } label: {
                Label(meetings.isMuted ? "Unmute" : "Mute", systemImage: meetings.isMuted ? "mic.slash.fill" : "mic.fill")
            }
            .help(meetings.isMuted ? "Unmute the microphone" : "Mute the microphone")
            .accessibilityIdentifier("meeting.mute")
            Button { meetings.togglePause() } label: {
                Label(state.paused ? "Resume" : "Pause", systemImage: state.paused ? "play.fill" : "pause.fill")
            }
            .help(state.paused ? "Resume the meeting" : "Pause the meeting")
            .accessibilityIdentifier("meeting.pause")
            Button { confirmEnd = true } label: { Label("End", systemImage: "stop.fill") }
                .tint(.red)
                .help("End the meeting")
                .accessibilityIdentifier("meeting.stop")
            Button(role: .destructive) { confirmDiscard = true } label: { Label("Discard", systemImage: "trash") }
                .help("Discard the meeting")
                .accessibilityIdentifier("meeting.discard")
        }
        .labelStyle(CompactLabelStyle(compact: compact))
        .buttonStyle(.plain)
        .disabled(!state.controlsEnabled)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: onBack) { Label("Meetings", systemImage: "chevron.left") }
                .help("Back to the list")
                .accessibilityIdentifier("meeting.back")
        }
        ToolbarItem(placement: .principal) {
            Text(meeting?.title ?? "Meeting").font(.headline).foregroundStyle(.secondary)
        }
        if isLive {
            ToolbarItem {
                Button { meetings.togglePill() } label: { Label("Shrink to pill", systemImage: "rectangle.compress.vertical") }
                    .help("Shrink to a floating pill (⌃⌘M)")
                    .accessibilityIdentifier("meeting.pill")
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
                    .help("More actions")
                    .accessibilityIdentifier("meeting.more")
            }
        }
        ToolbarItem {
            Button { showTranscript.toggle() } label: { Label("Transcript", systemImage: "sidebar.right") }
                .help(showTranscript ? "Hide the transcript" : "Show the transcript")
                .accessibilityIdentifier("meeting.transcript.toggle")
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
            if !notesLoaded {
                notesSaved = stored
                notes = stored
            }
            notesLoaded = true
        }
        if !isLive { await preparePlayer() }
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

/// Title and icon, or the icon alone at a narrow width.
private struct CompactLabelStyle: LabelStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            HStack(spacing: 4) { configuration.icon; configuration.title }
        }
    }
}
