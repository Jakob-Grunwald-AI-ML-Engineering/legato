import Foundation
import LegatoComposerDoc

/// One finalized Soniox segment heard on the dictation route, in the order it was spoken.
public struct DictationRouteLine: Sendable, Equatable {
    public var sequence: Int
    public var text: String
    public var words: [Word]
    /// The segment boundary: `endpoint`, `punctuation`, `gap`, `finalize`, …
    public var reason: String
    public init(sequence: Int, text: String, words: [Word], reason: String) {
        self.sequence = sequence; self.text = text; self.words = words; self.reason = reason
    }
}

/// Receives the typing surface's speech. It never reaches the composer, its Room or its writer.
/// The keyboard session calls `reset` when it closes; a surface switch leaves delivered lines alone.
@MainActor public protocol DictationRouteSink: AnyObject {
    func receive(_ line: DictationRouteLine) async
    func reset() async
    /// The dictation surface is about to be used: warm whatever cleaning needs (connection, prompt cache).
    func warm() async
    /// The route heard speech (a new live tail): a pause timer restarts here.
    func speechActivity()
    /// The route's live tail changed (the words Soniox has not finalized, empty when none).
    func tailChanged(_ text: String)
    /// The take ended (stop): whatever was buffered is cleaned and written now.
    func finishTake() async
    /// The stream reached a boundary of its own (`finalize`: a requested cut is through; `finished`: the stream ended).
    /// Every segment spoken before it has been received.
    func boundary(_ reason: String)
    /// Recent written takes, newest last, sent to Soniox as background text when a take starts.
    var backgroundText: String { get }
}
public extension DictationRouteSink {
    func warm() async {}
    var backgroundText: String { "" }
    func speechActivity() {}
    func tailChanged(_ text: String) {}
    func finishTake() async {}
    func boundary(_ reason: String) {}
}

/// Counts finalized lines and does nothing else (the default for sessions without a keyboard link).
@MainActor public final class DiscardingDictationSink: DictationRouteSink {
    public private(set) var received = 0
    public init() {}
    public func receive(_ line: DictationRouteLine) async { received += 1 }
    public func reset() async {}
}
