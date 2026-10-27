import Foundation
import Testing
import LegatoCore
@testable import LegatoAudio

private final class FakeEngine: PlaybackEngine {
    let url: URL
    let duration: TimeInterval
    var currentTime: TimeInterval = 0
    private(set) var isPlaying = false
    init(url: URL, duration: TimeInterval) { self.url = url; self.duration = duration }
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
}

private func folder(with names: [String]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "legato-player-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for name in names { try Data("x".utf8).write(to: url.appending(path: name)) }
    return url
}

@MainActor @Suite struct MeetingPlayerTests {
    private func player(_ folder: URL, duration: TimeInterval = 100) -> MeetingPlayer {
        MeetingPlayer(folder: folder) { FakeEngine(url: $0, duration: duration) }
    }

    @Test func itPrefersTheMixM4aThenTheMixCafThenTheMicRecording() throws {
        let all = try folder(with: ["mix.m4a", "mix.caf", "mic.m4a", "mic.caf", "system.m4a"])
        #expect(MeetingPlayer.audioURL(in: all)?.lastPathComponent == "mix.m4a")
        let caf = try folder(with: ["mix.caf", "mic.caf", "system.caf"])
        #expect(MeetingPlayer.audioURL(in: caf)?.lastPathComponent == "mix.caf", "until the audio step is done the CAF plays")
        let single = try folder(with: ["mic.m4a"])
        #expect(MeetingPlayer.audioURL(in: single)?.lastPathComponent == "mic.m4a", "one source: the mic is the mix")
        #expect(MeetingPlayer.audioURL(in: try folder(with: [])) == nil)
    }

    @Test func loadingAFolderWithNoRecordingThrows() throws {
        let p = player(try folder(with: ["meeting.json"]))
        #expect(throws: MeetingPlayer.PlayerError.noRecording) { try p.load() }
    }

    @Test func playAndPauseFollowTheEngine() throws {
        let p = player(try folder(with: ["mix.m4a"]))
        try p.load()
        #expect(p.duration == 100)
        #expect(!p.isPlaying)
        p.play()
        #expect(p.isPlaying)
        p.pause()
        #expect(!p.isPlaying)
        p.toggle()
        #expect(p.isPlaying)
        p.toggle()
        #expect(!p.isPlaying)
    }

    @Test func seekingSetsTheTimeAndClampsToTheRecording() throws {
        let p = player(try folder(with: ["mix.m4a"]), duration: 60)
        try p.load()
        p.seek(to: 42.5)
        #expect(p.currentTime == 42.5)
        p.seek(to: -5)
        #expect(p.currentTime == 0)
        p.seek(to: 1_000)
        #expect(p.currentTime == 60)
        p.seek(to: .nan)
        #expect(p.currentTime == 60, "a bad time changes nothing")
    }

    @Test func seekingWhilePlayingKeepsPlaying() throws {
        let p = player(try folder(with: ["mix.m4a"]))
        try p.load()
        p.play()
        p.seek(to: 10)
        #expect(p.isPlaying && p.currentTime == 10)
    }

    @Test func refreshSwitchesFromTheCafToTheM4aKeepingPositionAndPlayback() throws {
        let dir = try folder(with: ["mix.caf"])
        let p = player(dir)
        try p.load()
        #expect(p.source?.lastPathComponent == "mix.caf")
        p.play()
        p.seek(to: 33)

        try Data("y".utf8).write(to: dir.appending(path: "mix.m4a"))
        try FileManager.default.removeItem(at: dir.appending(path: "mix.caf"))
        try p.refresh()
        #expect(p.source?.lastPathComponent == "mix.m4a")
        #expect(p.currentTime == 33)
        #expect(p.isPlaying)
    }

    @Test func refreshWithTheSameFileKeepsTheEngine() throws {
        let dir = try folder(with: ["mix.m4a"])
        let made = Counter()
        let p = MeetingPlayer(folder: dir) { made.count += 1; return FakeEngine(url: $0, duration: 10) }
        try p.load()
        try p.refresh()
        #expect(made.count == 1)
    }

    @Test func aRealRecordingLoadsWithItsLength() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "legato-player-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = MeetingAudioWriter(folder: dir)
        try await writer.write(
            AudioChunk(samples: [Float](repeating: 0.1, count: 32_000), format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1)),
            stream: .mixed)
        try await writer.finish()
        let p = MeetingPlayer(folder: dir)
        try p.load()
        #expect(abs(p.duration - 2) < 0.05)
        #expect(p.source?.lastPathComponent == "mix.caf")
    }
}

@MainActor private final class Counter { var count = 0 }
