import AVFoundation
import FluidAudio
import Foundation
import Observation
import os

struct StreamReport: Codable, Sendable {
    var stats: StreamStats
    var text: String
    var partialUpdates: Int
    var firstTextS: Double?
    var chunkCount: Int
    var procMsMean: Double
    var procMsMax: Double
    var lagMsMean: Double
    var lagMsMax: Double
}

struct SelfTestReport: Codable, Sendable {
    var date: String
    var macOS: String
    var fluidAudio = "0.17.7"
    var model = "Nemotron multilingual 0.6B, latin/1120ms"
    var language: String
    var requestedSeconds: Double
    var micPermission: String
    var tapError: String?
    var tapExcludedOwnProcess: Bool
    var modelLoadSeconds: Double
    var me: StreamReport
    var them: StreamReport
    var notes: [String]
}

/// Collects 16 kHz samples (selftest only) so the run can be replayed offline.
final class SampleSink: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [Float]())
    func append(_ s: [Float]) { lock.withLock { $0.append(contentsOf: s) } }
    var all: [Float] { lock.withLock { $0 } }
}

@MainActor @Observable
final class Session {
    var meFinals: [String] = []
    var mePartial = ""
    var themFinals: [String] = []
    var themPartial = ""
    var status = "idle"
    var running = false
    var language = "auto"  // "auto", "de-DE", "en-US"
    var latencyLine = ""

    let chunkMs = 1120

    private var shared: SharedNemotronMultilingualModels?
    private(set) var modelLoadSeconds = 0.0
    private var mic = MicCapture()
    private var tap = SystemAudioTap()
    private var me: StreamTranscriber?
    private var them: StreamTranscriber?
    private var feedTasks: [Task<Void, Never>] = []
    private var continuations: [AsyncStream<[Float]>.Continuation] = []
    private(set) var tapError: String?
    private(set) var micPermission = "unknown"
    let meSink = SampleSink()
    let themSink = SampleSink()
    var recordSamples = false

