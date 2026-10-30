import AVFAudio
import Foundation
import Testing
import LegatoCore
@testable import LegatoAppServices

struct ComposerAudioRecorderTests {
    @Test func recordsNativePipelineFormatAsPlayableAAC() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try record(url)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length > 0)
    }

    private func record(_ url: URL) throws {
        let recorder = try ComposerAudioRecorder(url: url)
        try recorder.append(AudioChunk(samples: Array(repeating: 0.01, count: 16000), format: .init(sampleRate: 16000, channelCount: 1)))
    }
}
