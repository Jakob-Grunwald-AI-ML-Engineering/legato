// CAM++ preprocessing follows FluidAudio CampPlusEmbedder (Apache-2.0).
// Copyright FluidInference / FluidAudio contributors; source and license in README.md.
import AVFoundation
import CoreML
import Foundation
import Darwin

let outputRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ONLY_MY_VOICE_OUTPUT_DIR"] ?? "spikes/only-my-voice/results")
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let manifest: [String: [String: [String]]]? = CommandLine.arguments.count > 2 && CommandLine.arguments[2] != "-"
    ? try JSONDecoder().decode([String: [String: [String]]].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) : nil
let speakers = manifest?.keys.sorted() ?? ["jackson", "nicolas", "theo", "yweweler", "george", "lucas"]
let cpuOnly = CommandLine.arguments.contains("--cpu-only")
let label = cpuOnly ? "cpu" : "gpu"
let clock = ContinuousClock()
func seconds(_ duration: Duration) -> Double { Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 }
func loadModel(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
    let config = MLModelConfiguration(); config.computeUnits = units
    return try MLModel(contentsOf: root.appendingPathComponent(".cache/models/\(name).mlmodelc"), configuration: config)
}
let loadStart = clock.now
let pre = try loadModel("CamPlusPreprocessor_v2", .cpuOnly)
let model = try loadModel("CamPlusPlus_v2", cpuOnly ? .cpuOnly : .cpuAndGPU)
let loadSeconds = seconds(loadStart.duration(to: clock.now))
func audio(_ speaker: String, _ take: Int) throws -> [Float] {
    var output: [Float] = []
    let paths = manifest?[speaker]?[String(take)] ?? (0..<10).map { root.appendingPathComponent(".cache/audio/\($0)_\(speaker)_\(take).wav").path }
    for path in paths {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 16000 / file.processingFormat.sampleRate) + 128)!
        var supplied = false; var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        output.append(contentsOf: UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
    }
    return output
}
func embed(_ samples: [Float]) throws -> [Float] {
    let wave = try MLMultiArray(shape: [1, NSNumber(value: samples.count)], dataType: .float32)
    let pointer = wave.dataPointer.assumingMemoryBound(to: Float.self)
    for i in samples.indices { pointer[i] = samples[i] * 32768 }
    let result = try pre.prediction(from: MLDictionaryFeatureProvider(dictionary: ["waveform": MLFeatureValue(multiArray: wave)]))
    let features = result.featureValue(for: "features")!.multiArrayValue!
    let frames = features.shape[1].intValue; let bands = features.shape[2].intValue
    for band in 0..<bands {
        var mean = 0.0
        for frame in 0..<frames { mean += features[[0, NSNumber(value: frame), NSNumber(value: band)]].doubleValue }
        mean /= Double(frames)
        for frame in 0..<frames {
            let index = [NSNumber(value: 0), NSNumber(value: frame), NSNumber(value: band)]
            features[index] = NSNumber(value: features[index].doubleValue - mean)
        }
    }
    let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["feats": MLFeatureValue(multiArray: features)]))
    let array = prediction.featureValue(for: "embedding")!.multiArrayValue!
    let vector = (0..<array.count).map { array[$0].floatValue }
    let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
    return vector.map { $0 / max(norm, 1e-9) }
}
func cosine(_ a: [Float], _ b: [Float]) -> Double { Double(zip(a,b).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }
var profiles: [[Float]] = []
var enrollment: [[String: Any]] = []
for speaker in speakers {
    let samples = try audio(speaker, 5)
    let start = clock.now
    profiles.append(try embed(samples))
    enrollment.append(["speaker": speaker, "seconds": Double(samples.count)/16000, "inference_ms": seconds(start.duration(to: clock.now))*1000])
}
var trials: [[String: Any]] = []
for take in [6, 0] {
    for (speakerIndex, speaker) in speakers.enumerated() {
        let samples = try audio(speaker, take)
        for window in [0.35, 1.0, 2.0, 3.0] {
            let count = Int(window * 16000)
            for offset in stride(from: 0, through: max(0, samples.count-count), by: count) {
                guard offset + count <= samples.count else { continue }
                let start = clock.now
                let embedding = try embed(Array(samples[offset..<offset+count]))
                let elapsed = seconds(start.duration(to: clock.now))
                trials.append(["split": take == 6 ? "calibration" : "test", "speaker": speaker, "speaker_index": speakerIndex,
                    "window_seconds": window, "offset_seconds": Double(offset)/16000, "inference_ms": elapsed*1000,
                    "scores": profiles.map { cosine($0, embedding) }, "embedding": embedding])
            }
        }
    }
}
var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
let report: [String: Any] = ["model_load_seconds": loadSeconds, "peak_rss_bytes": usage.ru_maxrss,
    "user_cpu_seconds": Double(usage.ru_utime.tv_sec)+Double(usage.ru_utime.tv_usec)/1e6,
    "system_cpu_seconds": Double(usage.ru_stime.tv_sec)+Double(usage.ru_stime.tv_usec)/1e6,
    "compute_units": label, "hardware": ProcessInfo.processInfo.operatingSystemVersionString, "enrollment": enrollment, "trials": trials]
let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputRoot.appendingPathComponent("embeddings-\(manifest == nil ? "digits" : "sentences")-\(label).json"))
print("Measured \(trials.count) windows; peak RSS \(usage.ru_maxrss) bytes; load \(loadSeconds)s")
