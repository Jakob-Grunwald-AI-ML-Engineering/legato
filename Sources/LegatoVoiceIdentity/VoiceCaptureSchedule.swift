import Foundation

/// Walks a reading script against the recorded audio, never the wall clock: a step's time is the audio recorded in
/// it, so the countdown, the step ends and the labelled intervals agree with the samples, however late the app
/// gets to look. A quiet step ends after its length. A reading step ends on Next sentence, when the reader has
/// spoken and then stayed silent for a moment (after at least half the estimated time), or at its tolerant maximum.
public struct VoiceCaptureSchedule: Sendable {
    public let script: VoiceReadingScript
    public let sampleRate: Double
    /// The current step; `script.steps.count` once finished.
    public private(set) var stepIndex = 0
    /// The sample the current step started at.
    public private(set) var stepStart = 0
    /// Samples taken into the recording; audio after the last step is not part of it.
    public private(set) var sampleCount = 0
    public private(set) var intervals: [VoiceRecordingInterval] = []
    private var advanceRequested = false
    private var activity = SpeechActivity()
    private let frameLength: Int
    private var frameEnergy: Float = 0
    private var frameFill = 0

    /// Silence after speech that ends a reading step.
    public static let pauseSeconds = 1.2
    /// Speech a reading step needs before a pause can end it.
    public static let minimumSpeechSeconds = 0.6

    public init(script: VoiceReadingScript, sampleRate: Double = 16000) {
        self.script = script; self.sampleRate = sampleRate
        frameLength = max(1, Int(sampleRate / 50))
    }

    public var isFinished: Bool { stepIndex >= script.steps.count }
    public var currentStep: VoiceScriptStep? { isFinished ? nil : script.steps[stepIndex] }
    /// Seconds of audio recorded in the current step.
    public var stepElapsed: Double { Double(sampleCount - stepStart) / sampleRate }
    /// 1-based number of the sentence being read, or the last one read during a pause.
    public var sentence: Int { script.steps.prefix(min(stepIndex + 1, script.steps.count)).filter { $0.prompt != nil }.count }
    /// The whole recording, by the planned lengths: finished steps count fully, the current one up to its plan.
    public var progress: Double {
        guard !isFinished else { return 1 }
        let done = script.steps.prefix(stepIndex).reduce(0) { $0 + $1.seconds } + min(stepElapsed, script.steps[stepIndex].seconds)
        return min(1, done / max(1, script.plannedSeconds))
    }
    /// The current step up to its planned length.
    public var stepProgress: Double {
        guard let step = currentStep else { return 1 }
        return min(1, stepElapsed / max(0.1, step.seconds))
    }
    /// Whole seconds left in a quiet step, as the countdown shows them.
    public var quietRemaining: Int {
        guard let step = currentStep, step.prompt == nil else { return 0 }
        return max(0, Int((step.seconds - stepElapsed).rounded(.up)))
    }

    /// Next sentence: ends the current reading step at the next frame. Ignored in a pause and in the first second
    /// of a sentence, so a double tap does not skip one.
    public mutating func requestAdvance() {
        guard currentStep?.prompt != nil, stepElapsed >= 1 else { return }
        advanceRequested = true
    }

    /// Takes samples into the recording and returns how many were taken: all of them, unless the script finished
    /// inside `samples` (the rest are after the recording).
    @discardableResult
    public mutating func consume<S: Collection>(_ samples: S) -> Int where S.Element == Float {
        var taken = 0
        for sample in samples {
            guard !isFinished else { break }
            sampleCount += 1; taken += 1
            frameEnergy += sample * sample; frameFill += 1
            guard frameFill == frameLength else { continue }
            activity.observe(rms: (frameEnergy / Float(frameLength)).squareRoot(), frameSeconds: Double(frameLength) / sampleRate,
                             quiet: currentStep?.prompt == nil)
            frameEnergy = 0; frameFill = 0
            endStepIfDue()
        }
        return taken
    }

    private mutating func endStepIfDue() {
        guard let step = currentStep else { return }
        let elapsed = stepElapsed
        let ended: Bool
        if step.prompt == nil {
            ended = elapsed >= step.seconds
        } else {
            let finishedSpeaking = activity.speechSeconds >= Self.minimumSpeechSeconds && activity.silenceSeconds >= Self.pauseSeconds
                && elapsed >= step.seconds / 2
            ended = advanceRequested || finishedSpeaking || elapsed >= step.maximumSeconds
        }
        guard ended else { return }
        let start = Double(stepStart) / sampleRate * 1000, end = Double(sampleCount) / sampleRate * 1000
        if let prompt = step.prompt {
            intervals.append(.init(kind: .reading, startMs: start, endMs: end, prompt: prompt))
        } else {
            intervals.append(.init(kind: .quiet, startMs: min(end, start + VoiceReadingScript.quietSettleSeconds * 1000), endMs: end))
        }
        stepIndex += 1; stepStart = sampleCount; advanceRequested = false
        activity.startStep()
    }
}

/// Speech or silence, frame by frame, against the room's noise floor. The floor starts at a quiet room's level and
/// drops at once to any quieter frame. While the user reads it barely rises, so a long sentence is never mistaken
/// for silence; in a quiet pause it settles on the room's level within seconds, so a car or TV that is always
/// there does not count as speech afterwards. A room too loud to tell runs each sentence to its maximum.
struct SpeechActivity: Sendable {
    private(set) var floor: Float = 0.001
    private(set) var speechSeconds = 0.0
    private(set) var silenceSeconds = 0.0
    /// Speech is this many times the floor's level (about 12 dB) and above an absolute minimum.
    static let ratio: Float = 4
    static let minimumLevel: Float = 0.004

    mutating func startStep() { speechSeconds = 0; silenceSeconds = 0 }
    mutating func observe(rms: Float, frameSeconds: Double, quiet: Bool) {
        let current = floor
        floor = rms < current ? max(rms, 0.00001) : current + (rms - current) * (quiet ? 0.01 : 0.0002)
        if rms > max(current * Self.ratio, Self.minimumLevel) {
            speechSeconds += frameSeconds; silenceSeconds = 0
        } else {
            silenceSeconds += frameSeconds
        }
    }
}