    private func loadModelsIfNeeded() async throws {
        guard shared == nil else { return }
        status = "downloading / loading Nemotron multilingual (latin, \(chunkMs) ms)..."
        let t0 = Date()
        // "en-US" routes to the `latin` ship (en/de/es/fr/it/pt); `setLanguage("auto")` still lets the model pick per utterance.
        shared = try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
            languageCode: "en-US", chunkMs: chunkMs)
        modelLoadSeconds = Date().timeIntervalSince(t0)
    }

    func start() async {
        guard !running else { return }
        meFinals = []; themFinals = []; mePartial = ""; themPartial = ""; tapError = nil
        mic = MicCapture(); tap = SystemAudioTap()
        do {
            try await loadModelsIfNeeded()
            guard let shared else { return }

            status = "requesting microphone permission..."
            let granted = await Self.micAccessWithTimeout(seconds: 60)
            micPermission = Self.describe(AVCaptureDevice.authorizationStatus(for: .audio))
            if !granted { status = "microphone not granted (\(micPermission)); continuing with system audio only" }

            let sink: @Sendable (TranscriptEvent) -> Void = { [weak self] event in
                Task { @MainActor in self?.apply(event) }
            }
            let me = StreamTranscriber(name: "me", chunkMs: chunkMs, onEvent: sink)
            let them = StreamTranscriber(name: "them", chunkMs: chunkMs, onEvent: sink)
            try await me.load(shared: shared, language: language)
            try await them.load(shared: shared, language: language)
            self.me = me; self.them = them

            let (meStream, meCont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
            let (themStream, themCont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
            continuations = [meCont, themCont]
            feedTasks = [
                Task.detached { for await s in meStream { await me.feed(s) } },
                Task.detached { for await s in themStream { await them.feed(s) } },
            ]

            let record = recordSamples
            let meSink = meSink, themSink = themSink
            // Mic first: it registers our process with Core Audio, so the tap can exclude it.
            if granted {
                try mic.start { s in
                    if record { meSink.append(s) }
                    meCont.yield(s)
                }
            }
            do {
                try tap.start { s in
                    if record { themSink.append(s) }
                    themCont.yield(s)
                }
            } catch {
                tapError = "\(error)"
            }
            running = true
            status = "listening" + (tapError.map { " (system audio FAILED: \($0))" } ?? "")
        } catch {
            status = "start failed: \(error)"
        }
    }

    func stop() async {
        guard running else { return }
        mic.stop()
        tap.stop()
        continuations.forEach { $0.finish() }
        for t in feedTasks { await t.value }
        feedTasks = []
        await me?.commitSegment()
        await them?.commitSegment()
        running = false
        status = "stopped"
    }

    private func apply(_ event: TranscriptEvent) {
        switch event {
        case .partial("me", let t): mePartial = t
        case .partial(_, let t): themPartial = t
        case .final("me", let t): meFinals.append(t)
        case .final(_, let t): themFinals.append(t)
        }
    }

    // MARK: Self-test

    func runSelfTest(seconds: Double, outURL: URL) async -> Never {
        recordSamples = true
        var notes: [String] = []
        await start()
        guard running || tapError != nil, me != nil else {
            let msg = "selftest aborted: \(status)"
            try? msg.write(to: outURL.deletingLastPathComponent().appendingPathComponent("selftest.log"), atomically: true, encoding: .utf8)
            exit(2)
        }
        NSLog("[selftest] capturing for \(seconds) s")
        try? await Task.sleep(for: .seconds(seconds))
        await stop()

        let meStats = mic.stats.snapshot
        let themStats = tap.stats.snapshot
        if themStats.buffers == 0 { notes.append("them: no buffers delivered by the tap (tapError: \(tapError ?? "none"))") }
        else if themStats.zeroBuffers == themStats.buffers {
            notes.append("them: ALL \(themStats.buffers) tap buffers were all-zero. Most likely the system-audio-recording TCC permission is pending or denied (macOS shows the prompt on first AudioDeviceStart), or nothing was playing.")
        }
        if meStats.buffers == 0 { notes.append("me: no mic buffers (permission \(micPermission))") }
        else if meStats.zeroBuffers == meStats.buffers { notes.append("me: ALL mic buffers all-zero (permission pending/denied or muted)") }

        let report = SelfTestReport(
            date: ISO8601DateFormatter().string(from: Date()),
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            language: language,
            requestedSeconds: seconds,
            micPermission: micPermission,
            tapError: tapError,
            tapExcludedOwnProcess: tap.excludedOwnProcess,
            modelLoadSeconds: modelLoadSeconds,
            me: await Self.report(me, stats: meStats),
            them: await Self.report(them, stats: themStats),
            notes: notes)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(report).write(to: outURL)
            let dir = outURL.deletingLastPathComponent()
            Self.writeWav(meSink.all, to: dir.appendingPathComponent("selftest-me.wav"))
            Self.writeWav(themSink.all, to: dir.appendingPathComponent("selftest-them.wav"))
            NSLog("[selftest] wrote \(outURL.path)")
            exit(0)
        } catch {
            NSLog("[selftest] write failed: \(error)")
            exit(3)
        }
    }

    private static func report(_ t: StreamTranscriber?, stats: StreamStats) async -> StreamReport {
        guard let t else {
            return StreamReport(stats: stats, text: "", partialUpdates: 0, firstTextS: nil, chunkCount: 0,
                                procMsMean: 0, procMsMax: 0, lagMsMean: 0, lagMsMax: 0)
        }
        let lat = await t.latencies
        func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        let proc = lat.map(\.procMs), lag = lat.map(\.lagMs)
        return StreamReport(
            stats: stats, text: await t.fullText, partialUpdates: await t.partialUpdates,
            firstTextS: await t.firstTextS, chunkCount: lat.count,
            procMsMean: mean(proc), procMsMax: proc.max() ?? 0, lagMsMean: mean(lag), lagMsMax: lag.max() ?? 0)
    }

    private static func writeWav(_ samples: [Float], to url: URL) {
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: Resampler16k.target, frameCapacity: AVAudioFrameCount(samples.count)),
              let file = try? AVAudioFile(forWriting: url, settings: Resampler16k.target.settings)
        else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try? file.write(from: buf)
    }

    private static func describe(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined (prompt pending)"
        @unknown default: "unknown"
        }
    }

    /// Mic prompt can't be clicked in a headless run; don't hang forever on it.
    private static func micAccessWithTimeout(seconds: Double) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await MicCapture.requestAccess() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
