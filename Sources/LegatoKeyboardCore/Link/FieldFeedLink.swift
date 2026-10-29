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
/// process instance that numbered the slots; a restart starts a new ring under a new writer.
struct FeedRing: Sendable, Hashable, Codable {
    var writer: UUID
    var lastSeq: Int
    /// The confirmed window after the newest batch, for readers that must resync.
    var window: String
    var slots: [FeedSlot]
}

struct NumberedEdit: Sendable, Hashable, Codable {
    var n: Int
    var transaction: EditTransaction
}

/// `link.edits`: the app's not yet acknowledged transactions, numbered under its writer instance.
struct EditsBox: Sendable, Hashable, Codable {
    var writer: UUID
    var edits: [NumberedEdit]
}

struct EditsAck: Sendable, Hashable, Codable {
    var writer: UUID
    var through: Int
}

/// The cross-process transport of the field edit queue on iOS. The keyboard owns the queue: it appends the
/// field's events (`link.feed`) and takes the app's edits (`link.edits`). The app reads the feed and sends
/// edits. Each key has one writer, so no read-modify-write races. Darwin notes only wake the other side.
public final class FieldFeedLink: Sendable {
    private struct State {
        var ring: FeedRing?
        var writer = UUID()
        var sentThrough = 0
        var outbox: [NumberedEdit] = []
    }

    private let store: LinkStore
    private let post: @Sendable (String) -> Void
    private let capacity: Int
    private let state = Mutex(State())

    public init(
        store: LinkStore, post: @escaping @Sendable (String) -> Void = { DarwinObserver.post($0) },
        capacity: Int = LinkChannel.feedCapacity
    ) {
        self.store = store
        self.post = post
        self.capacity = max(1, capacity)
    }

    // MARK: Feed (keyboard writes, app reads)

    /// Keyboard: adds one batch (one per host update). `window` is the confirmed window after it. The
    /// oldest batch is dropped beyond the capacity.
    public func append(_ batch: FeedBatch, window: String) {
        let ring = state.withLock { state -> FeedRing in
            var ring = state.ring ?? FeedRing(writer: state.writer, lastSeq: 0, window: window, slots: [])
            ring.lastSeq += 1
            ring.window = window
            ring.slots.append(FeedSlot(seq: ring.lastSeq, batch: batch))
            if ring.slots.count > capacity { ring.slots.removeFirst(ring.slots.count - capacity) }
            state.ring = ring
            return ring
        }
        store.write(ring, forKey: LinkChannel.Key.feed)
        post(LinkChannel.Note.feed)
    }

    /// App: the batches after `cursor`. Nil when the keyboard has written nothing. A reader with no cursor, one
    /// from another writer (the keyboard restarted) or one that fell behind the kept batches gets a single
    /// `resync` batch with the current window; one already at the newest batch gets none.
    public func readFeed(after cursor: FeedCursor?) -> FeedRead? {
        guard let ring = store.read(FeedRing.self, forKey: LinkChannel.Key.feed) else { return nil }
        let now = FeedCursor(writer: ring.writer, seq: ring.lastSeq)
        let firstSeq = ring.slots.first?.seq ?? ring.lastSeq + 1
        guard let cursor, cursor.writer == ring.writer, cursor.seq >= firstSeq - 1, cursor.seq <= ring.lastSeq
        else {
            guard let newest = ring.slots.last?.batch else { return FeedRead(batches: [], cursor: now) }
            let resync = FeedBatch(
                entries: [], version: newest.version, session: newest.session, resync: true, window: ring.window,
                through: newest.lastSeq)
            return FeedRead(batches: [resync], cursor: now)
        }
        return FeedRead(batches: ring.slots.filter { $0.seq > cursor.seq }.map(\.batch), cursor: now)
    }

    // MARK: Edits (app writes, keyboard reads and acknowledges)

    /// App: queues transactions for the keyboard; what the keyboard acknowledged is dropped.
    public func sendEdits(_ transactions: [EditTransaction]) {
        guard !transactions.isEmpty else { return }
        let ack = store.read(EditsAck.self, forKey: LinkChannel.Key.editsAck)
        let box = state.withLock { state -> EditsBox in
            if ack?.writer == state.writer { state.outbox.removeAll { $0.n <= ack?.through ?? 0 } }
            for transaction in transactions {
                state.sentThrough += 1
                state.outbox.append(NumberedEdit(n: state.sentThrough, transaction: transaction))
            }
            if state.outbox.count > capacity { state.outbox.removeFirst(state.outbox.count - capacity) }
            return EditsBox(writer: state.writer, edits: state.outbox)
        }
        store.write(box, forKey: LinkChannel.Key.edits)
        post(LinkChannel.Note.edits)
    }

    /// Keyboard: the transactions it has not taken yet, in order; it acknowledges them so they come once.
    public func takeEdits() -> [EditTransaction] {
        guard let box = store.read(EditsBox.self, forKey: LinkChannel.Key.edits) else { return [] }
        let ack = store.read(EditsAck.self, forKey: LinkChannel.Key.editsAck)
        let taken = ack?.writer == box.writer ? ack?.through ?? 0 : 0
        let fresh = box.edits.filter { $0.n > taken }
        guard let newest = fresh.last else { return [] }
        store.write(EditsAck(writer: box.writer, through: newest.n), forKey: LinkChannel.Key.editsAck)
        return fresh.map(\.transaction)
    }
}
