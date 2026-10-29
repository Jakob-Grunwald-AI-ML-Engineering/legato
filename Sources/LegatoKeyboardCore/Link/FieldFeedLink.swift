import Foundation
import LegatoFieldEdit
import Synchronization

/// Where a reader of the feed is: the writer instance it read from and the newest sequence number it saw.
public struct FeedCursor: Sendable, Hashable, Codable {
    public var writer: UUID
    public var seq: Int

    public init(writer: UUID, seq: Int) {
        self.writer = writer
        self.seq = seq
    }
}

/// What a read of the feed returns: the batches to apply in order, and the cursor to pass next time.
public struct FeedRead: Sendable, Hashable {
    public var batches: [FeedBatch]
    public var cursor: FeedCursor
}

/// One kept batch with its ring sequence number (not the queue's entry numbers inside the batch).
struct FeedSlot: Sendable, Hashable, Codable {
    var seq: Int
    var batch: FeedBatch
}

/// `link.feed`: the keyboard's field events as batches in a bounded ring. `writer` identifies the keyboard
/// process instance (and run) that numbered the slots; a restart or a new run starts a new ring.
struct FeedRing: Sendable, Hashable, Codable {
    var writer: UUID
    /// The run the keyboard was following when it wrote this ring.
    var runID: String?
    var lastSeq: Int
    /// The confirmed window after the newest batch, for readers that must resync.
    var window: String
    var slots: [FeedSlot]
}

struct NumberedEdit: Sendable, Hashable, Codable {
    var n: Int
    var transaction: EditTransaction
}

/// `link.edits`: the app's not yet acknowledged transactions for one run, numbered under its writer instance.
struct EditsBox: Sendable, Hashable, Codable {
    var writer: UUID
    var runID: String?
    var edits: [NumberedEdit]
}

struct EditsAck: Sendable, Hashable, Codable {
    var writer: UUID
    var through: Int
}

/// What the keyboard took from `link.edits`: unacknowledged transactions in order.
public struct EditsRead: Sendable, Hashable {
    public var transactions: [EditTransaction]
    /// The sender instance; pass it back to ``FieldFeedLink/ack(through:writer:)``.
    public var writer: UUID
    /// The number of the last transaction read; acknowledge it once they are applied.
    public var through: Int
    /// Transactions the app sent that were dropped before the keyboard took them (more were pending than
    /// the link keeps): a gap the sources must re-plan around.
    public var missed: Int

    static let empty = EditsRead(transactions: [], writer: UUID(), through: 0, missed: 0)
}

/// The cross-process transport of the field edit queue on iOS. The keyboard owns the queue: it appends the
/// field's events (`link.feed`) and takes the app's edits (`link.edits`). The app reads the feed and sends
/// edits. Each key has one writer, so there are no cross-process read-modify-write races; within a process
/// every store access runs under one lock. Darwin notes only wake the other side: a reader that finds nothing
/// (or a value that does not decode yet) just waits for the next note and re-reads.
///
/// Delivery of edits is at-least-once: `takeEdits` does not acknowledge, so edits come again after a keyboard
/// crash until `ack(through:writer:)`. The executor must dedupe by ``EditTransaction/id`` and reject other
/// ``EditTransaction/session``s (a restarted queue's versions mean nothing to an old transaction).
public final class FieldFeedLink: Sendable {
    private struct State {
        var ring: FeedRing?
        var writer = UUID()
        var runID: String?
        var sentThrough = 0
        var outbox: [NumberedEdit] = []
        var editsRun: String?
        /// The keyboard stopped following (the app scrubbed the link): batches are not written until the next run.
        var stopped = false
        /// The encoded size of each kept slot, in ring order: the ring is encoded once per append.
        var slotBytes: [Int] = []
    }

    private let store: LinkStore
    private let post: @Sendable (String) -> Void
    private let capacity: Int
    private let maxBytes: Int
    private let state = Mutex(State())

    public init(
        store: LinkStore, post: @escaping @Sendable (String) -> Void = { DarwinObserver.post($0) },
        capacity: Int = LinkChannel.feedCapacity, maxBytes: Int = LinkChannel.feedMaxBytes
    ) {
        self.store = store
        self.post = post
        self.capacity = max(1, capacity)
        self.maxBytes = maxBytes
    }

