import Foundation
import Testing
@testable import LegatoFieldEdit
@testable import LegatoKeyboardCore

private func link(
    _ backing: MemoryLinkStore = MemoryLinkStore(), capacity: Int = 256, notes: NoteLog = NoteLog()
) -> FieldFeedLink {
    FieldFeedLink(store: LinkStore(backing), post: { notes.add($0) }, capacity: capacity)
}

private final class NoteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
}

private let session = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
private let step = EditStep(span: Span(location: 1, length: 2), text: "xy", expect: "bc")

private func batch(_ events: [FeedEvent], from first: Int = 1, version: Int = 1) -> FeedBatch {
    FeedBatch(
        entries: events.enumerated().map { FeedEntry(seq: first + $0.offset, event: $0.element) },
        version: FieldVersion(version), session: session)
}

private func allEvents() -> [FeedEvent] {
    let id = UUID(), other = UUID()
    return [
        .asrDelta("hello"),
        .applied(id, origin: .agent, steps: [step], version: FieldVersion(2)),
        .foreign(step, byUser: true, version: FieldVersion(3)),
        .conflict(id, Conflict(.overlap, intervening: step, byUser: true)),
        .superseded(id, by: other),
        .rebased(window: "abc", shift: -4, version: FieldVersion(4)),
        .reset(.cleared, window: "", version: FieldVersion(5)),
        .reset(.unaligned, window: "w", version: FieldVersion(6)),
        .reset(.focusChanged, window: "f", version: FieldVersion(7)),
    ]
}

@Suite struct FieldFeedLinkTests {
    @Test func everyFeedEventCaseSurvivesTheLink() throws {
        let backing = MemoryLinkStore()
        let notes = NoteLog()
        let keyboard = link(backing, notes: notes)
        let sent = batch(allEvents())
        keyboard.append(sent, window: "abc")
        #expect(notes.all == [LinkChannel.Note.feed])

        let app = link(backing)
        let read = try #require(app.readFeed(after: nil))
        // A reader with no cursor starts from the window, then follows from there.
        #expect(read.batches.count == 1 && read.batches[0].resync)
        #expect(read.batches[0].window == "abc")
        let follow = try #require(app.readFeed(after: FeedCursor(writer: read.cursor.writer, seq: 0)))
        #expect(follow.batches == [sent])
        #expect(follow.cursor.seq == 1)
    }

    @Test func aReaderAtTheNewestSeqGetsNothing() throws {
        let keyboard = link()
        keyboard.append(batch([.asrDelta("a")]), window: "a")
        let first = try #require(keyboard.readFeed(after: nil))
        let again = try #require(keyboard.readFeed(after: first.cursor))
        #expect(again.batches.isEmpty)
        #expect(again.cursor == first.cursor)
    }

    @Test func batchesComeInSeqOrder() throws {
        let keyboard = link()
        keyboard.append(batch([.asrDelta("e1")], from: 1), window: "")
        let start = try #require(keyboard.readFeed(after: nil)).cursor
        for index in 2...4 { keyboard.append(batch([.asrDelta("e\(index)")], from: index), window: "") }
        let read = try #require(keyboard.readFeed(after: start))
        #expect(read.batches.map { $0.entries[0].seq } == [2, 3, 4])
        #expect(read.cursor.seq == 4)
    }

    @Test func overflowTurnsALaggingReaderIntoAResyncWithTheCurrentWindow() throws {
        let keyboard = link(capacity: 4)
        keyboard.append(batch([.asrDelta("e")], from: 1, version: 1), window: "w1")
        let start = try #require(keyboard.readFeed(after: nil)).cursor
        for index in 2...6 {
            keyboard.append(batch([.asrDelta("e")], from: index, version: index), window: "w\(index)")
        }
        // Capacity 4 keeps seq 3...6; the reader at seq 1 missed seq 2.
        let lagging = try #require(keyboard.readFeed(after: start))
        #expect(lagging.batches.count == 1)
        let resync = lagging.batches[0]
        #expect(resync.resync && resync.entries.isEmpty)
        #expect(resync.window == "w6")
        #expect(resync.version == FieldVersion(6))
        #expect(resync.session == session)
        #expect(lagging.cursor.seq == 6)

        // A reader that had seen seq 2 can still follow 3...6.
        let caughtUp = try #require(keyboard.readFeed(after: FeedCursor(writer: start.writer, seq: 2)))
        #expect(caughtUp.batches.count == 4 && caughtUp.batches.allSatisfy { !$0.resync })
    }

