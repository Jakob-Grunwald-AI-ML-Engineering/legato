import LegatoCore
import LegatoMeetings
import SwiftUI

/// A running meeting: Me and Them side by side, the mute state, the engine and any warning.
struct MeetingLiveView: View {
    @Environment(MacAppController.self) private var app

    private var meetings: MeetingController { app.meetings }

    var body: some View {
        if meetings.phase == .starting {
            startingView
        } else {
            liveBody
        }
    }

    /// While the speech model loads (minutes the first time), with a way out.
    private var startingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Starting meeting…").font(.headline)
            Text("Loading the speech model — the first time can take a few minutes.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Cancel") { meetings.cancelStart() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private var liveBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let notice = meetings.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = meetings.systemAudioWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reason = meetings.engineFallback {
                Label(reason, systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = meetings.live?.audioError ?? meetings.live?.saveError {
                Label("Recording problem: \(error)", systemImage: "exclamationmark.octagon")
                    .font(.callout).foregroundStyle(.red)
            }
            HStack(alignment: .top, spacing: 12) {
                column("Me", stream: .mic)
                column("Them", stream: .system)
            }
        }
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle").foregroundStyle(.red)
            Text(Self.clock(meetings.elapsed)).font(.headline.monospacedDigit())
            if let engine = meetings.engineName {
                Text(engine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if meetings.autoMute {
                Text("Auto-muted: the call app closed its mic").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                meetings.toggleManualMute()
            } label: {
                Label(meetings.isMuted ? "Unmute me" : "Mute me",
                      systemImage: meetings.isMuted ? "mic.slash.fill" : "mic.fill")
            }
            Button("Stop") { Task { await meetings.stop() } }
                .keyboardShortcut(.return)
        }
    }

    private func column(_ title: String, stream: TranscriptEvent.Stream) -> some View {
        let segments = (meetings.live?.segments ?? []).filter { $0.stream == stream && !$0.echo }
        let partial = meetings.live?.volatile[stream] ?? ""
        let muted = stream == .mic && meetings.isMuted
        let failure = meetings.live?.engineErrors[stream]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                if muted { Image(systemName: "mic.slash.fill").foregroundStyle(.secondary) }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(segments) { Text($0.text).textSelection(.enabled) }
                        if !partial.isEmpty {
                            Text(partial).foregroundStyle(.secondary).italic()
                        }
                        if let failure {
                            Text("This stream's engine stopped (\(failure)). Its audio is still recorded.")
                                .font(.caption).foregroundStyle(.red)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: segments.count) { proxy.scrollTo("end") }
                .onChange(of: partial) { proxy.scrollTo("end") }
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
