import AVFAudio
import LegatoAppServices
import LegatoAudio
import LegatoMeetings
import SwiftUI

struct MeetingsView: View {
    @Bindable var controller: IOSMeetingController
    @State private var settings = false
    var body: some View {
        List {
            Section {
                if controller.fixtureMode {
                    Label("Offline meeting fixture", systemImage: "testtube.2").font(.caption).foregroundStyle(.secondary)
                }
                if controller.isActive {
                    Button { controller.selectedID = controller.services.activeMeetingID } label: {
                        HStack {
                            Label(controller.phase == .recording ? "Meeting recording" : "Preparing meeting…", systemImage: "record.circle.fill").foregroundStyle(.red)
                            Spacer()
                            Text(Duration.seconds(controller.elapsed).formatted(.time(pattern: .minuteSecond))).monospacedDigit()
                        }
                    }
                    Button(role: .destructive) { Task { await controller.stop() } } label: {
                        Label(controller.phase == .starting ? "Cancel start" : "Stop recording", systemImage: "stop.fill")
                    }.disabled(controller.phase == .stopping)
                } else {
                    Button { controller.start() } label: { Label("Record a meeting", systemImage: "mic.badge.plus") }
                        .disabled(!controller.ready)
                        .accessibilityIdentifier("meetings.record")
                }
            } footer: {
                Text("Records the room through your microphone, including while locked. Audio streams to Soniox with your key. Summaries use Claude when enabled. Other apps’ call audio is not captured.")
            }
            if let notice = controller.notice {
                Section { Text(notice).foregroundStyle(.orange); Button("Dismiss") { controller.notice = nil } }
            }
            Section("Recordings") {
                if controller.shown.isEmpty {
                    ContentUnavailableView(controller.query.isEmpty ? "No meetings yet" : "No matching meetings", systemImage: "person.2.wave.2")
                }
                ForEach(controller.shown) { meeting in
                    Button { controller.selectedID = meeting.id } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(meeting.title).font(.headline).foregroundStyle(.primary)
                            HStack {
                                Text(meeting.date, format: .dateTime.month().day().hour().minute())
                                Spacer()
                                Text(meeting.state.rawValue.capitalized)
                                    .foregroundStyle(meeting.state == .interrupted ? .orange : .secondary)
                            }.font(.caption).foregroundStyle(.secondary)
                            if let client = meeting.client { Text([client, meeting.project].compactMap { $0 }.joined(separator: " / ")).font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 3)
                    }
                }
            }
        }
        .navigationTitle("Meetings")
        .searchable(text: $controller.query, prompt: "Title, tags, summary or transcript")
        .onChange(of: controller.query) { controller.search() }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Meeting settings", systemImage: "slider.horizontal.3") { settings = true } } }
        .sheet(isPresented: $settings) { MeetingSettingsSheet(settings: controller.services.settings) }
        .navigationDestination(item: $controller.selectedID) { id in IOSMeetingDetail(controller: controller, id: id) }
        .refreshable { await controller.refresh() }
    }
}

