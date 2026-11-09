import Foundation

// Instruction mode: the contract between the keyboard's magic key and the app's instruction runner.
//
// - keyboard -> app, `link.presence`: the magic toggle (`MagicToggle`) rides on `KeyboardPresence`. Speech is tagged
//   with the mode active when it was spoken; turning the toggle off (a latch tapped off, a hold released) runs the
//   instruction. Nothing runs on its own.
// - app -> keyboard, `link.instruction`: `InstructionStrip`, what the strip shows (transcript, reading, running,
//   result with undo, error).
// - keyboard -> app, `link.instruction.intent.<id>`: `InstructionIntent` (run, undo, accept, dismiss); the app drains them.
// - app -> keyboard, `link.read` / keyboard -> app, `link.read.ack`: `FieldReadRequest` / `FieldReadReply`, the field's
//   text around the cursor, read (and walked, when it must be) by the keyboard.
// - app -> keyboard, `link.instruction.edit` / keyboard -> app, `link.instruction.edit.ack`: `ScopedEdit` /
//   `ScopedEditAck`, the result landing as word-level edits of exactly the text the model was shown.
//
// Every value carries field text, so each side removes what it read once it is done with it.

/// The magic key. `latched`: tapped on, stays on until tapped again. `held`: on while the finger is down.
public enum MagicToggle: String, Codable, Sendable, Equatable, CaseIterable {
    case off, latched, held
    /// Speech is an instruction.
    public var isOn: Bool { self != .off }
}

/// app -> keyboard (`link.instruction`): the instruction strip. Republished on every change (`revision` counts up).
public struct InstructionStrip: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable, Equatable {
        /// Nothing to show: the strip is the word row.
        case idle
        /// Instruction mode is on: `transcript` is what was said so far (final words plus the live tail).
        case listening
        /// The keyboard reads the field for the instruction (the cursor visibly moves).
        case reading
        /// The model works on it.
        case running
        /// The result is in the field: offer Undo (and Accept) until the next keystroke.
        case result
        /// Undo restored the text the instruction changed.
        case undone
        /// Nothing changed in the field: `message` says why. Run again with `.run`, or `.dismiss`.
        case failed
    }
    public var revision: Int
    /// The instruction this strip is about; nil while idle.
    public var instructionID: String?
    public var phase: Phase
    public var transcript: String
    /// The part of the field the result replaced (`InstructionScopeName` raw value), on `result` and `undone`.
    public var scope: String?
    /// A short status or error line for the strip ("Rewrote the paragraph.", "The text changed, so nothing was edited.").
    public var message: String?
    public var canUndo: Bool
    /// On `failed`: running the same instruction again could help (false for "nothing to change", "no text"; nil: true).
    public var canRetry: Bool?
    public init(revision: Int = 0, instructionID: String? = nil, phase: Phase = .idle, transcript: String = "",
                scope: String? = nil, message: String? = nil, canUndo: Bool = false, canRetry: Bool? = nil) {
        self.revision = revision; self.instructionID = instructionID; self.phase = phase; self.transcript = transcript
        self.scope = scope; self.message = message; self.canUndo = canUndo; self.canRetry = canRetry
    }
}

/// keyboard -> app (`link.instruction.intent.<id>`): what the user chose on the strip.
public struct InstructionIntent: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable, Equatable {
        /// Run the held instruction now (again after a failure). Turning the toggle off runs it without this.
        case run
        /// Restore the text the last instruction replaced.
        case undo
        /// Keep the result; the strip goes back to the word row (the next keystroke means the same).
        case accept
        /// Drop what the strip shows: the held instruction, an error, or a running instruction (cancelled).
        case dismiss
    }
    public var id: String
    public var action: Action
    /// The strip's instruction the user acted on; an intent for an older one is ignored.
    public var instructionID: String?
    public var at: Date
    public init(id: String = UUID().uuidString, action: Action, instructionID: String?, at: Date = Date()) {
        self.id = id; self.action = action; self.instructionID = instructionID; self.at = at
    }
}

/// How a read above the cursor ended.
public enum FieldStop: String, Codable, Sendable, Equatable {
    /// The field's start: nothing above.
    case start
    /// A quote header ("On … wrote:", "-----Original Message-----") or quoted lines: the text above is someone else's.
    case quote
    /// A signature delimiter (`-- `).
    case signature
    /// The read reached `FieldReader.cap` characters.
    case cap
    /// One block (`read_more`) was read; more may follow.
    case block
    /// Not read (no walk): the text above is unknown.
    case unread
}