    @Test func theRingIsBoundedInTheAppGroup() throws {
        let backing = MemoryLinkStore()
        let keyboard = link(backing, capacity: 256)
        for index in 1...300 { keyboard.append(batch([.asrDelta("e")], from: index), window: "") }
        let ring = try #require(LinkStore(backing).read(FeedRing.self, forKey: LinkChannel.Key.feed))
        #expect(ring.slots.count == 256)
        #expect(ring.lastSeq == 300)
    }

    @Test func aRestartedWriterMakesAnOldCursorResync() throws {
        let backing = MemoryLinkStore()
        let before = link(backing)
        before.append(batch([.asrDelta("a")]), window: "old")
        let app = link(backing)
        let seen = try #require(app.readFeed(after: nil))

        let after = link(backing)  // the keyboard process restarted: a new writer, seq numbers start over
        after.append(batch([.asrDelta("b")], version: 9), window: "new")
        let read = try #require(app.readFeed(after: seen.cursor))
        #expect(read.batches.count == 1 && read.batches[0].resync)
        #expect(read.batches[0].window == "new")
        #expect(read.cursor.writer != seen.cursor.writer)
        #expect(read.cursor.seq == 1)
    }

    @Test func nothingWrittenYetReadsAsNil() {
        #expect(link().readFeed(after: nil) == nil)
    }

    // MARK: edits

    private func transaction(_ text: String) -> EditTransaction {
        EditTransaction(
            origin: .agent, owner: "agent", base: FieldVersion(3), steps: [EditStep(span: .at(0), text: text, expect: "")],
            caret: 2, coalesce: "k", session: session)
    }

    @Test func editsTravelToTheKeyboardOnceAndAreAcknowledged() throws {
        let backing = MemoryLinkStore()
        let notes = NoteLog()
        let app = link(backing, notes: notes)
        let keyboard = link(backing)
        let a = transaction("a"), b = transaction("b")
        app.sendEdits([a, b])
        #expect(notes.all == [LinkChannel.Note.edits])

        #expect(keyboard.takeEdits() == [a, b])
        #expect(keyboard.takeEdits().isEmpty)  // acknowledged

        let c = transaction("c")
        app.sendEdits([c])  // the app prunes what was acknowledged
        let stored = try #require(LinkStore(backing).read(EditsBox.self, forKey: LinkChannel.Key.edits))
        #expect(stored.edits.map(\.transaction) == [c])
        #expect(keyboard.takeEdits() == [c])
    }

    @Test func aRestartedAppSenderIsNotMistakenForAcknowledged() {
        let backing = MemoryLinkStore()
        let keyboard = link(backing)
        let first = link(backing)
        first.sendEdits([transaction("a")])
        #expect(keyboard.takeEdits().count == 1)

        let restarted = link(backing)  // numbering starts over under a new writer
        let b = transaction("b")
        restarted.sendEdits([b])
        #expect(keyboard.takeEdits() == [b])
    }

    @Test func unacknowledgedEditsAreBounded() throws {
        let backing = MemoryLinkStore()
        let app = link(backing, capacity: 4)
        app.sendEdits((1...6).map { transaction("t\($0)") })
        let kept = link(backing).takeEdits()
        #expect(kept.map { $0.steps[0].text } == ["t3", "t4", "t5", "t6"])
    }
}

@Suite struct FieldOffsetsTests {
    // "a👩‍👩‍👧b🇩🇪c": a=1 unit, family ZWJ sequence=8 units (1 Character), b=1, flag=4 units (1 Character), c=1.
    let text = "a\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}b\u{1F1E9}\u{1F1EA}c"

    @Test func characterOffsetsBecomeUTF16Offsets() {
        #expect(text.count == 5 && text.utf16.count == 15)
        let expected = [0, 1, 9, 10, 14, 15]
        for (character, units) in expected.enumerated() {
            #expect(FieldOffsets.utf16Offset(ofCharacter: character, in: text) == units)
        }
        #expect(FieldOffsets.utf16Offset(ofCharacter: 6, in: text) == nil)
        #expect(FieldOffsets.utf16Offset(ofCharacter: -1, in: text) == nil)
    }

