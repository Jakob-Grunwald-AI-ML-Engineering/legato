import Foundation
import LegatoMeetings
import LegatoVoiceIdentity

/// Who speaks when in a recorded meeting, from its mix: pyannote segmentation on overlapping 10 s windows finds up to
/// three local speakers per window (overlap and short interjections included), a CAM++ embedding of each local speaker's
/// solo speech says whose voice it is, and agglomerative clustering joins them into the meeting's voices.
///
/// Local speakers with too little solo speech for a reliable embedding join the nearest voice that is not already
/// another local speaker of their window; those too short to embed at all (a quick "yes") join the voice that speaks
/// most around them, again never one of their window's other speakers. Embeddings live only in this run's memory.
struct MeetingDiarizer {
    struct Options: Sendable {
        /// Hop between windows, seconds; every moment is seen by two windows.
        var windowStep: TimeInterval = 5
        /// Solo speech a local speaker needs for an embedding that may form a voice, seconds. An estimate.
        var reliableSeconds: TimeInterval = 1.5
        /// Speech a local speaker needs to be embedded at all, seconds (CAM++ needs 0.35 s). An estimate.
        var weakSeconds: TimeInterval = 0.4
        /// The most audio embedded per local speaker, seconds: bounds the run time.
        var embeddingSeconds: TimeInterval = 3
        var threshold: Float = SpeakerClustering.defaultThreshold
        /// A voice with less solo speech than this joins the nearest larger voice, seconds. An estimate.
        var minimumVoiceSeconds: TimeInterval = 8
        /// A voice with less solo speech than this joins the nearest larger voice when their similarity reaches
        /// ``minorVoiceSimilarity``: fragments of one voice, not a quiet participant. Estimates.
        var minorVoiceSeconds: TimeInterval = 60
        var minorVoiceSimilarity: Float = 0.3
        /// An embedding from little speech joins a voice only this similar; else it is placed like a too-short one. An estimate.
        var weakSimilarity: Float = 0.3
        /// Around a too-short local speaker, how far the voices' speech is weighed, seconds.
        var neighbourhood: TimeInterval = 15
        /// The most embeddings clustered together (the rest join the nearest voice): bounds memory and time.
        var maxClustered = 3_000
    }

    struct Output: Sendable {
        var timeline: SpeakerTimeline
        /// Per voice, the stretches (meeting seconds) where it alone speaks, longest first.
        var soloSpeech: [[Range<TimeInterval>]]
        /// Cosine similarity between the voices' centroids, `[voice][voice]`.
        var voiceSimilarity: [[Float]] = []
        var audioSeconds: TimeInterval
        var windows = 0
        /// Local speakers embedded reliably, embedded from little speech, placed by their surroundings, left out.
        var reliable = 0, weak = 0, guessed = 0, unplaced = 0
        /// Time spent in the segmentation model and in the embeddings.
        var segmentationTime: Duration = .zero, embeddingTime: Duration = .zero
    }

    private enum Kind { case reliable, weak, tiny }

    private struct Local {
        var window: Int
        var speaker: Int
        var kind: Kind
        var embedding: [Float]?
        var solo: [Range<TimeInterval>]
        var soloSeconds: TimeInterval
        var label: Int?
    }

    let segmentation: SpeakerSegmentationModel
    let voice: VoiceIdentityService
    var options = Options()

    private static let rate = SpeakerSegmentationModel.sampleRate
    private static let hop = 270
    /// The 270 samples around the centre of frame `f` (its receptive field is 991 samples): `hop * f + offset`.
    private static let chunkOffset = 360