/// app -> keyboard (`link.read`): read the field for instruction `instructionID`. The keyboard answers on `link.read.ack`
/// (a `reading` reply at once when it walks, then the result) and removes the request once read.
public struct FieldReadRequest: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        /// The structural prefetch: selection, the session's text, the cursor paragraph, and above back to the nearest
        /// structural stop or the cap. Walks only when no session text exists and the field shows more than is known.
        case context
        /// `context` without moving the cursor (no walk): the instruction is about a selection, which a walk would
        /// collapse in a host that does not report it (Safari gives no `selectedText`).
        case contextInPlace
        /// One more block above what was read (`read_more`): a paragraph group of at most `FieldReader.blockLimit`.
        case more
        /// Everything above and then below what was read, up to the cap in all.
        case toCap
    }
    public var id: String
    public var instructionID: String
    public var kind: Kind
    public var at: Date
    public init(id: String = UUID().uuidString, instructionID: String, kind: Kind, at: Date = Date()) {
        self.id = id; self.instructionID = instructionID; self.kind = kind; self.at = at
    }
}

/// keyboard -> app (`link.read.ack`): the field around the cursor. `above` ends at the cursor, `below` starts there.
public struct FieldReadReply: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable, Equatable {
        /// The keyboard walks the field (the result follows; the app waits up to `LinkChannel.readTimeout`).
        case reading
        case done
        /// The read failed (a window pair that did not stitch, the field changed, no field): nothing partial is sent.
        case failed
    }
    public var id: String
    public var state: State
    /// Verified text above the cursor, from `stop` (or what was read) down to the cursor.
    public var above: String
    /// From the cursor down: the host's window after it, or what a downward read verified (to `stopBelow`).
    public var below: String
    /// The selected text; with a selection nothing is walked and only the selection can be edited.
    public var selection: String?
    /// How many characters at the end of `above` Legato itself typed in this keyboard session (0: none known).
    public var sessionLength: Int
    public var stop: FieldStop
    /// How the text below ended: `.start` for the field's end, `.quote`/`.signature`/`.cap` after a downward read;
    /// nil (or `.unread`) when only the host's window is known.
    public var stopBelow: FieldStop?
    /// Text continues above `above` / below `below` that was not read.
    public var moreAbove: Bool
    public var moreBelow: Bool
    /// Why the read failed (no field text).
    public var error: String?
    /// The failure lies in how this app shows its text (its windows never agreed): reading again cannot help.
    public var lasting: Bool?
    public var documentID: String?
    public init(id: String, state: State, above: String = "", below: String = "", selection: String? = nil, sessionLength: Int = 0,
                stop: FieldStop = .unread, stopBelow: FieldStop? = nil, moreAbove: Bool = false, moreBelow: Bool = false, error: String? = nil,
                documentID: String? = nil) {
        self.id = id; self.state = state; self.above = above; self.below = below; self.selection = selection
        self.sessionLength = sessionLength; self.stop = stop; self.stopBelow = stopBelow; self.moreAbove = moreAbove; self.moreBelow = moreBelow
        self.error = error; self.documentID = documentID
    }
}

/// app -> keyboard (`link.instruction.edit`): replace the scope with `target`. The scope is exactly the text the model
/// was shown: `before` ends at the cursor, `after` starts there; with `selected` set the selection is the scope. The
/// keyboard checks that the field still shows it (the windows around the cursor agree), word-diffs `target` into it
/// (`ShadowEditPlanner`), and answers on `link.instruction.edit.ack`. Undo is the same edit the other way round.
public struct ScopedEdit: Codable, Sendable, Equatable {
    public var id: String
    public var instructionID: String
    public var documentID: String?
    public var before: String
    public var after: String
    public var selected: String?
    public var target: String
    public var at: Date
    public init(id: String = UUID().uuidString, instructionID: String, documentID: String?, before: String, after: String,
                selected: String? = nil, target: String, at: Date = Date()) {
        self.id = id; self.instructionID = instructionID; self.documentID = documentID
        self.before = before; self.after = after; self.selected = selected; self.target = target; self.at = at
    }
    /// The scope as the field shows it now.
    public var scopeText: String { selected ?? (before + after) }
}

