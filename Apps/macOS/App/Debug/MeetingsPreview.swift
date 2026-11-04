#if LEGATO_INTERNAL
import AppKit
import AVFoundation
import Foundation
import LegatoMeetings

/// `-LegatoMeetingsShots <dir>` (with `-LegatoMeetingsRoot <empty dir>`): fills the store with sample meetings, opens the
/// Meetings window, writes a PNG of it for each state and quits. No session, no network, no key.
@MainActor enum MeetingsPreview {
    static func runIfRequested(_ controller: MeetingController) {
        if UserDefaults.standard.bool(forKey: "LegatoMeetingsLiveSim") {
            // A live meeting that gains a line every 0.7 s, to watch how the transcript scrolls.
            Task {
                let live = await seedLive(controller.services.store)
                await controller.refresh()
                controller.showWindow()
                controller.selection = live.id
                controller.detailTab = .transcript
                var state = live.state
                var n = 0
                while true {
                    n += 1
                    let last = state.segments.last?.end ?? 0
                    state.segments.append(MeetingSegment(text: "Line \(n): the export total differs by a few cents because every line is rounded on its own before the sum.", start: last + 1, end: last + 7, speaker: n % 2 == 0 ? "P1" : "P2"))
                    controller.previewLive(state, elapsed: last + 7)
                    try? await Task.sleep(for: .milliseconds(700))
                }
            }
            return
        }
        if UserDefaults.standard.bool(forKey: "LegatoMeetingsSeed") {
            Task {
                let ids = await seed(controller.services.store)
                await controller.refresh()
                controller.showWindow()
                controller.selection = ids.planning
            }
            return
        }
        guard let path = UserDefaults.standard.string(forKey: "LegatoMeetingsShots") else { return }
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        Task {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if UserDefaults.standard.bool(forKey: "LegatoMeetingsEmpty") {
                try? await Task.sleep(for: .seconds(2))
                controller.showWindow()
                try? await Task.sleep(for: .seconds(4))
                snapshot(window: "Meetings", to: directory.appending(path: "0-empty.png"))
                NSApp.terminate(nil)
                return
            }
            let ids = await seed(controller.services.store)
            await controller.refresh()
            controller.showWindow()
            try? await Task.sleep(for: .seconds(4))
            @MainActor func shot(_ name: String, region: Bool = false) async {
                try? await Task.sleep(for: .milliseconds(2000))
                snapshot(window: "Meetings", region: region, to: directory.appending(path: "\(name).png"))
            }
            controller.selection = ids.planning
            controller.detailTab = .summary
            await shot("1-summary")
            controller.detailTab = .transcript
            await shot("2-transcript-speakers-gap-player")
            controller.editingDetails = true
            await shot("2b-details-popover", region: true)
            controller.editingDetails = false
            controller.sidebar = .project(client: "Acme", project: "Website relaunch")
            await shot("3-folder-filter")
            controller.sidebar = .all
            controller.selection = ids.kickoff
            controller.detailTab = .summary
            await shot("4-summary-failed")
            controller.selection = ids.interview
            await shot("5-interrupted")
            controller.query = "pricing"
            await shot("6-search")
            controller.query = ""
            let live = await seedLive(controller.services.store)
            await controller.refresh()
            controller.previewLive(live.state, elapsed: 754)
            controller.selection = live.id
            controller.detailTab = .transcript
            await shot("7-live-transcript")
            snapshot(window: nil, to: directory.appending(path: "8-island.png"))
            NSApp.terminate(nil)
        }
    }

    // MARK: Snapshots

