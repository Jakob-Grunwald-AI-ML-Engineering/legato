import Foundation
import Testing
@testable import LegatoFieldEdit
@testable import LegatoKeyboardCore

private func link(
    _ backing: MemoryLinkStore = MemoryLinkStore(), capacity: Int = 256, maxBytes: Int = 64 * 1024,
    notes: NoteLog = NoteLog()
) -> FieldFeedLink {
    FieldFeedLink(store: LinkStore(backing), post: { notes.add($0) }, capacity: capacity, maxBytes: maxBytes)
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

    @Test func theRingIsBoundedInBytesToo() throws {
        let backing = MemoryLinkStore()
        let keyboard = link(backing, maxBytes: 4_000)
        let big = String(repeating: "x", count: 900)
        for index in 1...10 { keyboard.append(batch([.asrDelta(big)], from: index), window: "w") }
        let data = try #require(backing.data(forKey: LinkChannel.Key.feed))
        #expect(data.count <= 4_000)
        let ring = try #require(LinkStore(backing).read(FeedRing.self, forKey: LinkChannel.Key.feed))
        #expect(ring.slots.count < 10 && ring.slots.last?.seq == 10 && ring.lastSeq == 10)
        // A reader at seq 1 fell off the front and resyncs.
        let read = try #require(keyboard.readFeed(after: FeedCursor(writer: ring.writer, seq: 1)))
        #expect(read.batches.first?.resync == true)
    }

    @Test func aSingleOversizedBatchBecomesAResyncMarker() throws {
        let backing = MemoryLinkStore()
        let keyboard = link(backing, maxBytes: 2_000)
        keyboard.append(batch([.asrDelta("a")], from: 1), window: "w")
        let start = try #require(keyboard.readFeed(after: nil)).cursor
        keyboard.append(batch([.asrDelta(String(repeating: "y", count: 5_000))], from: 2, version: 7), window: "w2")
        let data = try #require(backing.data(forKey: LinkChannel.Key.feed))
        #expect(data.count <= 2_000)
        let read = try #require(keyboard.readFeed(after: start))
        #expect(read.batches.count == 1 && read.batches[0].resync)
        #expect(read.batches[0].window == "w2" && read.batches[0].version == FieldVersion(7))
        #expect(read.cursor.seq == 2)
    }

    @Test func concurrentAppendsKeepEverySeqOnce() throws {
        let backing = MemoryLinkStore()
        let keyboard = link(backing)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in 0..<20 { keyboard.append(batch([.asrDelta("w\(worker)-\(index)")]), window: "") }
        }
        let ring = try #require(LinkStore(backing).read(FeedRing.self, forKey: LinkChannel.Key.feed))
        #expect(ring.lastSeq == 160)
        #expect(ring.slots.map(\.seq) == Array(1...160))
    }

    @Test func aNewRunResetsTheRing() throws {
        let backing = MemoryLinkStore()
        let keyboard = link(backing)
        keyboard.follow(runID: "r1")
        keyboard.append(batch([.asrDelta("old")]), window: "old window")
        let app = link(backing)
        let old = try #require(app.readFeed(after: nil, forRun: "r1"))
        #expect(app.readFeed(after: nil, forRun: "r2") == nil)  // r1's ring is not r2's

        keyboard.follow(runID: "r2")
        #expect(app.readFeed(after: nil, forRun: "r2") == nil)  // nothing yet, and no stale resync
        keyboard.follow(runID: "r2")  // following the same run again keeps what is there
        keyboard.append(batch([.asrDelta("new")], version: 4), window: "new window")
        let read = try #require(app.readFeed(after: old.cursor, forRun: "r2"))
        #expect(read.batches.count == 1 && read.batches[0].resync && read.batches[0].window == "new window")
        #expect(read.cursor.writer != old.cursor.writer && read.cursor.seq == 1)
    }

    // MARK: edits

    private func transaction(_ text: String) -> EditTransaction {
        EditTransaction(
            origin: .agent, owner: "agent", base: FieldVersion(3), steps: [EditStep(span: .at(0), text: text, expect: "")],
            caret: 2, coalesce: "k", session: session)
    }

    @Test func editsAreRedeliveredUntilAcknowledged() throws {
        let backing = MemoryLinkStore()
        let notes = NoteLog()
        let app = link(backing, notes: notes)
        let keyboard = link(backing)
        app.beginRun("r")
        let a = transaction("a"), b = transaction("b")
        #expect(app.sendEdits([a, b]) == 0)
        #expect(notes.all == [LinkChannel.Note.edits])

        let first = keyboard.takeEdits(forRun: "r")
        #expect(first.transactions == [a, b] && first.through == 2 && first.missed == 0)
        // The keyboard died before applying them: they come again.
        #expect(keyboard.takeEdits(forRun: "r").transactions == [a, b])

        keyboard.ack(through: first.through, writer: first.writer)
        #expect(keyboard.takeEdits(forRun: "r").transactions.isEmpty)
        keyboard.ack(through: 1, writer: first.writer)  // never moves back
        #expect(keyboard.takeEdits(forRun: "r").transactions.isEmpty)

        let c = transaction("c")
        app.sendEdits([c])  // the app prunes what was acknowledged
        let stored = try #require(LinkStore(backing).read(EditsBox.self, forKey: LinkChannel.Key.edits))
        #expect(stored.edits.map(\.transaction) == [c])
        #expect(keyboard.takeEdits(forRun: "r").transactions == [c])
    }

    @Test func aRestartedAppSenderIsNotMistakenForAcknowledged() {
        let backing = MemoryLinkStore()
        let keyboard = link(backing)
        let first = link(backing)
        first.beginRun("r")
        first.sendEdits([transaction("a")])
        let read = keyboard.takeEdits(forRun: "r")
        keyboard.ack(through: read.through, writer: read.writer)

        let restarted = link(backing)  // numbering starts over under a new writer
        restarted.beginRun("r")
        let b = transaction("b")
        restarted.sendEdits([b])
        #expect(keyboard.takeEdits(forRun: "r").transactions == [b])
    }

    @Test func editsOfAnotherRunAreNotDelivered() {
        let backing = MemoryLinkStore()
        let app = link(backing)
        let keyboard = link(backing)
        app.beginRun("r1")
        app.sendEdits([transaction("a")])
        #expect(keyboard.takeEdits(forRun: "r2").transactions.isEmpty)
        app.beginRun("r2")  // a new run drops what was queued for the old one
        #expect(keyboard.takeEdits(forRun: "r1").transactions.isEmpty)
        #expect(keyboard.takeEdits(forRun: "r2").transactions.isEmpty)
    }

    @Test func overflowOfUnacknowledgedEditsIsReported() {
        let backing = MemoryLinkStore()
        let app = link(backing, capacity: 4)
        app.beginRun("r")
        let dropped = app.sendEdits((1...6).map { transaction("t\($0)") })
        #expect(dropped == 2)
        let read = link(backing).takeEdits(forRun: "r")
        #expect(read.transactions.map { $0.steps[0].text } == ["t3", "t4", "t5", "t6"])
        #expect(read.missed == 2)
    }

    @Test func concurrentAcksOnlyMoveForward() throws {
        let backing = MemoryLinkStore()
        let app = link(backing)
        let keyboard = link(backing)
        app.beginRun("r")
        app.sendEdits((1...50).map { transaction("t\($0)") })
        let writer = keyboard.takeEdits(forRun: "r").writer
        DispatchQueue.concurrentPerform(iterations: 50) { keyboard.ack(through: $0 + 1, writer: writer) }
        #expect(keyboard.takeEdits(forRun: "r").transactions.isEmpty)
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