    func run(mix url: URL) async throws -> Output {
        let reader = try MeetingTrackReader(url: url)
        let total = Int(reader.duration * Self.rate)
        let windowSamples = SpeakerSegmentationModel.windowSamples
        let step = max(1, Int(options.windowStep * Self.rate))
        let lastStart = max(0, total - windowSamples)

        var buffer: [Float] = []
        var bufferStart = 0
        var ended = false
        var starts: [Int] = []
        var windowClasses: [[UInt8]] = []
        var locals: [Local] = []
        var windowStart = 0
        var segmentationTime: Duration = .zero, embeddingTime: Duration = .zero
        let clock = ContinuousClock()
        while true {
            try Task.checkCancellation()
            while buffer.count < windowStart - bufferStart + windowSamples, !ended {
                let block = try reader.next()
                if block.isEmpty { ended = true } else { buffer.append(contentsOf: block) }
            }
            let offset = windowStart - bufferStart
            let window = offset < buffer.count ? Array(buffer[offset..<min(buffer.count, offset + windowSamples)]) : []
            let segmented = clock.now
            let classes = try await segmentation.classes(of: window)
            segmentationTime += clock.now - segmented
            starts.append(windowStart)
            windowClasses.append(classes)
            let embedded = clock.now
            locals += try await localSpeakers(window: starts.count - 1, start: windowStart, samples: window, classes: classes)
            embeddingTime += clock.now - embedded
            if windowStart >= lastStart { break }
            windowStart += step
            buffer.removeFirst(min(buffer.count, windowStart - bufferStart))
            bufferStart = windowStart
        }
        buffer = []

        let duration = Double(total) / Self.rate
        var output = Output(timeline: SpeakerTimeline(clusters: 0, duration: duration), soloSpeech: [], audioSeconds: duration)
        output.windows = starts.count
        output.segmentationTime = segmentationTime
        output.embeddingTime = embeddingTime
        let (voices, centroids) = cluster(&locals)
        guard voices > 0 else { return output }
        output.voiceSimilarity = centroids.map { a in centroids.map { SpeakerClustering.dot(a, $0) } }

        // Activity: in each 20 ms frame, how many window frames had the voice, over how many window frames covered it.
        let frames = max(1, Int((duration / SpeakerTimeline.frame).rounded(.up)))
        var hits = [[Float]](repeating: [Float](repeating: 0, count: frames), count: voices)
        var cover = [Float](repeating: 0, count: frames)
        var byWindow = [[Int]](repeating: [], count: starts.count)
        for (index, local) in locals.enumerated() { byWindow[local.window].append(index) }

        func accumulate(window w: Int, only: Int?) {
            let labels: [Int?] = (0..<3).map { k in byWindow[w].first { locals[$0].speaker == k }.flatMap { locals[$0].label } }
            for (f, cls) in windowClasses[w].enumerated() {
                let time = (Double(starts[w] + Self.hop * f) + 495) / Self.rate
                let bin = Int(time / SpeakerTimeline.frame)
                guard bin < frames else { break }
                if only == nil { cover[bin] += 1 }
                var seen = Set<Int>()
                for k in SpeakerSegmentationModel.powerset[Int(cls)] {
                    guard let label = labels[k], only == nil || only == k, seen.insert(label).inserted else { continue }
                    hits[label][bin] += 1
                }
            }
        }
        for w in starts.indices { accumulate(window: w, only: nil) }

        // Too short to embed: the voice that speaks most around it, never another speaker of its window.
        for index in locals.indices where locals[index].kind == .tiny {
            let local = locals[index]
            let taken = Set(byWindow[local.window].compactMap { $0 == index ? nil : locals[$0].label })
            let from = max(0, Int((Double(starts[local.window]) / Self.rate - options.neighbourhood) / SpeakerTimeline.frame))
            let to = min(frames, Int((Double(starts[local.window]) / Self.rate + SpeakerSegmentationModel.windowSeconds + options.neighbourhood) / SpeakerTimeline.frame))
            guard from < to else { continue }
            let best = (0..<voices).filter { !taken.contains($0) }
                .map { label in (label, hits[label][from..<to].reduce(0, +)) }
                .max { $0.1 < $1.1 }
            guard let best, best.1 > 0 else {
                output.unplaced += 1
                continue
            }
            locals[index].label = best.0
            output.guessed += 1
            accumulate(window: local.window, only: local.speaker)
        }

        var timeline = SpeakerTimeline(clusters: voices, duration: duration)
        for label in 0..<voices {
            for bin in 0..<frames where cover[bin] > 0 { timeline.set(min(1, hits[label][bin] / cover[bin]), cluster: label, frame: bin) }
        }
        output.timeline = timeline
        var solo = [[Range<TimeInterval>]](repeating: [], count: voices)
        for local in locals where local.kind == .reliable { if let label = local.label { solo[label] += local.solo } }
        output.soloSpeech = solo.map { $0.sorted { ($0.upperBound - $0.lowerBound) > ($1.upperBound - $1.lowerBound) } }
        output.reliable = locals.filter { $0.kind == .reliable && $0.label != nil }.count
        output.weak = locals.filter { $0.kind == .weak && $0.label != nil }.count
        return output
    }

