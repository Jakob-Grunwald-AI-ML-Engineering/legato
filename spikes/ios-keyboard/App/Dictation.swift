import AVFAudio
import Foundation
import Speech

/// Converts tap buffers to the analyzer's format. Only touched from the audio tap thread.
final class BufferConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    init?(from: AVAudioFormat, to: AVAudioFormat) {
        guard let c = AVAudioConverter(from: from, to: to) else { return nil }
        converter = c; target = to
    }

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = target.sampleRate / input.format.sampleRate
        let cap = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        nonisolated(unsafe) var consumed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        return status == .error ? nil : out
    }
}

/// On-device transcription with SpeechAnalyzer/SpeechTranscriber, fed from the always-on engine tap.
/// Publishes the full dictation text (finalized + volatile) to the App Group after every result.
@MainActor
final class Dictation {
    static let locale = Locale(identifier: "de_DE")

    private(set) var isRunning = false
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""
    private var router: TapRouter?

    private func log(_ msg: String) { SpikeLog.write("dict", msg) }

    /// Downloads the on-device model once. Call from the foreground app UI.
    func prepareModel() async -> String {
        let t = SpeechTranscriber(locale: Self.locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        do {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                try await req.downloadAndInstall()
            }
            let st = await AssetInventory.status(forModules: [t])
            log("model status: \(st)")
            return "model status: \(st)"
        } catch {
            log("prepareModel failed: \(error)")
            return "prepare failed: \(error)"
        }
    }

    func start(router: TapRouter, inputFormat: AVAudioFormat) async {
        guard !isRunning else { return }
        finalized = ""; volatile = ""
        publish(final: false, state: "listening", force: true)
        let t = SpeechTranscriber(locale: Self.locale, transcriptionOptions: [],
                                  reportingOptions: [.volatileResults], attributeOptions: [])
        do {
            let status = await AssetInventory.status(forModules: [t])
            guard status == .installed else {
                throw NSError(domain: "spike", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "speech model not installed (\(status)); open app and tap 'Prepare speech model'"])
            }
            let a = SpeechAnalyzer(modules: [t])
            guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]),
                  let conv = BufferConverter(from: inputFormat, to: fmt) else {
                throw NSError(domain: "spike", code: 2, userInfo: [NSLocalizedDescriptionKey: "no analyzer format/converter"])
            }
            let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
            router.setSink { buf in
                if let c = conv.convert(buf) { cont.yield(AnalyzerInput(buffer: c)) }
            }
            try await a.start(inputSequence: stream)
            analyzer = a; continuation = cont; self.router = router; isRunning = true
            resultsTask = Task { [weak self] in
                do {
                    for try await r in t.results {
                        let text = String(r.text.characters)
                        guard let self else { return }
                        if r.isFinal {
                            self.finalized += (self.finalized.isEmpty || self.finalized.hasSuffix(" ") ? "" : " ") + text
                            self.volatile = ""
                        } else {
                            self.volatile = (self.finalized.isEmpty || self.finalized.hasSuffix(" ") ? "" : " ") + text
                        }
                        self.publish(final: false, state: "listening")
                    }
                } catch {
                    self?.log("results stream error: \(error)")
                }
            }
            log("dictation started, analyzer format \(fmt.sampleRate) Hz")
        } catch {
            router.setSink(nil)
            publishError("\(error.localizedDescription)")
        }
    }

    func stop() async {
        guard isRunning else { return }
        router?.setSink(nil)
        continuation?.finish()
        publish(final: false, state: "finishing")
        do { try await analyzer?.finalizeAndFinishThroughEndOfInput() } catch { log("finalize error: \(error)") }
        await resultsTask?.value
        finalized += volatile; volatile = ""
        publish(final: true, state: "idle")
        analyzer = nil; continuation = nil; resultsTask = nil; router = nil; isRunning = false
        log("dictation stopped; text=\"\(finalized)\"")
    }

    func publishError(_ msg: String) {
        log("dictation error: \(msg)")
        publish(final: true, state: "error:\(msg)")
    }

    private func publish(final: Bool, state: String, force: Bool = false) {
        let d = Spike.defaults
        d.set(finalized + volatile, forKey: Spike.Key.text)
        d.set(final, forKey: Spike.Key.textFinal)
        d.set(state, forKey: Spike.Key.dictState)
        d.set(d.integer(forKey: Spike.Key.textSeq) + 1, forKey: Spike.Key.textSeq)
        DarwinObserver.post(Spike.Note.text)
    }
}