    /// The window as the screen shows it, through `screencapture -l`.
    private static func snapshot(window title: String?, region: Bool = false, to url: URL) {
        let candidates = NSApp.windows.filter { $0.isVisible }
        let target = title.flatMap { title in candidates.first { $0.title == title } }
            ?? candidates.first { $0.frame.height < 140 && $0.frame.width >= 390 }
        guard let target else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(target.windowNumber), url.path]
        if region, let popover = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) {
            // A popover is a window of its own; the window behind it is the other shot.
            process.arguments = ["-x", "-o", "-l", String(popover.windowNumber), url.path]
        }
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: Sample data

    private static func seg(_ speaker: String, _ start: TimeInterval, _ text: String) -> MeetingSegment {
        MeetingSegment(text: text, start: start, end: start + 6, speaker: speaker)
    }

    private static func people(_ names: [String]) -> [PersonID: SpeakerInfo] {
        Dictionary(uniqueKeysWithValues: names.enumerated().map { ("P\($0.offset + 1)", SpeakerInfo(name: $0.element, colorIndex: $0.offset)) })
    }

    static func seed(_ store: MeetingStore) async -> (planning: UUID, kickoff: UUID, interview: UUID) {
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        let planning = Meeting(
            title: "Q4 planning", client: "Acme", project: "Website relaunch", tags: ["planning", "roadmap"], date: ago(3), duration: 2530,
            gaps: [TranscriptGap(start: 61, end: 92)], speakers: people(["Mara", "Jonas", "Speaker 3"]), state: .finished,
            completedSteps: [.audio, .summary])
        let review = Meeting(
            title: "Design review", client: "Acme", project: "Website relaunch", tags: ["design"], date: ago(27), duration: 1710,
            speakers: people(["Mara", "Speaker 2"]), state: .finished, completedSteps: [.audio, .summary])
        let kickoff = Meeting(
            title: "Mobile kickoff", client: "Acme", project: "Mobile app", tags: ["kickoff"], date: ago(30), duration: 1260,
            speakers: people(["Speaker 1", "Speaker 2"]), state: .finished, completedSteps: [.audio],
            summaryFailure: "Add your Claude API key in Settings to write summaries.")
        let sync = Meeting(
            title: "Weekly sync", client: "Northwind", project: "Billing", tags: ["sync"], date: ago(80), duration: 1980,
            speakers: people(["Speaker 1", "Speaker 2", "Speaker 3"]), state: .finished, completedSteps: [.audio, .summary])
        let interview = Meeting(
            title: "Backend engineer interview", tags: ["hiring"], date: ago(150), duration: 905,
            speakers: people(["Speaker 1", "Speaker 2"]), state: .interrupted)
        let lines: [UUID: [MeetingSegment]] = [
            planning.id: [
                seg("P1", 4, "Let's start with the pricing page, since that blocks everything else in the relaunch."),
                seg("P2", 15, "Agreed. Legal still has to approve the new plan names, so I'd keep the copy in a draft until Thursday."),
                seg("P1", 31, "Fine by me. Jonas, can your team have the new navigation ready by the end of the month?"),
                seg("P3", 45, "We can, if the design tokens land this week. Otherwise we ship it with the old colours and migrate later."),
                seg("P1", 100, "Okay, then the plan is: tokens this week, navigation next, pricing copy after legal."),
                seg("P2", 118, "I'll write the follow-up and send the timeline around tomorrow morning."),
            ],
            review.id: [
                seg("P1", 3, "The new hero works, but the pricing table is too dense on small screens."),
                seg("P2", 19, "We can collapse the comparison rows behind a toggle and keep three plans visible."),
            ],
            kickoff.id: [
                seg("P1", 2, "Welcome everyone. Today we agree on scope for the first release of the app."),
                seg("P2", 17, "Offline mode is the one thing the customer will not compromise on."),
            ],
            sync.id: [seg("P1", 5, "Invoices are still failing for two customers in Germany."), seg("P2", 21, "That is the VAT id check, I have a fix in review.")],
            interview.id: [seg("P1", 6, "Tell me about the last system you built that had to survive a bad deploy.")],
        ]
        let summaryText = """
        ## Summary
        The team agreed to unblock the relaunch in three steps: design tokens this week, the new navigation next, and the **pricing copy** once legal approves the plan names.

        ## Decisions
        - Keep the pricing copy in draft until Thursday.
        - Ship the navigation on the old colours if the design tokens slip.

        ## Action items
        - [ ] Jonas: navigation ready by the end of the month
        - [ ] Mara: send the timeline tomorrow morning
        - [x] Legal: review the new plan names
        """
        let reviewSummary = "## Summary\nThe hero is approved. The pricing table needs a denser mobile layout: collapse the comparison rows and keep three plans visible.\n\n## Action items\n- [ ] Mara: mobile pricing table"
        for meeting in [planning, review, kickoff, sync, interview] {
            try? await store.create(meeting)
            for segment in lines[meeting.id] ?? [] { try? await store.appendSegment(segment, to: meeting.id) }
        }
        try? await store.saveSummary(summaryText, backendID: "claude", for: planning.id)
        try? await store.saveSummary(reviewSummary, backendID: "claude", for: review.id)
        try? await store.saveSummary("## Summary\nInvoices fail for two customers in Germany because of the VAT id check; a fix is in review.", backendID: "claude", for: sync.id)
        for meeting in [planning, review] { writeTone(into: await store.folder(for: meeting.id), seconds: Int(meeting.duration / 60)) }
        return (planning.id, kickoff.id, interview.id)
    }

    static func seedLive(_ store: MeetingStore) async -> (id: UUID, state: MeetingController.Live) {
        let meeting = Meeting(title: "Customer call", client: "Northwind", project: "Billing", tags: ["call"], date: Date().addingTimeInterval(-754), state: .recording)
        try? await store.create(meeting)
        let speakers = people(["Speaker 1", "Mara"])
        let segments = [
            seg("P1", 3, "Thanks for making the time. I'd like to walk through the invoice export first."),
            seg("P2", 17, "Sure. The export works, but the totals do not match what our accounting system shows."),
            seg("P1", 33, "Do you know if the difference is the VAT, or the rounding per line?"),
            seg("P2", 47, "I think it is the rounding, because it grows with the number of lines."),
        ]
        let live = MeetingController.Live(meetingID: meeting.id, segments: segments, volatile: "Let me send you an example from last month so you can", speakers: speakers, gaps: [])
        return (meeting.id, live)
    }

    /// A quiet AAC file of `seconds` (at least 10), so the player has a recording to show.
    private static func writeTone(into folder: URL, seconds: Int) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1]
        guard let file = try? AVAudioFile(forWriting: folder.appending(path: "mix.m4a"), settings: settings) else { return }
        let frames = AVAudioFrameCount(16_000 * 10)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = 0.01 * sinf(Float(i) * 0.05) }
        for _ in 0..<max(1, seconds / 10) { try? file.write(from: buffer) }
    }
}
#endif