/// keyboard -> app (`link.instruction.edit.ack`).
public struct ScopedEditAck: Codable, Sendable, Equatable {
    public var id: String
    public var applied: Bool
    /// Where the cursor ended, in UTF-16 units into `target` (the undo splits the target there), or into `partial`.
    public var cursor: Int?
    /// Why nothing (or not all) was edited (no field text).
    public var reason: String?
    /// Not applied, but stopped partway (the field did not keep up, `ScopedEditQueue`): the scope's text as the field
    /// shows it now, so an undo can still put the original back. Nil with `applied` false: the field is as it was, or
    /// its text is unknown (`reason` says which).
    public var partial: String?
    /// Ops went out and the edit stopped before the end; without `partial` the field's text is unknown.
    public var stopped: Bool?
    public init(id: String, applied: Bool, cursor: Int? = nil, reason: String? = nil, partial: String? = nil, stopped: Bool? = nil) {
        self.id = id; self.applied = applied; self.cursor = cursor; self.reason = reason; self.partial = partial; self.stopped = stopped
    }
}

/// Both ends of the instruction link over one `LinkStore`.
public struct InstructionLink: Sendable {
    public let store: LinkStore
    public init(store: LinkStore) { self.store = store }

    public func publish(_ strip: InstructionStrip) { store.write(strip, forKey: LinkChannel.Key.instruction) }
    public func strip() -> InstructionStrip? { store.read(InstructionStrip.self, forKey: LinkChannel.Key.instruction) }
    public func clearStrip() { store.remove(forKey: LinkChannel.Key.instruction) }

    public func send(_ intent: InstructionIntent) { store.write(intent, forKey: LinkChannel.Key.instructionIntentPrefix + intent.id) }
    /// Every queued intent, oldest first; each is removed once read.
    public func drainIntents() -> [InstructionIntent] {
        store.keys(withPrefix: LinkChannel.Key.instructionIntentPrefix).compactMap { key in
            defer { store.remove(forKey: key) }
            return store.read(InstructionIntent.self, forKey: key)
        }.sorted { $0.at < $1.at }
    }

    public func request(_ request: FieldReadRequest) { store.write(request, forKey: LinkChannel.Key.read) }
    /// The pending read request, removed as it is taken.
    public func takeRequest() -> FieldReadRequest? {
        guard let request = store.read(FieldReadRequest.self, forKey: LinkChannel.Key.read) else { return nil }
        store.remove(forKey: LinkChannel.Key.read)
        return request
    }
    public func reply(_ reply: FieldReadReply) { store.write(reply, forKey: LinkChannel.Key.readAck) }
    /// The reply to `id` when one is stored; a finished reply is removed as it is taken.
    public func takeReply(id: String) -> FieldReadReply? {
        guard let reply = store.read(FieldReadReply.self, forKey: LinkChannel.Key.readAck), reply.id == id else { return nil }
        if reply.state != .reading { store.remove(forKey: LinkChannel.Key.readAck) }
        return reply
    }

    public func publish(_ edit: ScopedEdit) { store.write(edit, forKey: LinkChannel.Key.instructionEdit) }
    public func takeEdit() -> ScopedEdit? {
        guard let edit = store.read(ScopedEdit.self, forKey: LinkChannel.Key.instructionEdit) else { return nil }
        store.remove(forKey: LinkChannel.Key.instructionEdit)
        return edit
    }
    public func acknowledge(_ ack: ScopedEditAck) { store.write(ack, forKey: LinkChannel.Key.instructionEditAck) }
    public func takeAck(id: String) -> ScopedEditAck? {
        guard let ack = store.read(ScopedEditAck.self, forKey: LinkChannel.Key.instructionEditAck), ack.id == id else { return nil }
        store.remove(forKey: LinkChannel.Key.instructionEditAck)
        return ack
    }

    /// Removes every instruction value (the keyboard session ended, or the user deleted history).
    public func clearAll() {
        for key in [LinkChannel.Key.instruction, LinkChannel.Key.read, LinkChannel.Key.readAck,
                    LinkChannel.Key.instructionEdit, LinkChannel.Key.instructionEditAck] { store.remove(forKey: key) }
        for key in store.keys(withPrefix: LinkChannel.Key.instructionIntentPrefix) { store.remove(forKey: key) }
    }
}
