import Foundation
import Testing
import LegatoComposerDoc
@testable import LegatoKeyboardCore

struct ComposerLinkTests {
    @Test func rangeIntentRoundTripsAndLegacyWordIntentStillDecodes() throws {
        let range = Data(#"{"id":"range","action":"tap","lineID":"L1","wordID":"W1","endLineID":"L3","endWordID":"W9","timestamp":100}"#.utf8)
        let intent = try JSONDecoder().decode(ComposerIntent.self, from: range)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(intent)) as? [String: Any])
        #expect(encoded["endLineID"] as? String == "L3")
        #expect(encoded["endWordID"] as? String == "W9")
        let legacy = Data(#"{"id":"word","action":"tap","lineID":"L1","wordID":"W1","timestamp":100}"#.utf8)
        let old = try JSONDecoder().decode(ComposerIntent.self, from: legacy)
        #expect(old.lineID == "L1" && old.wordID == "W1")
    }

    @Test func mutePublicationRoundTripsAndReadsLegacySnapshot() throws {
        let legacy = Data(#"{"snapshot":{"revision":0,"lines":[]},"hunks":[],"requiresSnapshot":false,"tail":"","mode":"message","status":"listening","pendingLineIDs":[],"busy":false}"#.utf8)
        #expect(try JSONDecoder().decode(ComposerPublication.self, from: legacy).muted != true)
        var publication = ComposerPublication()
        publication.muted = true
        #expect(try JSONDecoder().decode(ComposerPublication.self, from: JSONEncoder().encode(publication)).muted == true)
    }
    @Test func cumulativePublicationAndGapSnapshot() {
        var host = ComposerLinkHistory()
        let a = DocumentSnapshot(revision: 1, lines: [Line(id: "L1", words: [Word(text: "Hello")])])
        let b = DocumentSnapshot(revision: 2, lines: [Line(id: "L1", words: [Word(text: "Hello world")])])
        host.record(a, hunks: [.lineInserted(line: a.lines[0], index: 0)])
        host.record(b, hunks: [.wordsReplaced(lineID: "L1", old: a.lines[0].words, new: b.lines[0].words)])
        #expect(host.publication(acknowledged: 0).hunks.count == 2)
        #expect(host.publication(acknowledged: 1).hunks.count == 1)
        #expect(host.publication(acknowledged: -1).requiresSnapshot)
        #expect(host.publication(acknowledged: 2).snapshot == b)
    }
    @Test func insertionAcknowledgementCarriesSessionIdentity() throws {
        let link = ComposerLink(store: LinkStore(MemoryLinkStore()))
        let intent = ComposerIntent(action: "insert", sessionID: "session-before-send")
        link.send(intent)
        let received = try #require(link.drainIntents().first)
        #expect(received.sessionID == "session-before-send")
        var cleared = ComposerPublication()
        cleared.insertedIntentID = received.id
        link.publish(cleared)
        #expect(link.read()?.insertedIntentID == intent.id)
        #expect(link.read()?.snapshot.lines.isEmpty == true)
        #expect(link.drainIntents().isEmpty)
    }

    @Test func dictationProgressRoundTripsWithoutChangingTheDraft() {
        let link = ComposerLink(store: LinkStore(MemoryLinkStore()))
        var value = ComposerPublication(snapshot: .init(revision: 4, lines: [Line(words: [Word(text: "Spoken")])]))
        value.dictationRevision = 2
        value.dictationCommit = .init(sequence: 2, wordIDs: value.snapshot.lines.flatMap(\.words).map(\.id), uptime: 10)
        value.successfulInsertionID = "actual-delivery"
        link.publish(value)
        #expect(link.read()?.dictationRevision == 2)
        #expect(link.read()?.dictationCommit == value.dictationCommit)
        #expect(link.read()?.successfulInsertionID == "actual-delivery")
        #expect(link.read()?.snapshot == value.snapshot)
    }

    @Test func intentsHaveIndependentInboxKeys() {
        let store = LinkStore(MemoryLinkStore())
        let link = ComposerLink(store: store)
        link.send(.init(action: "undo")); link.send(.init(action: "cancel"))
        #expect(link.drainIntents().count == 2)
        #expect(link.drainIntents().isEmpty)
    }
}