    @Test func utf16OffsetsBecomeCharacterOffsetsOnlyOnBoundaries() {
        #expect(FieldOffsets.characterOffset(ofUTF16: 0, in: text) == 0)
        #expect(FieldOffsets.characterOffset(ofUTF16: 9, in: text) == 2)
        #expect(FieldOffsets.characterOffset(ofUTF16: 15, in: text) == 5)
        #expect(FieldOffsets.characterOffset(ofUTF16: 2, in: text) == nil)  // inside the surrogate pair
        #expect(FieldOffsets.characterOffset(ofUTF16: 4, in: text) == nil)  // inside the ZWJ sequence
        #expect(FieldOffsets.characterOffset(ofUTF16: 12, in: text) == nil)  // between the flag's regional indicators
        #expect(FieldOffsets.characterOffset(ofUTF16: 16, in: text) == nil)
    }

    @Test func aCharacterRangeBecomesASpan() {
        #expect(FieldOffsets.span(ofCharacters: 1..<3, in: text) == Span(location: 1, length: 9))
        #expect(FieldOffsets.span(ofCharacters: 4..<4, in: text) == Span.at(14))
        #expect(FieldOffsets.span(ofCharacters: 3..<9, in: text) == nil)
        #expect(FieldOffsets.characters(ofSpan: Span(location: 1, length: 9), in: text) == 1..<3)
        #expect(FieldOffsets.characters(ofSpan: Span(location: 2, length: 3), in: text) == nil)
    }

    @Test func decomposedAccentsCountAsOneCharacter() {
        let decomposed = "e\u{301}x"
        #expect(FieldOffsets.utf16Offset(ofCharacter: 1, in: decomposed) == 2)
        #expect(FieldOffsets.characterOffset(ofUTF16: 1, in: decomposed) == nil)
    }
}

@Suite struct HostStateFieldEditsTests {
    @Test func theFlagIsAbsentUnlessSetAndOldStatesStillDecode() throws {
        let backing = MemoryLinkStore()
        let store = LinkStore(backing)
        store.write(hostState(), forKey: LinkChannel.Key.host)
        let plainData = try #require(backing.data(forKey: LinkChannel.Key.host))
        let plain = try #require(JSONSerialization.jsonObject(with: plainData) as? [String: Any])
        #expect(plain["fieldEdits"] == nil)
        #expect(store.read(HostState.self, forKey: LinkChannel.Key.host)?.fieldEdits == nil)

        var on = hostState()
        on.fieldEdits = true
        store.write(on, forKey: LinkChannel.Key.host)
        let storedData = try #require(backing.data(forKey: LinkChannel.Key.host))
        let stored = try #require(JSONSerialization.jsonObject(with: storedData) as? [String: Any])
        #expect(stored["fieldEdits"] as? Bool == true)
        #expect(stored["v"] as? Int == 1)
        #expect(store.read(HostState.self, forKey: LinkChannel.Key.host)?.fieldEdits == true)
    }

    @Test func aStateWrittenBeforeTheFlagExistedDecodes() throws {
        let old = """
            {"v":1,"runID":"r","phase":"listening","target":"keyboard","committed":"a","volatile":"b","seq":3,\
            "beatAt":1000,"acceptsRemoteStart":false}
            """
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let state = try decoder.decode(HostState.self, from: Data(old.utf8))
            #expect(state.fieldEdits == nil && state.committed == "a")
        }
    }

    @MainActor @Test func aRunFreezesTheFlagWhenItStarts() {
        let link = HostLink(store: LinkStore(MemoryLinkStore()), post: { _ in })
        link.runStarted(id: "r", target: .keyboard, fieldEdits: true)
        #expect(link.state.fieldEdits == true)
    }
}

@Suite struct LinkChannelFeedKeysTests {
    @Test func theFeedAndEditsHaveTheirOwnKeysAndNotes() {
        #expect(LinkChannel.Key.feed == "link.feed")
        #expect(LinkChannel.Key.edits == "link.edits")
        #expect(LinkChannel.Note.feed.hasSuffix(".link.feed"))
        #expect(LinkChannel.Note.edits.hasSuffix(".link.edits"))
        #expect(LinkChannel.feedCapacity == 256)
    }
}
