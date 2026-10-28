#if DEBUG
import Foundation
import AVFAudio
import LegatoAudio
import LegatoCore
import Synchronization

/// Explicit opt-in diagnostics. Stores measurements and lifecycle metadata, never audio or transcript text.
final class MacMeetingDiagnostics: Sendable {
    static let shared: MacMeetingDiagnostics? = ProcessInfo.processInfo.arguments.contains("--meeting-debug")
        ? MacMeetingDiagnostics() : nil
    private let queue = DispatchQueue(label: "de.gruenwald.legato.mac.debug.files")
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "de.gruenwald.legato/meeting-debug", directoryHint: .isDirectory)
    private struct Meter {
        var samples = 0
        var squares = 0.0
        var last: TimeInterval?
        var periodStart = ProcessInfo.processInfo.systemUptime
    }
    private let meters = Mutex<[String: Meter]>(["rawMic": Meter(), "sink.mic": Meter(), "sink.system": Meter(), "sink.mixed": Meter()])

    @MainActor private static var probePlayer: AVAudioPlayer?

    private init() {}

    func observe(_ chunk: AudioChunk, stream: String) {
        let squares = chunk.samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let now = ProcessInfo.processInfo.systemUptime
        meters.withLock { values in
            var meter = values[stream] ?? Meter()
            meter.samples += chunk.samples.count
            meter.squares += squares
            meter.last = now
            values[stream] = meter
        }
    }

    func silence(seconds: TimeInterval, stream: String) {
        meters.withLock { values in
            var meter = values[stream] ?? Meter()
            meter.samples += Int(max(0, seconds) * 16_000)
            meter.last = ProcessInfo.processInfo.systemUptime
            values[stream] = meter
        }
    }

    func event(_ event: String, fields: [String: String] = [:]) {
        queue.async { self.write(event, fields: fields, status: false) }
    }

    @MainActor
    func install(meetings: MeetingController) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for command in ["status", "meeting-start", "meeting-stop", "meeting-mute", "meeting-unmute", "probe-speaker"] {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let raw = name?.rawValue as String?, let command = raw.split(separator: ".").last.map(String.init) else { return }
                Task { @MainActor in await MacMeetingDiagnostics.shared?.command(command, meetings: MacAppController.shared.meetings) }
            }, "de.gruenwald.legato.mac.debug.\(command)" as CFString, nil, .deliverImmediately)
        }
        event("debug.enabled")
        Task { @MainActor in
            while !Task.isCancelled {
                snapshot(meetings)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @MainActor
    private func command(_ command: String, meetings: MeetingController) async {
        event("command", fields: ["command": command])
        switch command {
        case "probe-speaker":
            if let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: "/private/tmp/legato-microphone-probe.aiff")) {
                player.currentDevice = "BuiltInSpeakerDevice"
                guard player.currentDevice == "BuiltInSpeakerDevice" else { event("probe.unavailable"); return }
                player.volume = 0.5
                Self.probePlayer = player
                event("probe.started", fields: ["playing": String(player.play())])
            } else { event("probe.unavailable") }
        case "meeting-start": await meetings.start()
        case "meeting-stop": _ = await meetings.stop()
        case "meeting-mute": if !meetings.isMuted { meetings.toggleManualMute() }
        case "meeting-unmute": if meetings.isMuted { meetings.toggleManualMute() }
        default: break
        }
        snapshot(meetings)
    }

    @MainActor
    private func snapshot(_ meetings: MeetingController) {
        var fields = [
            "phase": String(describing: meetings.phase), "muted": String(meetings.isMuted),
            "paused": String(meetings.isPaused), "selectedMicrophoneUID": meetings.settings.inputDeviceUID ?? "auto",
            "engine": meetings.engineName ?? "none", "tap": String(describing: meetings.tapStatus),
            "engineFailed": String(!(meetings.live?.engineErrors.isEmpty ?? true)),
            "audioFailed": String(meetings.live?.audioError != nil),
            "audioError": meetings.live?.audioError ?? "",
            "elapsedSeconds": String(meetings.elapsed),
            "meetingID": meetings.liveMeetingID?.uuidString ?? "none",
            "lastNotice": meetings.notices.all.last?.text ?? "", "pid": String(ProcessInfo.processInfo.processIdentifier)
        ]
        let now = ProcessInfo.processInfo.systemUptime
        meters.withLock { values in
            for (stream, meter) in values {
                fields["\(stream).samplesPerInterval"] = String(meter.samples)
                fields["\(stream).samplesPerSecond"] = String(Double(meter.samples) / max(0.001, now - meter.periodStart))
                fields["\(stream).rms"] = String((meter.squares / Double(max(1, meter.samples))).squareRoot())
                fields["\(stream).lastBufferAgeSeconds"] = meter.last.map { String(max(0, now - $0)) } ?? "never"
                values[stream]?.samples = 0
                values[stream]?.squares = 0
                values[stream]?.periodStart = now
            }
        }
        let snapshotFields = fields
        queue.async { self.write("status", fields: snapshotFields, status: true) }
    }

    /// Serial, off the audio callback. Two 4 MiB logs bound disk usage; the latest status replaces one file.
    private func write(_ event: String, fields: [String: String], status: Bool) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let row: [String: Any] = ["time": Date().timeIntervalSince1970, "event": event, "fields": fields]
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            if status { try data.write(to: directory.appending(path: "status.json"), options: .atomic) }
            let log = directory.appending(path: "events.jsonl")
            let size = (try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size >= 4 * 1024 * 1024 {
                let previous = directory.appending(path: "events.previous.jsonl")
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                try FileManager.default.moveItem(at: log, to: previous)
            }
            if !FileManager.default.fileExists(atPath: log.path) { _ = FileManager.default.createFile(atPath: log.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([10]))
        } catch {
            // Diagnostic failure must never affect recording.
        }
    }
}

/// Counts raw capture before enhancement, while preserving the original microphone's restart stream.
struct DiagnosticMicSource: ResumableAudioSource {
    let source: VoiceProcessingFallbackMic
    let diagnostics: MacMeetingDiagnostics
    var resumptions: AsyncStream<Void> { source.resumptions }
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        tracked(try await source.start(format: format))
    }
    func route() async throws -> AsyncStream<AudioChunk> { tracked(try await source.route()) }
    func detach() async { await source.detach() }
    func stop() async { await source.stop() }
    private func tracked(_ input: AsyncStream<AudioChunk>) -> AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            let pump = Task {
                for await chunk in input {
                    diagnostics.observe(chunk, stream: "rawMic")
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }
}

struct DiagnosticMeetingSink: MeetingAudioSink {
    let sink: any MeetingAudioSink
    let diagnostics: MacMeetingDiagnostics
    func write(_ chunk: AudioChunk, stream: TranscriptEvent.Stream) async throws {
        diagnostics.observe(chunk, stream: "sink.\(stream)")
        try await sink.write(chunk, stream: stream)
    }
    func writeSilence(seconds: TimeInterval, stream: TranscriptEvent.Stream) async throws {
        diagnostics.silence(seconds: seconds, stream: "sink.\(stream)")
        try await sink.writeSilence(seconds: seconds, stream: stream)
    }
    func finish() async throws { try await sink.finish() }
}
#endif
