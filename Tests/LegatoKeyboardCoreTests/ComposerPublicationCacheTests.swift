import Foundation
import Synchronization
import Testing
import LegatoComposerDoc
@testable import LegatoKeyboardCore

private final class CountingPublicationStore: LinkValueStore, Sendable {
    private let state = Mutex((values: [String: Data](), writes: 0))
    var writes: Int { state.withLock { $0.writes } }
    func data(forKey key: String) -> Data? { state.withLock { $0.values[key] } }
    func set(_ data: Data?, forKey key: String) {
        state.withLock { $0.values[key] = data; $0.writes += 1 }
    }
    func keys(withPrefix prefix: String) -> [String] { state.withLock { $0.values.keys.filter { $0.hasPrefix(prefix) } } }
}

struct ComposerPublicationCacheTests {
    @Test func fiveThousandWordUnchangedPublicationWritesAndDecodesOnlyOnce() {
        let backing = CountingPublicationStore()
        let link = ComposerLink(store: LinkStore(backing))
        var writer = ComposerPublicationPublisher(), reader = ComposerPublicationReader()
        let words = (0..<5_000).map { Word(text: "word\($0)") }
        var value = ComposerPublication(snapshot: .init(revision: 1, lines: [Line(words: words)]))
        value.sessionID = "large-session"
        var publications = 0, reads = 0
        for _ in 0..<20 {
            if writer.publish(value, through: link) { publications += 1 }
            if let decoded = reader.read(from: link) {
                reads += 1
                #expect(decoded == value)
            }
        }
        #expect(publications == 1 && backing.writes == 1)
        #expect(reads == 1)
        #expect(link.read()?.snapshot.lines[0].words == words)
        // A status change without a document revision must still reach the keyboard immediately.
        value.status = "paused"
        let changed = writer.publish(value, through: link)
        #expect(changed)
        let paused = reader.read(from: link)
        #expect(paused?.status == "paused")
    }
    @Test func removedBackingValueIsRestoredAndFirstReaderResumesFromCurrentSnapshot() {
        let backing = CountingPublicationStore()
        let store = LinkStore(backing), link = ComposerLink(store: LinkStore(backing))
        var writer = ComposerPublicationPublisher(), reader = ComposerPublicationReader()
        let value = ComposerPublication(snapshot: .init(revision: 4, lines: [Line(words: [Word(text: "Keep")])]))
        let first = writer.publish(value, through: link)
        #expect(first)
        let read = reader.read(from: link)
        #expect(read == value)
        store.remove(forKey: LinkChannel.Key.composer)
        let missing = reader.read(from: link)
        #expect(missing == nil)
        let restored = writer.publish(value, through: link)
        #expect(restored)
        let recovered = reader.read(from: link)
        #expect(recovered == value)
        var restarted = ComposerPublicationReader()
        let resumed = restarted.read(from: link)
        #expect(resumed == value)
    }
    @Test func malformedValueDoesNotReplaceDraftAndChangedValidValueRecovers() {
        let store = LinkStore(MemoryLinkStore())
        let shared = ComposerLink(store: store)
        var reader = ComposerPublicationReader()
        store.writeEncodedData(Data("not-json".utf8), forKey: LinkChannel.Key.composer)
        let invalid = reader.read(from: shared)
        let repeatedInvalid = reader.read(from: shared)
        #expect(invalid == nil && repeatedInvalid == nil)
        var value = ComposerPublication(); value.sessionID = "recovered"
        shared.publish(value)
        let recovered = reader.read(from: shared)
        #expect(recovered == value)
    }
}
