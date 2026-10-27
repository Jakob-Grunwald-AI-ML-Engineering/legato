import Foundation
import Synchronization
import Testing
@testable import LegatoKeyboardCore

private final class Posts: Sendable {
    private let names = Mutex<[String]>([])
    func add(_ name: String) { names.withLock { $0.append(name) } }
    var all: [String] { names.withLock { $0 } }
    func count(_ name: String) -> Int { all.filter { $0 == name }.count }
}

@MainActor
private final class Refines {
    var texts: [String] = []
}

@MainActor
private struct LinkRig {
    let posts = Posts()
    let backing: MemoryLinkStore
    let store: LinkStore
    let link: HostLink
    let refines = Refines()

    init(backing: MemoryLinkStore = MemoryLinkStore(), answer: String? = "Refined.") {
        self.backing = backing
        store = LinkStore(backing)
        let posts = self.posts
        link = HostLink(
            store: store, post: { posts.add($0) }, now: { t0 },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let refines = self.refines
        link.onRefine = { text in
            refines.texts.append(text)
            return answer
        }
    }

    var host: HostState? { store.read(HostState.self, forKey: LinkChannel.Key.host) }
    var ack: KeyboardAck? { store.read(KeyboardAck.self, forKey: LinkChannel.Key.ack) }
    var reply: RefineReply? { store.read(RefineReply.self, forKey: LinkChannel.Key.refined) }
    var request: RefineRequest? { store.read(RefineRequest.self, forKey: LinkChannel.Key.refine) }

    func askRefine(_ text: String, id: String = "ref-1", age: TimeInterval = 0) {
        store.write(RefineRequest(id: id, text: text, at: t0.addingTimeInterval(-age)), forKey: LinkChannel.Key.refine)
    }
}

@MainActor
@Suite struct HostLinkCleanupTests {
    // MARK: delivery and final text

    @Test func theRunsDeliveryIsPublishedWithItsStart() {
        let r = LinkRig()
        r.link.runStarted(id: "run-1", target: .keyboard, delivery: .hold)
        #expect(r.host?.delivery == .hold)
        r.link.update(committed: "hello ", volatile: "")
        #expect(r.host?.delivery == .hold)
    }

    @Test func theFinalStateCarriesTheCleanedText() {
        let r = LinkRig()
        r.link.runStarted(id: "run-1", target: .keyboard, delivery: .replace)
        r.link.update(committed: "um hello ", volatile: "")
        r.link.runEnded(committed: "um hello ", finalText: "Hello.")
        #expect(r.host?.isFinal == true)
        #expect(r.host?.committed == "um hello " && r.host?.finalText == "Hello.")
    }

    @Test func aNewRunForgetsTheLastCleanedTextAndDelivery() {
        let r = LinkRig()
        r.link.runStarted(id: "run-1", target: .keyboard, delivery: .clipboard)
        r.link.runEnded(committed: "a ", finalText: "A.")
        r.link.runStarted(id: "run-2", target: .keyboard)
        #expect(r.host?.finalText == nil && r.host?.delivery == nil)
    }

    @Test func theScrubRemovesTheCleanedText() {
        let r = LinkRig()
        r.link.runStarted(id: "run-1", target: .keyboard, delivery: .replace)
        r.link.runEnded(committed: "a ", finalText: "A.")
        r.link.scrubText()
        #expect(r.host?.finalText == nil && r.host?.committed == "")
    }

    @Test func anOldStateWithoutTheNewFieldsStillDecodes() throws {
        let json = #"{"v":1,"runID":"r","phase":"idle","target":"keyboard","committed":"a","volatile":"","seq":3,"beatAt":1000,"acceptsRemoteStart":false}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let state = try decoder.decode(HostState.self, from: Data(json.utf8))
        #expect(state.finalText == nil && state.delivery == nil)
    }

    // MARK: finishing

    @Test func finishingIsPublishedAtOnceAndLaterUpdatesKeepIt() {
        let r = LinkRig()
        r.link.runStarted(id: "run-1", target: .keyboard)
        r.link.update(committed: "hello ", volatile: "wor")
        r.link.runFinishing()
        #expect(r.host?.phase == .finishing)
        r.link.update(committed: "hello world ", volatile: "")
        #expect(r.link.state.phase == .finishing)
        #expect(r.link.state.committed == "hello world ")
    }

    // MARK: refine

    @Test func aRefineRequestIsAckedAnsweredAndItsTextLeavesTheStore() async {
        let r = LinkRig()
        r.askRefine("um hello world")
        await r.link.processRefine()
        #expect(r.ack == KeyboardAck(id: "ref-1", result: .accepted))
        #expect(r.refines.texts == ["um hello world"])
        #expect(r.reply == RefineReply(id: "ref-1", text: "Refined."))
        #expect(r.request == nil)
        #expect(r.posts.count(LinkChannel.Note.ack) == 1)
        #expect(r.posts.count(LinkChannel.Note.refined) == 1)
    }

    @Test func noBetterTextIsAnsweredWithoutText() async {
        let r = LinkRig(answer: nil)
        r.askRefine("hello")
        await r.link.processRefine()
        #expect(r.reply == RefineReply(id: "ref-1", text: nil))
    }

    @Test func aStaleRefineRequestIsIgnored() async {
        let r = LinkRig()
        r.askRefine("hello", age: LinkChannel.requestMaxAge + 1)
        await r.link.processRefine()
        #expect(r.ack == nil && r.reply == nil && r.refines.texts.isEmpty)
    }

    @Test func theSameRefineRequestIsActedOnOnce() async {
        let r = LinkRig()
        r.askRefine("hello")
        await r.link.processRefine()
        r.askRefine("hello") // the same id again
        await r.link.processRefine()
        #expect(r.refines.texts == ["hello"])
    }

    @Test func startingTheLinkRemovesLeftoverRefineText() {
        let backing = MemoryLinkStore()
        let old = LinkRig(backing: backing)
        old.askRefine("private words")
        old.store.write(RefineReply(id: "x", text: "Private words."), forKey: LinkChannel.Key.refined)
        let fresh = LinkRig(backing: backing)
        #expect(fresh.request == nil && fresh.reply == nil)
    }
}