    /// The local speakers of one window, embedded when they have enough speech.
    private func localSpeakers(window: Int, start: Int, samples: [Float], classes: [UInt8]) async throws -> [Local] {
        var result: [Local] = []
        for k in 0..<3 {
            var soloFrames: [Int] = [], activeFrames: [Int] = []
            for (f, cls) in classes.enumerated() {
                let speakers = SpeakerSegmentationModel.powerset[Int(cls)]
                guard speakers.contains(k) else { continue }
                activeFrames.append(f)
                if speakers.count == 1 { soloFrames.append(f) }
            }
            guard !activeFrames.isEmpty else { continue }
            let frameSeconds = Double(Self.hop) / Self.rate
            let soloSeconds = Double(soloFrames.count) * frameSeconds
            let activeSeconds = Double(activeFrames.count) * frameSeconds
            let kind: Kind = soloSeconds >= options.reliableSeconds ? .reliable : activeSeconds >= options.weakSeconds ? .weak : .tiny
            var local = Local(window: window, speaker: k, kind: kind, embedding: nil, solo: [], soloSeconds: soloSeconds, label: nil)
            if kind != .tiny {
                let runs = Self.runs(kind == .reliable ? soloFrames : activeFrames)
                var audio: [Float] = []
                let cap = Int(options.embeddingSeconds * Self.rate)
                for run in runs where audio.count < cap {
                    let from = min(samples.count, Self.hop * run.lowerBound + Self.chunkOffset)
                    let to = min(samples.count, Self.hop * run.upperBound + Self.chunkOffset + Self.hop)
                    if from < to { audio += samples[from..<min(to, from + cap - audio.count)] }
                }
                do {
                    local.embedding = try await voice.embedding(samples: audio)
                } catch {
                    local.kind = .tiny
                }
                if local.kind == .reliable {
                    local.solo = runs.map { run in
                        let a = (Double(start + Self.hop * run.lowerBound + Self.chunkOffset)) / Self.rate
                        let b = (Double(start + Self.hop * run.upperBound + Self.chunkOffset + Self.hop)) / Self.rate
                        return a..<b
                    }
                }
            }
            result.append(local)
        }
        return result
    }

    /// Clusters the reliable embeddings into voices, folds the small voices into the nearest large one, places the weak
    /// embeddings, and returns the number of voices and their centroids. Labels are written onto `locals`.
    private func cluster(_ locals: inout [Local]) -> (Int, [[Float]]) {
        var reliable = locals.indices.filter { locals[$0].kind == .reliable }
        var overflow: [Int] = []
        if reliable.count > options.maxClustered {
            let stride = Double(reliable.count) / Double(options.maxClustered)
            let kept = Set((0..<options.maxClustered).map { reliable[Int(Double($0) * stride)] })
            overflow = reliable.filter { !kept.contains($0) }
            reliable = reliable.filter { kept.contains($0) }
        }
        guard !reliable.isEmpty else { return (0, []) }
        let vectors = reliable.map { locals[$0].embedding! }
        var labels = SpeakerClustering.agglomerate(vectors, threshold: options.threshold)

        // Small voices join the nearest large one: the smallest always, the minor ones when they resemble it.
        let count = (labels.max() ?? -1) + 1
        var seconds = [TimeInterval](repeating: 0, count: count)
        for (i, label) in labels.enumerated() { seconds[label] += locals[reliable[i]].soloSeconds }
        let centroids = SpeakerClustering.centroids(vectors, labels: labels)
        func fold(below limit: TimeInterval, minimumSimilarity: Float?) {
            let small = Set((0..<count).filter { seconds[$0] > 0 && seconds[$0] < limit })
            guard small.count < (0..<count).filter({ seconds[$0] > 0 }).count else { return }
            var into: [Int: Int] = [:]
            for label in small {
                guard let nearest = SpeakerClustering.nearest(centroids[label], centroids: centroids, excluding: small.union((0..<count).filter { seconds[$0] == 0 })),
                    nearest.similarity >= minimumSimilarity ?? -.infinity
                else { continue }
                into[label] = nearest.label
            }
            labels = labels.map { into[$0] ?? $0 }
            for (from, to) in into {
                seconds[to] += seconds[from]
                seconds[from] = 0
            }
        }
        fold(below: options.minimumVoiceSeconds, minimumSimilarity: nil)
        fold(below: options.minorVoiceSeconds, minimumSimilarity: options.minorVoiceSimilarity)
        // Compact: 0..<voices in order of first appearance.
        var compact: [Int: Int] = [:]
        labels = labels.map { label in
            if let c = compact[label] { return c }
            compact[label] = compact.count
            return compact.count - 1
        }
        for (i, index) in reliable.enumerated() { locals[index].label = labels[i] }
        let voices = SpeakerClustering.centroids(vectors, labels: labels)

        // The rest join the nearest voice that is not another speaker of their window.
        var byWindow: [Int: [Int]] = [:]
        for (index, local) in locals.enumerated() { byWindow[local.window, default: []].append(index) }
        let pending = overflow + locals.indices.filter { locals[$0].kind == .weak }
        for index in pending {
            guard let embedding = locals[index].embedding else { continue }
            let taken = Set(byWindow[locals[index].window, default: []].compactMap { $0 == index ? nil : locals[$0].label })
            if let nearest = SpeakerClustering.nearest(embedding, centroids: voices, excluding: taken),
                nearest.similarity >= options.weakSimilarity || locals[index].kind == .reliable
            {
                locals[index].label = nearest.label
            } else {
                locals[index].kind = .tiny
            }
        }
        for index in locals.indices { locals[index].embedding = nil }
        return (voices.count, voices)
    }

    /// Consecutive frame indices as closed runs.
    private static func runs(_ frames: [Int]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        for f in frames {
            if let last = runs.last, last.upperBound + 1 == f { runs[runs.count - 1] = last.lowerBound...f } else { runs.append(f...f) }
        }
        return runs
    }
}
