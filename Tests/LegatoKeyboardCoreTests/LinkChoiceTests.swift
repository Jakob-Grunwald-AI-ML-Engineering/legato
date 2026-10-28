import Foundation
import Synchronization
import Testing
@testable import LegatoKeyboardCore

private final class Posts: Sendable {
    private let names = Mutex<[String]>([])
    func add(_ name: String) { names.withLock { $0.append(name) } }
    var all: [String] { names.withLock { $0 } }
}

@MainActor
private struct ChoiceRig {
    let backing = MemoryLinkStore()
    let store: LinkStore
    let posts = Posts()
    let link: HostLink

    init() {
        store = LinkStore(backing)
        let posts = self.posts
        link = HostLink(
            store: store, post: { posts.add($0) }, now: { t0 },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    }

    func choice(_ original: String = "fahren", _ chosen: String = "Varen", age: TimeInterval = 0, vocab: Bool = true) -> ChoiceRecord {
        ChoiceRecord(original: original, chosen: chosen, fromVocabulary: vocab, at: t0.addingTimeInterval(-age))
    }
}

@MainActor
@Suite struct LinkChoiceTests {
    @Test func theKeyboardWritesOneKeyPerChoiceAndPostsTheNote() {
        let r = ChoiceRig()
        let posts = r.posts
        ChoiceWriter.write(r.choice("a", "b"), to: r.store, id: "one", post: { posts.add($0) })
        ChoiceWriter.write(r.choice("c", "d"), to: r.store, id: "two", post: { posts.add($0) })
        #expect(r.store.read(ChoiceRecord.self, forKey: "link.choice.one")?.chosen == "b")
        #expect(r.store.read(ChoiceRecord.self, forKey: "link.choice.two")?.chosen == "d")
        #expect(posts.all.filter { $0 == LinkChannel.Note.choice } == [LinkChannel.Note.choice, LinkChannel.Note.choice])
    }

    @Test func draining_returnsFreshChoicesAndDeletesTheirKeys() {
        let r = ChoiceRig()
        r.store.write(r.choice("a", "b"), forKey: LinkChannel.Key.choicePrefix + "1")
        r.store.write(r.choice("c", "d", age: 3600), forKey: LinkChannel.Key.choicePrefix + "2")
        let drained = r.link.drainChoices(now: t0)
        #expect(Set(drained.map(\.chosen)) == ["b", "d"])
        #expect(r.backing.keys(withPrefix: LinkChannel.Key.choicePrefix).isEmpty)
        #expect(r.link.drainChoices(now: t0).isEmpty)
    }

    @Test func draining_dropsChoicesOlderThanSevenDaysButStillDeletesThem() {
        let r = ChoiceRig()
        r.store.write(r.choice(age: 7 * 86_400 + 1), forKey: LinkChannel.Key.choicePrefix + "old")
        r.store.write(r.choice("x", "y", age: 7 * 86_400 - 1), forKey: LinkChannel.Key.choicePrefix + "edge")
        let drained = r.link.drainChoices(now: t0)
        #expect(drained.map(\.chosen) == ["y"])
        #expect(r.backing.keys(withPrefix: LinkChannel.Key.choicePrefix).isEmpty)
    }

    @Test func draining_deletesAKeyThatDoesNotDecode() {
        let r = ChoiceRig()
        r.backing.set(Data("nope".utf8), forKey: LinkChannel.Key.choicePrefix + "bad")
        #expect(r.link.drainChoices(now: t0).isEmpty)
        #expect(r.backing.keys(withPrefix: LinkChannel.Key.choicePrefix).isEmpty)
    }

    @Test func draining_returnsTheOldestFirst() {
        let r = ChoiceRig()
        r.store.write(r.choice("n", "new", age: 10), forKey: LinkChannel.Key.choicePrefix + "b")
        r.store.write(r.choice("o", "old", age: 100), forKey: LinkChannel.Key.choicePrefix + "a")
        #expect(r.link.drainChoices(now: t0).map(\.chosen) == ["old", "new"])
    }

    @Test func draining_leavesOtherKeysAlone() {
        let r = ChoiceRig()
        r.store.write(r.choice(), forKey: LinkChannel.Key.choicePrefix + "1")
        _ = r.link.drainChoices(now: t0)
        #expect(r.store.read(HostState.self, forKey: LinkChannel.Key.host) != nil)
    }

    @Test func aStartingHostKeepsChoicesTheKeyboardQueuedWhileTheAppWasAway() {
        let backing = MemoryLinkStore()
        let store = LinkStore(backing)
        store.write(ChoiceRecord(original: "a", chosen: "b", fromVocabulary: false, at: t0), forKey: LinkChannel.Key.choicePrefix + "1")
        let link = HostLink(store: store, post: { _ in }, now: { t0 }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        #expect(link.drainChoices(now: t0).count == 1)
    }

    @Test func scrubbingTextKeepsPendingChoices() {
        // The retention timer scrubs a finished run's text after a few seconds; choices the app has not read yet
        // are not that text and must survive it.
        let r = ChoiceRig()
        r.store.write(r.choice(), forKey: LinkChannel.Key.choicePrefix + "1")
        r.link.scrubText()
        #expect(r.backing.keys(withPrefix: LinkChannel.Key.choicePrefix).count == 1)
        #expect(r.link.drainChoices(now: t0).count == 1)
    }

    @Test func theRetentionTimerLeavesUnreadChoicesAlone() async {
        let backing = MemoryLinkStore()
        let store = LinkStore(backing)
        let link = HostLink(store: store, post: { _ in }, now: { t0 }, sleep: { _ in })
        store.write(ChoiceRecord(original: "a", chosen: "b", fromVocabulary: false, at: t0), forKey: LinkChannel.Key.choicePrefix + "1")
        link.runStarted(id: "r", target: .keyboard)
        link.runEnded(committed: "hello")
        let deadline = ContinuousClock.now + .seconds(30)
        while store.read(HostState.self, forKey: LinkChannel.Key.host)?.runID != nil,
              ContinuousClock.now < deadline { await Task.yield() }
        let scrubbed = store.read(HostState.self, forKey: LinkChannel.Key.host)
        #expect(scrubbed?.runID == nil && scrubbed?.committed == "")
        #expect(backing.keys(withPrefix: LinkChannel.Key.choicePrefix).count == 1)
    }

    @Test func deletingHistoryRemovesPendingChoicesUnread() {
        let r = ChoiceRig()
        r.store.write(r.choice(), forKey: LinkChannel.Key.choicePrefix + "1")
        r.store.write(r.choice("c", "d"), forKey: LinkChannel.Key.choicePrefix + "2")
        r.link.removePendingChoices()
        #expect(r.backing.keys(withPrefix: LinkChannel.Key.choicePrefix).isEmpty)
        #expect(r.link.drainChoices(now: t0).isEmpty)
    }

    @Test func theRecordRoundTripsThroughTheStore() {
        let r = ChoiceRig()
        let record = ChoiceRecord(original: "wind", chosen: "wand", fromVocabulary: true, at: t0)
        r.store.write(record, forKey: "k")
        #expect(r.store.read(ChoiceRecord.self, forKey: "k") == record)
    }
}