    // MARK: Feed (keyboard writes, app reads)

    /// Keyboard: starts following `runID`. A different run than the one followed drops the ring (a new writer
    /// id, so every reader resyncs) and the previous run's edit acknowledgement.
    public func follow(runID: String) {
        state.withLock { state in
            state.stopped = false
            guard state.runID != runID else { return }
            state.runID = runID
            state.writer = UUID()
            state.ring = nil
            state.slotBytes = []
            store.remove(forKey: LinkChannel.Key.feed)
            store.remove(forKey: LinkChannel.Key.editsAck)
        }
    }

    /// Keyboard: the run's link is gone (the app scrubbed it): the ring is dropped and nothing is written again
    /// until ``follow(runID:)``, so a batch still on its way does not bring the field's text back.
    public func stopFollowing() {
        state.withLock { state in
            state.stopped = true
            state.runID = nil
            state.ring = nil
            state.slotBytes = []
            store.remove(forKey: LinkChannel.Key.feed)
        }
    }

    /// Keyboard: adds one batch (one per host update). `window` is the confirmed window after it. The oldest
    /// batches are dropped beyond the capacity and the byte budget; a single batch over the budget is kept as a
    /// `resync` marker (readers rebuild from `window`).
    public func append(_ batch: FeedBatch, window: String) {
        let written = state.withLock { state -> Bool in
            guard !state.stopped else { return false }
            var ring = state.ring ?? FeedRing(writer: state.writer, runID: state.runID, lastSeq: 0, window: window, slots: [])
            if state.ring == nil { state.slotBytes = [] }
            ring.lastSeq += 1
            ring.window = window
            let slot = FeedSlot(seq: ring.lastSeq, batch: batch)
            ring.slots.append(slot)
            state.slotBytes.append(store.encoded(slot)?.count ?? 0)
            if ring.slots.count > capacity {
                ring.slots.removeFirst(ring.slots.count - capacity)
                state.slotBytes.removeFirst(state.slotBytes.count - ring.slots.count)
            }
            // The oldest slots go by their known sizes (the ring is encoded once, not once per dropped slot): the
            // slots, a comma between each, and the rest of the ring (its window, at most twice its UTF-8 when escaped).
            let overhead = 256 + 2 * window.utf8.count
            var total = state.slotBytes.reduce(0, +) + state.slotBytes.count + overhead
            while total > maxBytes, ring.slots.count > 1 {
                ring.slots.removeFirst()
                total -= state.slotBytes.removeFirst() + 1
            }
            var data = store.encoded(ring)
            while let size = data?.count, size > maxBytes, ring.slots.count > 1 {
                ring.slots.removeFirst()
                state.slotBytes.removeFirst()
                data = store.encoded(ring)
            }
            if let size = data?.count, size > maxBytes, let only = ring.slots.first {
                ring.slots[0].batch = FeedBatch(
                    entries: [], version: only.batch.version, session: only.batch.session, resync: true, window: window,
                    through: only.batch.lastSeq ?? 0)
                data = store.encoded(ring)
            }
            state.ring = ring
            if let data { store.write(encoded: data, forKey: LinkChannel.Key.feed) }
            return true
        }
        if written { post(LinkChannel.Note.feed) }
    }

    /// App: the batches after `cursor`. Nil when the keyboard has written nothing (for `runID`, when given: a
    /// ring of another run is not this run's). A reader with no cursor, one from another writer (the keyboard
    /// restarted or began a new run) or one that fell behind the kept batches gets a single `resync` batch
    /// with the current window; one already at the newest batch gets none. Nil or stale: wait for the next note.
    public func readFeed(after cursor: FeedCursor?, forRun runID: String? = nil) -> FeedRead? {
        guard let ring = store.read(FeedRing.self, forKey: LinkChannel.Key.feed) else { return nil }
        if let runID, ring.runID != runID { return nil }
        let now = FeedCursor(writer: ring.writer, seq: ring.lastSeq)
        let firstSeq = ring.slots.first?.seq ?? ring.lastSeq + 1
        guard let cursor, cursor.writer == ring.writer, cursor.seq >= firstSeq - 1, cursor.seq <= ring.lastSeq
        else {
            guard let newest = ring.slots.last?.batch else { return FeedRead(batches: [], cursor: now) }
            let resync = FeedBatch(
                entries: [], version: newest.version, session: newest.session, resync: true, window: ring.window,
                through: newest.lastSeq ?? 0)
            return FeedRead(batches: [resync], cursor: now)
        }
        return FeedRead(batches: ring.slots.filter { $0.seq > cursor.seq }.map(\.batch), cursor: now)
    }

