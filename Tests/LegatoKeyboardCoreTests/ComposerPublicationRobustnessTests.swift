import Foundation
import Synchronization
import Testing
import LegatoComposerDoc
@testable import LegatoKeyboardCore

private final class MemoryStore: LinkValueStore, Sendable {
    private let values = Mutex([String: Data]())
    func data(forKey key: String) -> Data? { values.withLock { $0[key] } }
    func set(_ data: Data?, forKey key: String) { values.withLock { $0[key] = data } }
    func keys(withPrefix prefix: String) -> [String] { values.withLock { $0.keys.filter { $0.hasPrefix(prefix) } } }
}

/// #225: the keyboard copy of the composer must follow the host's draft whatever happens on the wire.
struct ComposerPublicationRobustnessTests {
    private func draft(_ revision: Int, _ text: String = "Draft") -> ComposerPublication {
        var value = ComposerPublication(snapshot: .init(revision: revision, lines: [Line(words: [Word(text: text)])]))
        value.sessionID = "s"
        return value
    }

    /// Hypothesis 3: a stray NaN made the whole publication unencodable, leaving the keyboard blank.
    @Test func nonFiniteCountdownStillPublishesTheDraft() {
        let link = ComposerLink(store: LinkStore(MemoryStore()))
        var writer = ComposerPublicationPublisher(), reader = ComposerPublicationReader()
        var value = draft(1)
        value.correctionCountdownStart = .nan
        value.correctionCountdownDeadline = .infinity
        let published = writer.publish(value, through: link)
        #expect(published)
        let read = reader.read(from: link)
        #expect(read?.snapshot == value.snapshot)
        #expect(read?.correctionCountdownStart?.isNaN == true)
        #expect(read?.correctionCountdownDeadline == .infinity)
        // The same non-comparable value is not republished every tick.
        let again = writer.publish(value, through: link)
        #expect(!again)
    }

    /// Hypothesis 3: undecodable bytes are reported, and a later good publication is read.
    @Test func decodeFailureIsReportedAndNextPublicationDecodes() {
        let backing = MemoryStore()
        let link = ComposerLink(store: LinkStore(backing))
        var reader = ComposerPublicationReader()
        backing.set(Data("{not json".utf8), forKey: LinkChannel.Key.composer)
        let broken = reader.read(from: link)
        #expect(broken == nil)
        #expect(reader.lastDecodeFailureBytes == 9)
        var writer = ComposerPublicationPublisher()
        let published = writer.publish(draft(2), through: link)
        #expect(published)
        let good = reader.read(from: link)
        #expect(good?.snapshot.revision == 2)
        #expect(reader.lastDecodeFailureBytes == nil)
    }

    /// Hypothesis 4: the keyboard's appearance reads afresh even when its reader already saw these bytes.
    @Test func resetReaderDeliversUnchangedBytesAgain() {
        let link = ComposerLink(store: LinkStore(MemoryStore()))
        var writer = ComposerPublicationPublisher(), reader = ComposerPublicationReader()
        _ = writer.publish(draft(3), through: link)
        let first = reader.read(from: link), second = reader.read(from: link)
        #expect(first != nil && second == nil)
        reader.reset()
        let third = reader.read(from: link)
        #expect(third?.snapshot.revision == 3)
    }

    /// Hypothesis 5: a restarted document may reuse a revision number with other lines.
    @Test func historyRecordsSameRevisionWithDifferentLines() {
        var history = ComposerLinkHistory()
        let first = draft(4, "Old").snapshot, second = draft(4, "New").snapshot
        #expect(history.needsRecord(first))
        history.record(first, hunks: [])
        #expect(!history.needsRecord(first))
        #expect(history.needsRecord(second))
        history.record(second, hunks: [])
        #expect(history.publication(acknowledged: 4).snapshot == second)
    }
}
