import AVFAudio
import Foundation
import Observation

/// What the player needs of an audio player; `AVAudioPlayer` provides it.
public protocol PlaybackEngine: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }
    @discardableResult func play() -> Bool
    func pause()
}

extension AVAudioPlayer: PlaybackEngine {}

/// Plays a meeting's recording: play, pause and seek, no speed control.
///
/// It plays the mix (`mix.m4a`, written when the audio step is done) and until then the CAF it is made from;
/// a meeting with one source has no mix, and its mic recording is the mix. Call ``refresh()`` when the audio
/// step finishes: the player moves to the m4a where it was, playing or not.
///
/// The time moves by itself while playing, so a view calls ``sync()`` on a timer (and after any change of its
/// own) to read it.
@MainActor @Observable
public final class MeetingPlayer {
    public enum PlayerError: Error, Equatable { case noRecording }

    /// The recording to play in `folder`, best first: `mix.m4a`, `mix.caf`, then the mic's (the mix of a meeting
    /// with one source). Nil when there is none.
    public nonisolated static func audioURL(in folder: URL) -> URL? {
        ["mix.m4a", "mix.caf", "mic.m4a", "mic.caf"]
            .map { folder.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let makeEngine: (URL) throws -> any PlaybackEngine
    @ObservationIgnored private var engine: (any PlaybackEngine)?

    /// The file being played; nil before ``load()``.
    public private(set) var source: URL?
    public private(set) var duration: TimeInterval = 0
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var isPlaying = false

    public init(folder: URL, makeEngine: @escaping (URL) throws -> any PlaybackEngine = { try AVAudioPlayer(contentsOf: $0) }) {
        self.folder = folder
        self.makeEngine = makeEngine
    }

    /// Opens the best recording. Does not start playing.
    /// - Throws: ``PlayerError/noRecording`` when the folder has none.
    public func load() throws {
        guard let url = Self.audioURL(in: folder) else { throw PlayerError.noRecording }
        engine = try makeEngine(url)
        source = url
        sync()
    }

    /// Moves to a better recording if one has appeared (the m4a after the CAF), keeping the position and
    /// whether it was playing. Does nothing when the best recording is the one open.
    public func refresh() throws {
        guard engine != nil else { return try load() }
        guard let url = Self.audioURL(in: folder), url != source else { return }
        let position = engine?.currentTime ?? 0, wasPlaying = engine?.isPlaying ?? false
        engine?.pause()
        let next = try makeEngine(url)
        next.currentTime = max(0, min(position, next.duration))
        engine = next
        source = url
        if wasPlaying { next.play() }
        sync()
    }

    public func play() {
        engine?.play()
        sync()
    }

    public func pause() {
        engine?.pause()
        sync()
    }

    public func toggle() {
        if engine?.isPlaying == true { pause() } else { play() }
    }

    /// Jumps to `time` seconds, clamped to the recording. Playback carries on if it was playing.
    public func seek(to time: TimeInterval) {
        guard let engine, time.isFinite else { return }
        engine.currentTime = max(0, min(time, engine.duration))
        sync()
    }

    /// Reads the time and the playing state from the engine.
    public func sync() {
        guard let engine else { return }
        duration = engine.duration
        currentTime = engine.currentTime
        isPlaying = engine.isPlaying
    }
}
