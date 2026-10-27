import FluidAudio
import Foundation
import LegatoCore
import LegatoModels

/// One LocalVQE stream as the enhancer drives it: equal-length mic and reference in, cleaned mic out, a few
/// milliseconds late.
protocol LocalVqeProcessing: Sendable {
    func enhance(mic: [Float], reference: [Float]) async throws -> [Float]
    func flush() async throws -> [Float]
}

/// Pairs mic and reference samples by position and holds back whichever side is ahead. Pure: it never touches a model.
///
/// Both sides are on the meeting mixer's 16 kHz clock, so sample `i` of each is the same instant; whatever
/// arrives in different chunk sizes is lined up here before the model sees it. Samples with no partner yet
/// are the queue; more than ``limit`` of them means one side has stalled.
struct MicReferenceAligner: Sendable {
    /// One second at 16 kHz.
    static let defaultLimit = 16_000

    let limit: Int
    private var mic: [Float] = []
    private var reference: [Float] = []

    init(limit: Int = MicReferenceAligner.defaultLimit) { self.limit = limit }

    /// Appends audio to each side; a nil `reference` is silence as long as `mic`.
    mutating func push(mic: [Float], reference: [Float]?) {
        self.mic += mic
        self.reference += reference ?? [Float](repeating: 0, count: mic.count)
    }

    /// Removes and returns every sample both sides have, in step.
    mutating func takeAligned() -> (mic: [Float], reference: [Float]) {
        let count = min(mic.count, reference.count)
        defer {
            mic.removeFirst(count)
            reference.removeFirst(count)
        }
        return (Array(mic.prefix(count)), Array(reference.prefix(count)))
    }

    /// Ends the audio: the mic still waiting gets silence for its reference, and a reference with no mic is dropped.
    mutating func takeRemaining() -> (mic: [Float], reference: [Float]) {
        let rest = mic
        mic = []
        reference = []
        return (rest, [Float](repeating: 0, count: rest.count))
    }

    /// Samples on the side that is ahead and have no partner yet.
    var unmatched: Int { abs(mic.count - reference.count) }

    /// Samples that have a partner and wait for the model.
    var queuedPairs: Int { min(mic.count, reference.count) }

    var overflowed: Bool { unmatched > limit }

    mutating func reset() {
        mic = []
        reference = []
    }
}

/// Echo cancellation, noise suppression and dereverberation of the meeting mic with LocalVQE (FluidAudio, beta).
///
/// The mic and, on the Mac, the system tap's reference go in on the mixer's 16 kHz clock, sample-aligned; the
/// cleaned mic comes back in order, a hop (16 ms) late. With no reference (iOS) it denoises only.
///
/// It never gets in the meeting's way. If the model fails or cannot load, or more than a second of audio is
/// waiting (for the model or for a stalled reference), it hands the raw mic through from that sample on, with
/// no gap and no repeat, and ``state()`` says why so the app can tell the user.
public actor LocalVqeEnhancer: MicEnhancer {
    private let queueLimit: Int
    private let makeStream: @Sendable () async throws -> any LocalVqeProcessing
    private var stream: (any LocalVqeProcessing)?
    private var aligner: MicReferenceAligner
    /// Mic samples fed and not yet returned, so a fall-back can hand them over raw.
    private var rawPending: [Float] = []
    private var busy = false
    private var lagging = false
    private var fallback: MicEnhancerFallback?

    /// An enhancer over the model installed as `modelID` in `models`. The model loads on the first call.
    public init(models: ModelManager, modelID: String = FluidAudioModels.localVqeID) {
        self.init(queueLimit: MicReferenceAligner.defaultLimit) {
            try await EngineSupport.requireInstalled(models: models, id: modelID)
            let folder = LocalVqeInstaller().installFolder(root: await models.root)
            let manager = try LocalVqeManager(config: FluidAudioModels.localVqeConfig, modelDirectory: folder)
            return LocalVqeStreamProcessor(stream: try await manager.makeStream())
        }
    }

    init(queueLimit: Int, makeStream: @escaping @Sendable () async throws -> any LocalVqeProcessing) {
        self.queueLimit = queueLimit
        self.makeStream = makeStream
        self.aligner = MicReferenceAligner(limit: queueLimit)
    }

    /// Loads the model now (a meeting calls this before the mic starts). A model that cannot load falls back
    /// here, so the raw mic passes from the first sample.
    public func prepare() async {
        guard fallback == nil, stream == nil else { return }
        do { _ = try await ready() } catch { fallBack(.failed("\(error)")) }
    }

    public func state() -> MicEnhancerState {
        fallback.map(MicEnhancerState.fellBack) ?? .active
    }

    public func enhance(mic: [Float], reference: [Float]?) async -> [Float] {
        guard fallback == nil else { return mic }
        rawPending += mic
        aligner.push(mic: mic, reference: reference)
        // A call that arrives while another is in the model means audio is queuing faster than it is cleaned.
        if aligner.overflowed || (busy && aligner.queuedPairs > queueLimit) { lagging = true }
        if busy { return [] }  // the running call picks this audio up

        busy = true
        defer { busy = false }
        var out: [Float] = []
        while fallback == nil {
            if lagging || aligner.overflowed {
                fallBack(.lagging)
                break
            }
            let pair = aligner.takeAligned()
            guard !pair.mic.isEmpty else { break }
            do {
                let stream = try await ready()
                out += emit(try await stream.enhance(mic: pair.mic, reference: pair.reference))
            } catch {
                fallBack(.failed("\(error)"))
            }
        }
        if fallback != nil { out += takeRaw() }
        return out
    }

    public func flush() async -> [Float] {
        guard fallback == nil, let stream else { return takeRaw() }
        var out: [Float] = []
        do {
            let rest = aligner.takeRemaining()
            if !rest.mic.isEmpty { out += emit(try await stream.enhance(mic: rest.mic, reference: rest.reference)) }
            out += emit(try await stream.flush())
        } catch {
            fallBack(.failed("\(error)"))
        }
        // Whatever the model did not return is returned raw: the output always has the input's length.
        return out + takeRaw()
    }

    private func ready() async throws -> any LocalVqeProcessing {
        if let stream { return stream }
        let made = try await makeStream()
        stream = made
        return made
    }

    /// Sample `i` out is the cleaned sample `i` in, so each returned sample retires one raw one.
    private func emit(_ cleaned: [Float]) -> [Float] {
        let count = min(cleaned.count, rawPending.count)
        rawPending.removeFirst(count)
        return count == cleaned.count ? cleaned : Array(cleaned.prefix(count))
    }

    private func takeRaw() -> [Float] {
        defer { rawPending = [] }
        return rawPending
    }

    private func fallBack(_ reason: MicEnhancerFallback) {
        fallback = reason
        aligner.reset()
    }
}

/// A real ``LocalVqeStream`` behind ``LocalVqeProcessing``.
struct LocalVqeStreamProcessor: LocalVqeProcessing {
    let stream: LocalVqeStream

    func enhance(mic: [Float], reference: [Float]) async throws -> [Float] {
        try await stream.enhance(mic: mic, reference: reference)
    }

    func flush() async throws -> [Float] {
        try await stream.flush()
    }
}