private struct IOSMeetingDetail: View {
    let controller: IOSMeetingController
    let id: UUID
    @State private var meeting: Meeting?
    @State private var segments: [MeetingSegment] = []
    @State private var summary: String?
    @State private var notes = ""
    @State private var markdown = ""
    @State private var selectedTab = 0
    @State private var editor = false
    @State private var copied = false
    @State private var player: MeetingPlayer?
    @State private var error: String?
    private var isLive: Bool { id == controller.services.activeMeetingID }
    private var displayed: [MeetingSegment] { isLive ? controller.live?.segments ?? segments : segments }
    private var speakers: [PersonID: SpeakerInfo] { isLive ? controller.live?.meeting.speakers ?? meeting?.speakers ?? [:] : meeting?.speakers ?? [:] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let meeting {
                    Text(meeting.title).font(.title2.bold())
                    Text(meeting.date, format: .dateTime.month().day().year().hour().minute()).font(.subheadline).foregroundStyle(.secondary)
                    if isLive { liveHeader }
                    else {
                        Label(meeting.state == .interrupted ? "Recording interrupted — captured audio and text are kept" : meeting.state.rawValue.capitalized,
                              systemImage: meeting.state == .interrupted ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.callout).foregroundStyle(meeting.state == .interrupted ? .orange : .secondary)
                        if controller.services.processing.contains(id) { ProgressView("Processing recording…") }
                        if let player { playerView(player) }
                    }
                    if let error { Text(error).foregroundStyle(.orange).font(.callout) }
                    Picker("Meeting content", selection: $selectedTab) { Text("Summary").tag(0); Text("Transcript").tag(1) }.pickerStyle(.segmented)
                    if selectedTab == 0 { summaryView(meeting) } else { transcriptView }
                    if !notes.isEmpty { Divider(); Text("Notes").font(.headline); Text(notes).textSelection(.enabled) }
                    if !isLive {
                        HStack {
                            Button { UIPasteboard.general.string = markdown; copied = true } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                            ShareLink(item: markdown) { Label("Share", systemImage: "square.and.arrow.up") }
                        }.buttonStyle(.bordered).disabled(markdown.isEmpty)
                    }
                } else { ProgressView("Loading meeting…") }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
        .navigationTitle("Meeting").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit details", systemImage: "pencil") { editor = true }.disabled(meeting == nil) } }
        .sheet(isPresented: $editor) {
            if let meeting { MeetingEditor(controller: controller, meeting: meeting, initialNotes: notes) }
        }
        .task(id: controller.revision) { await reload() }
        .task { if isLive { selectedTab = 1 } }
        .onChange(of: editor) { _, shown in if !shown { Task { await reload() } } }
        .onDisappear { player?.pause() }
    }
    private var liveHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Recording", systemImage: "record.circle.fill").foregroundStyle(.red)
                Spacer()
                Text(Duration.seconds(controller.elapsed).formatted(.time(pattern: .minuteSecond))).monospacedDigit()
                Button("Stop", role: .destructive) { Task { await controller.stop() } }.buttonStyle(.bordered)
            }
            if let warning = controller.warning { Text(warning).foregroundStyle(.orange).font(.callout) }
        }
    }
    @ViewBuilder private func summaryView(_ meeting: Meeting) -> some View {
        if let summary {
            IOSMeetingSummary(text: summary)
        } else {
            Text(isLive ? "The summary is available after you stop recording." : "No summary yet. You can generate one with your Claude key.").foregroundStyle(.secondary)
        }
        if let failure = meeting.summaryFailure { Text(failure).foregroundStyle(.orange).font(.callout) }
        if !isLive {
            if controller.services.summarizing.contains(id) { ProgressView("Writing summary…") }
            else { Button(summary == nil ? "Summarize with Claude" : "Regenerate with Claude") { Task { await controller.summarize(id) } }.buttonStyle(.bordered) }
        }
    }
    private var transcriptView: some View {
        VStack(alignment: .leading, spacing: 15) {
            if displayed.isEmpty { Text(isLive ? "Listening for speech…" : "No transcript was captured.").foregroundStyle(.secondary) }
            ForEach(displayed) { segment in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if let person = segment.speaker { Text(speakers[person]?.name ?? person).fontWeight(.semibold) }
                        Text(Duration.seconds(segment.start).formatted(.time(pattern: .minuteSecond))).monospacedDigit()
                    }.font(.caption).foregroundStyle(.secondary)
                    Text(segment.text).textSelection(.enabled)
                }
            }
            if isLive, !controller.liveText.isEmpty { Text(controller.liveText).foregroundStyle(.secondary) }
            if let meeting, !meeting.gaps.isEmpty {
                Text("The transcript has \(meeting.gaps.count) connection gap(s). Recorded audio is preserved.").font(.caption).foregroundStyle(.orange)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func playerView(_ player: MeetingPlayer) -> some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    guard !controller.isActive else { return }
                    if !player.isPlaying {
                        try? AVAudioSession.sharedInstance().setCategory(.playback)
                        try? AVAudioSession.sharedInstance().setActive(true)
                    }
                    player.toggle()
                } label: { Label(player.isPlaying ? "Pause" : "Play recording", systemImage: player.isPlaying ? "pause.fill" : "play.fill") }
                    .disabled(controller.isActive)
                Spacer()
                Text(Duration.seconds(player.currentTime).formatted(.time(pattern: .minuteSecond))).monospacedDigit()
            }
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }), in: 0...max(1, player.duration)).accessibilityLabel("Recording position")
        }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
            .task {
                while !Task.isCancelled {
                    player.sync()
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
    }
    private func reload() async {
        do {
            meeting = try await controller.services.store.meeting(id: id)
            segments = try await controller.services.store.segments(for: id)
            summary = try await controller.services.summaryText(meetingID: id)
            notes = try await controller.services.store.notes(for: id) ?? ""
            markdown = try await controller.services.markdown(meetingID: id)
            if !isLive {
                if let player { try? player.refresh() }
                else {
                    let next = MeetingPlayer(folder: await controller.services.store.folder(for: id))
                    do { try next.load(); player = next }
                    catch { player = nil }
                }
            }
            copied = false
        } catch { self.error = "Could not load meeting: \(error.localizedDescription)" }
    }
}

