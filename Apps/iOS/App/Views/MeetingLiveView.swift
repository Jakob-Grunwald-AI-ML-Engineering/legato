import SwiftUI

/// A running meeting: the time, the mute button, Stop, and the transcript as it comes in.
struct MeetingLiveView: View {
    let controller: AppController

    private var meetings: MeetingController { controller.meetings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if meetings.interrupted {
                Label("Paused: a call or another app has the microphone. Legato resumes when it is free.", systemImage: "pause.circle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("meeting.interrupted")
            }
            if let reason = meetings.engineFallback {
                Label(reason, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            if let error = meetings.live?.audioError ?? meetings.live?.saveError {
                Label("Recording problem: \(error)", systemImage: "exclamationmark.octagon")
                    .font(.callout).foregroundStyle(.red)
            }
            if let notice = meetings.notice {
                Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            transcript
            controls
        }
        .padding()
        .navigationTitle("Meeting")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle").foregroundStyle(meetings.isMuted ? Color.secondary : .red)
            Text(Self.clock(meetings.elapsed)).font(.title2.monospacedDigit().bold())
            Spacer()
            if let engine = meetings.engineName {
                Text(engine).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var transcript: some View {
        let segments = (meetings.live?.segments ?? []).filter { !$0.echo }
        let partial = meetings.live?.volatile[.mixed] ?? ""
        let failure = meetings.live?.engineErrors[.mixed]
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(segments) { Text($0.text).textSelection(.enabled) }
                    if !partial.isEmpty { Text(partial).foregroundStyle(.secondary).italic() }
                    if let failure {
                        Text("The speech engine stopped (\(failure)). The audio is still recorded.")
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
        .accessibilityIdentifier("meeting.transcript")
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                meetings.toggleManualMute()
            } label: {
                Label(meetings.manualMute ? "Unmute" : "Mute", systemImage: meetings.isMuted ? "mic.slash.fill" : "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!meetings.isRecording)
            .accessibilityIdentifier("meeting.mute")
            Button(role: .destructive) {
                Task { await meetings.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!meetings.isRecording)
            .accessibilityIdentifier("meeting.stop")
        }
        .controlSize(.large)
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}