    /// App: the first read of a run, by a reader with no cursor yet. While the ring still holds its first batch
    /// (nothing was dropped) every batch since the keyboard began following `runID` is returned, so the reader
    /// learns who wrote which text (the run's own text is told from the user's only by its `applied` events);
    /// otherwise, as ``readFeed(after:forRun:)`` with no cursor, a `resync`. Nil while nothing was written for it.
    public func readFeedFromStart(forRun runID: String) -> FeedRead? {
        guard let ring = store.read(FeedRing.self, forKey: LinkChannel.Key.feed), ring.runID == runID else { return nil }
        guard ring.slots.first?.seq == 1 else { return readFeed(after: nil, forRun: runID) }
        return FeedRead(batches: ring.slots.map(\.batch), cursor: FeedCursor(writer: ring.writer, seq: ring.lastSeq))
    }

    // MARK: Edits (app writes, keyboard reads and acknowledges)

    /// App: starts sending edits for `runID`; what was queued for an earlier run is dropped.
    public func beginRun(_ runID: String) {
        state.withLock { state in
            state.writer = UUID()
            state.editsRun = runID
            state.sentThrough = 0
            state.outbox = []
            store.remove(forKey: LinkChannel.Key.edits)
        }
    }

    /// App: the run's stop is over: nothing more is sent for it (its link is about to be scrubbed).
    public func endRun() {
        state.withLock { state in
            state.editsRun = nil
            state.outbox = []
        }
    }

    /// App: queues transactions for the keyboard (of the run given to `beginRun`); what the keyboard
    /// acknowledged is dropped. Returns how many unacknowledged edits fell off the front because more than the
    /// capacity were pending (the keyboard sees them as `EditsRead.missed`).
    @discardableResult
    public func sendEdits(_ transactions: [EditTransaction]) -> Int {
        guard !transactions.isEmpty else { return 0 }
        let dropped = state.withLock { state -> Int? in
            guard state.editsRun != nil else { return nil }
            let ack = store.read(EditsAck.self, forKey: LinkChannel.Key.editsAck)
            if ack?.writer == state.writer { state.outbox.removeAll { $0.n <= ack?.through ?? 0 } }
            for transaction in transactions {
                state.sentThrough += 1
                state.outbox.append(NumberedEdit(n: state.sentThrough, transaction: transaction))
            }
            let dropped = max(0, state.outbox.count - capacity)
            if dropped > 0 { state.outbox.removeFirst(dropped) }
            store.write(EditsBox(writer: state.writer, runID: state.editsRun, edits: state.outbox), forKey: LinkChannel.Key.edits)
            return dropped
        }
        guard let dropped else { return 0 }
        post(LinkChannel.Note.edits)
        return dropped
    }

    /// Keyboard: the transactions of run `runID` that it has not acknowledged, in order. Does not acknowledge.
    public func takeEdits(forRun runID: String) -> EditsRead {
        state.withLock { _ in
            guard let box = store.read(EditsBox.self, forKey: LinkChannel.Key.edits), box.runID == runID else { return .empty }
            let ack = store.read(EditsAck.self, forKey: LinkChannel.Key.editsAck)
            let taken = ack?.writer == box.writer ? ack?.through ?? 0 : 0
            let fresh = box.edits.filter { $0.n > taken }
            guard let first = fresh.first, let last = fresh.last else { return .empty }
            return EditsRead(
                transactions: fresh.map(\.transaction), writer: box.writer, through: last.n, missed: first.n - taken - 1)
        }
    }

    /// Keyboard: the transactions up to `n` (from the same ``EditsRead``) were applied; they are not delivered
    /// again. Never moves back.
    public func ack(through n: Int, writer: UUID) {
        state.withLock { _ in
            if let current = store.read(EditsAck.self, forKey: LinkChannel.Key.editsAck), current.writer == writer,
                current.through >= n
            { return }
            store.write(EditsAck(writer: writer, through: n), forKey: LinkChannel.Key.editsAck)
        }
    }
}