private struct MeetingEditor: View {
    let controller: IOSMeetingController
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var client: String
    @State private var project: String
    @State private var tags: String
    @State private var notes: String
    @State private var names: [PersonID: String]
    @State private var sections: Set<SectionID>
    @State private var saving = false
    @State private var error: String?
    init(controller: IOSMeetingController, meeting: Meeting, initialNotes: String) {
        self.controller = controller; self.meeting = meeting
        _title = State(initialValue: meeting.title); _client = State(initialValue: meeting.client ?? "")
        _project = State(initialValue: meeting.project ?? ""); _tags = State(initialValue: meeting.tags.joined(separator: ", "))
        _notes = State(initialValue: initialNotes); _names = State(initialValue: meeting.speakers.mapValues(\.name))
        _sections = State(initialValue: Set(controller.services.settings.sections(for: meeting).map(\.id)))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Title", text: $title)
                    TextField("Client", text: $client)
                    TextField("Project", text: $project)
                    TextField("Tags, separated by commas", text: $tags)
                }
                if !names.isEmpty {
                    Section("Speakers") {
                        ForEach(names.keys.sorted(), id: \.self) { id in
                            TextField(meeting.speakers[id]?.name ?? id, text: Binding(get: { names[id] ?? "" }, set: { names[id] = $0 }))
                        }
                    }
                }
                Section("Notes for the summary") { TextEditor(text: $notes).frame(minHeight: 120).accessibilityLabel("Meeting notes") }
                Section("Summary sections") {
                    ForEach(controller.services.settings.allSections, id: \.id) { section in
                        Toggle(section.heading, isOn: Binding(get: { sections.contains(section.id) }, set: { value in
                            if value { sections.insert(section.id) } else { sections.remove(section.id) }
                        }))
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Meeting details").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(saving) }
            }
        }
    }
    private func save() async {
        saving = true
        do {
            _ = try await controller.services.updateMetadata(meetingID: meeting.id,
                MeetingMetadata(title: title, client: client, project: project, tags: tags.components(separatedBy: ",")))
            try await controller.services.store.saveNotes(notes, for: meeting.id)
            let picks = controller.services.settings.allSections.map(\.id).filter(sections.contains)
            _ = try await controller.services.store.update(id: meeting.id) { $0.sections = picks }
            for (id, name) in names where meeting.speakers[id]?.name != name {
                try await controller.services.renameSpeaker(meetingID: meeting.id, person: id, to: name)
            }
            await controller.refresh(); dismiss()
        } catch { self.error = "Could not save changes: \(error.localizedDescription)" }
        saving = false
    }
}

private struct MeetingSettingsSheet: View {
    let settings: MeetingSettings
    @Environment(\.dismiss) private var dismiss
    @State private var automatic: Bool
    @State private var sections: Set<SectionID>
    init(settings: MeetingSettings) {
        self.settings = settings
        _automatic = State(initialValue: settings.summarizeAutomatically)
        _sections = State(initialValue: Set(settings.defaultSectionIDs))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Summarize automatically", isOn: $automatic).onChange(of: automatic) { settings.summarizeAutomatically = automatic }
                } footer: { Text("After recording stops, the transcript is sent to Claude with your API key. Off leaves summaries to the Summarize button. Audio is streamed to Soniox while recording. Provider charges apply.") }
                Section("Default summary sections") {
                    ForEach(settings.allSections, id: \.id) { section in
                        Toggle(section.heading, isOn: Binding(get: { sections.contains(section.id) }, set: { value in
                            if value { sections.insert(section.id) } else { sections.remove(section.id) }
                            settings.defaultSectionIDs = settings.allSections.map(\.id).filter(sections.contains)
                        }))
                    }
                }
            }.navigationTitle("Meeting settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// A summary as the document shows it: headings, bullets, checklists and paragraphs, with inline Markdown.
private struct IOSMeetingSummary: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(SummaryMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in view(block) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(_ block: SummaryMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let title):
            inline(title).font(level <= 1 ? .title2.weight(.bold) : .headline).padding(.top, level <= 2 ? 10 : 4)
        case .bullet(let level, let item):
            row("•", item, level: level)
        case .todo(let checked, let level, let item):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                inline(item).strikethrough(checked)
            }
            .padding(.leading, CGFloat(level) * 18)
        case .numbered(let number, let level, let item):
            row("\(number).", item, level: level)
        case .paragraph(let line):
            inline(line)
        }
    }

    private func row(_ marker: String, _ text: String, level: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
            inline(text)
        }
        .padding(.leading, CGFloat(level) * 18)
    }

    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
}
