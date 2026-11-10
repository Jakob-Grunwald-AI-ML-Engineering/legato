#if os(macOS)
import Foundation
import LegatoAgent
import LegatoCore
import LegatoKeyboardCore
import LegatoMac

/// AX-backed hosts supply a TextTarget. All mutations own an exact readable span and caret;
/// a lost target is never rebound while words or a model result are in flight.
@MainActor public final class MacFieldEditor: InstructionField {
    private let capture: @MainActor () -> FocusedField
    public var report: @MainActor (String) -> Void = { _ in }
    public var recover: @MainActor (String) -> Void = { _ in }
    /// Only an initially unreadable, nonsecure field may receive a guarded final-text fallback.
    public var fallback: (@MainActor (String) async -> Void)?
    private var fallbackAllowed = false
    private var fallbackRuns: Set<String> = []
    private var fallbackTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var pendingLive: LiveDictationSnapshot?
    private var seenRunIDs: Set<String> = []
    private var retiredRunIDs: Set<String> = []
    private var target: (any TextTarget)?
    private var documentID = UUID().uuidString
    private var coordinator = FieldEditCoordinator()
    private var readRevision: FieldRevision?
    private var activeInstructionID: String?
    private var runVersions: [String: Int] = [:]
    private var runID: String?
    private var start = 0
    private var written = ""
    private var expected = UTF16Range(location: 0, length: 0)
    private var original = ""
    private var replacedOriginal = ""
    private var blocked = false
    private var sessionSpan: (range: UTF16Range, text: String)?
    private var readSelection: UTF16Range?
    private var instructionCursor: UTF16Range?
    private var readText: String?
    private var readRange: UTF16Range?
    public init(capture: @escaping @MainActor () -> FocusedField) { self.capture = capture }

    public func begin() {
        liveTask?.cancel(); liveTask = nil; pendingLive = nil
        fallbackTask?.cancel(); fallbackTask = nil
        fallbackAllowed = false; fallbackRuns = []
        retiredRunIDs.formUnion(seenRunIDs); seenRunIDs = []; runVersions = [:]
        coordinator = FieldEditCoordinator(); readRevision = nil; activeInstructionID = nil
        target = nil; runID = nil; written = ""; blocked = false; sessionSpan = nil
        readSelection = nil; readText = nil; instructionCursor = nil
        documentID = UUID().uuidString
        switch capture() {
        case .target(let value):
            target = value
            if let selection = try? value.selectedRange() { expected = selection } else { blocked = true }
        case .secure: blocked = true; report("Secure field: dictation will be copied. Magic cannot edit it.")
        case .none: blocked = true; fallbackAllowed = true; report("Live editing is unavailable here. Dictation sends when finished; Magic needs readable text.")
        }
    }

    /// A Magic start binds the field now, even when no dictation preceded it. Keep the verified
    /// dictated span only while the same field still owns focus.
    /// Real user input relinquishes every in-flight dictation/model edit, even if its caret
    /// later returns to the same offset. A new explicit Magic/dictation start binds afresh.
    public func relinquish() { blocked = true; fallbackAllowed = false; coordinator.preempt() }
    public func cancel(instructionID: String) {
        guard activeInstructionID == instructionID else { return }
        coordinator.preempt(); activeInstructionID = nil
        documentID = UUID().uuidString; readRevision = nil
        readSelection = nil; readText = nil; readRange = nil; instructionCursor = nil
    }
    public func focusChanged() { if target?.isFocused() == false { relinquish() } }

    public func beginInstruction() {
        flushLive()
        let cursorChanged = target.flatMap { try? $0.selectedRange() } != expected
        if target?.isFocused() != true || blocked || cursorChanged {
            // An old pipeline cleanup may finish after Magic binds a different field/selection.
            // Its run remains barred even though the new instruction has explicit fresh ownership.
            let retired = retiredRunIDs.union(seenRunIDs)
            begin()
            retiredRunIDs = retired
        }
        // An explicit new Magic start owns a fresh result namespace, including in the same field.
        retiredRunIDs.formUnion(seenRunIDs)
        documentID = UUID().uuidString
        coordinator.preempt(); readRevision = nil; activeInstructionID = nil
        instructionCursor = try? target?.selectedRange()
        if let instructionCursor { expected = instructionCursor }
        readSelection = nil; readText = nil
    }

    /// Browser accessibility updates are expensive and partials can arrive faster than they can
    /// paint. Coalesce pending hypotheses; every final and cleanup still reaches the same owner.
    public func enqueueLive(_ snapshot: LiveDictationSnapshot?) {
        guard let snapshot, !retiredRunIDs.contains(snapshot.runID) else { return }
        seenRunIDs.insert(snapshot.runID)
        if let pending = pendingLive, pending.runID == snapshot.runID, pending.version >= snapshot.version { return }
        pendingLive = snapshot
        guard liveTask == nil else { return }
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self else { return }
                guard let next = self.pendingLive else { self.liveTask = nil; return }
                self.pendingLive = nil
                self.applyLive(next)
                if self.pendingLive == nil { self.liveTask = nil; return }
            }
        }
    }
    private func flushLive() {
        liveTask?.cancel(); liveTask = nil
        let next = pendingLive; pendingLive = nil
        applyLive(next)
    }

    public func applyLive(_ snapshot: LiveDictationSnapshot?) {
        guard let snapshot else { return }
        seenRunIDs.insert(snapshot.runID)
        guard !retiredRunIDs.contains(snapshot.runID),
              snapshot.version > (runVersions[snapshot.runID] ?? -1) else { return }
        runVersions[snapshot.runID] = snapshot.version
        let body = snapshot.segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        guard !blocked, let target, target.isFocused() else {
            blocked = true
            if snapshot.complete, !body.isEmpty {
                if fallbackAllowed, let fallback {
                    guard fallbackRuns.insert(snapshot.runID).inserted else { return }
                    let previous = fallbackTask
                    let id = documentID
                    fallbackTask = Task { [weak self] in
                        await previous?.value
                        guard !Task.isCancelled, let self, self.documentID == id else { return }
                        if self.fallbackAllowed { await fallback(body) }
                        else { self.recover(body); self.report("Dictation copied: the target changed. Paste with ⌘V.") }
                    }
                } else { recover(body); report("Dictation copied. The field is unavailable or changed; paste with ⌘V.") }
            }
            return
        }
        do {
            if runID != snapshot.runID {
                if let runID { retiredRunIDs.insert(runID) }
                runID = snapshot.runID
                guard try target.selectedRange() == expected else { throw Ownership.changed }
                start = expected.location
                original = try target.text(in: expected); replacedOriginal = original; written = ""
            }
            guard try target.selectedRange() == expected,
                  try target.text(in: .init(location: start, length: written.isEmpty ? original.utf16.count : written.utf16.count)) == (written.isEmpty ? original : written)
            else { throw Ownership.changed }
            var text = body
            if !text.isEmpty, start > 0,
               let preceding = try target.text(in: .init(location: start - 1, length: 1)).last,
               !preceding.isWhitespace, !"([{\"'“‘„«¿¡".contains(preceding),
               text.first.map({ !$0.isWhitespace && !".,;:!?)]}%".contains($0) }) == true { text = " " + text }
            guard text != written else { return }
            // Empty nonfinal snapshots must not erase the user's initial selection.
            if written.isEmpty && text.isEmpty { return }
            let old = written.isEmpty ? original : written
            // Preserve the stable prefix. Replace the changing tail in one operation so
            // browser hosts do not select a middle word then jump the caret to the end.
            let a = Array(old), b = Array(text)
            var prefix = 0
            while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
            let lead = String(a.prefix(prefix)).utf16.count
            let removed = String(a[prefix...]).utf16.count
            let replacement = String(b[prefix...])
            try replaceOwned(target, range: .init(location: start + lead, length: removed), text: replacement,
                             owner: .dictation, id: UUID().uuidString)
            // replaceOwned verified the tail and its natural final caret together.
            let end = UTF16Range(location: start + text.utf16.count, length: 0)
            written = text; expected = end; original = ""
            if instructionCursor != nil, readSelection == nil { instructionCursor = end }
            sessionSpan = (.init(location: start, length: text.utf16.count), text)
        } catch {
            blocked = true
            if snapshot.complete { recover(body) }
            report("The field or cursor changed. Dictation stopped editing it; finished text will be copied.")
        }
    }

    public func read(_ kind: FieldReadRequest.Kind, instructionID: String, reading: @escaping @MainActor () -> Void) async throws -> FieldReadReply {
        guard !blocked, let target, target.isFocused(), let bound = instructionCursor,
              let selection = try? target.selectedRange(), selection == bound else {
            throw InstructionFailure.unreadable("The field or cursor changed. Nothing was edited.")
        }
        let length = try target.textLength()
        guard selection.location >= 0, selection.end <= length else { throw Ownership.changed }
        let cap = FieldReader.defaultCap
        guard selection.length <= cap else { throw InstructionFailure.unreadable("The selection is too long. Select a smaller passage.") }
        let room = cap - selection.length
        let afterLength = min(length - selection.end, room / 3)
        let beforeLength = min(selection.location, room - afterLength)
        let lower = selection.location - beforeLength
        let upper = min(length, selection.end + room - beforeLength)
        let range = UTF16Range(location: lower, length: upper - lower)
        let snapshot = try target.text(in: range)
        if let readText, readText != snapshot { throw InstructionFailure.unreadable("The text changed while Magic was reading it.") }
        guard snapshot.utf16.count == range.length, try target.selectedRange() == selection else { throw Ownership.changed }
        // Derive all model context from one observed snapshot; separate AX reads could mix revisions.
        let captured = snapshot as NSString
        var above = captured.substring(with: NSRange(location: 0, length: selection.location - lower))
        var below = captured.substring(with: NSRange(location: selection.end - lower, length: upper - selection.end))
        let selected = selection.length > 0 ? captured.substring(with: NSRange(location: selection.location - lower, length: selection.length)) : nil
        var aboveStop: FieldStop = lower == 0 ? .start : .cap
        var belowStop: FieldStop = upper == length ? .start : .cap
        if let stop = FieldReader.structuralStop(in: above, atFieldStart: lower == 0) {
            above = String(above[stop.index...]); aboveStop = stop.kind
        }
        if let stop = FieldReader.structuralStopBelow(in: below) {
            below = String(below[..<stop.index]); belowStop = stop.kind
        }
        activeInstructionID = instructionID
        coordinator.observe(try window(target))
        guard let lease = coordinator.begin(owner: .read, id: UUID().uuidString) else { throw Ownership.changed }
        do {
            guard coordinator.confirm(lease, window: try window(target)) else { throw Ownership.changed }
            coordinator.finish(lease, settled: true)
        } catch {
            coordinator.finish(lease, settled: false)
            throw error
        }
        readRevision = coordinator.revision
        readSelection = selection; readText = snapshot; readRange = range
        var sessionLength = 0
        if let span = sessionSpan, span.range.end == selection.location,
           (try? target.text(in: span.range)) == span.text { sessionLength = min(span.text.count, above.count) }
        return FieldReadReply(id: instructionID, state: .done, above: above, below: below, selection: selected,
                              sessionLength: sessionLength, stop: aboveStop,
                              stopBelow: belowStop, moreAbove: aboveStop == .cap,
                              moreBelow: belowStop == .cap, documentID: documentID, revision: readRevision)
    }

    public func apply(_ edit: ScopedEdit) async -> ScopedEditAck? {
        func refused(_ reason: String) -> ScopedEditAck { .init(id: edit.id, applied: false, reason: reason) }
        guard edit.documentID == documentID, !blocked, let target, target.isFocused() else {
            return refused("The focused field changed. Nothing was edited.")
        }
        do {
            let selection = try target.selectedRange()
            if let readSelection {
                guard selection == readSelection else { return refused("The cursor moved. Nothing was edited.") }
                guard let readRange, try target.text(in: readRange) == readText else {
                    return refused("The text changed. Nothing was edited.")
                }
            } else {
                guard selection == instructionCursor else { return refused("The cursor moved. Nothing was edited.") }
            }
            let range: UTF16Range
            if let selected = edit.selected {
                guard selection.length == selected.utf16.count else { return refused("The selection changed.") }
                range = selection
            } else {
                guard selection.length == 0, selection.location >= edit.before.utf16.count else { return refused("The cursor moved.") }
                range = .init(location: selection.location - edit.before.utf16.count, length: edit.scopeText.utf16.count)
            }
            guard try target.text(in: range) == edit.scopeText else { return refused("The text changed. Nothing was edited.") }
            try replaceOwned(target, range: range, text: edit.target, owner: .instruction, id: edit.id,
                             revision: edit.revision ?? readRevision)
            let caret = UTF16Range(location: range.location + edit.target.utf16.count, length: 0)
            readSelection = nil; readText = nil; instructionCursor = caret; expected = caret
            sessionSpan = nil; runID = nil; readRevision = coordinator.revision
            return .init(id: edit.id, applied: true, cursor: edit.target.utf16.count, revision: coordinator.revision)
        } catch {
            if coordinator.uncertain {
                blocked = true
                return .init(id: edit.id, applied: false, reason: "The app did not confirm the edit. The original and suggestion are saved; check the field before retrying.", stopped: true)
            }
            return refused("The field could not be verified. Nothing further was edited.")
        }
    }
    /// Retry/Insert-as-is retract only the last stream's verified text, including restoring
    /// the original selection. A refused retract freezes retries so they cannot duplicate it.
    @discardableResult public func retractStreamed() -> Bool {
        guard runID != nil, !written.isEmpty else { return true }
        guard !blocked, let target, target.isFocused() else { blocked = true; report("The field changed. Partial text was left in place; the retry will be copied."); return false }
        do {
            let range = UTF16Range(location: start, length: written.utf16.count)
            guard try target.selectedRange() == expected, try target.text(in: range) == written else { throw Ownership.changed }
            try replaceOwned(target, range: range, text: replacedOriginal, owner: .dictation, id: UUID().uuidString,
                             finalSelection: .init(location: start, length: replacedOriginal.utf16.count))
            let restored = UTF16Range(location: start, length: replacedOriginal.utf16.count)
            guard try target.text(in: restored) == replacedOriginal else { throw Ownership.changed }
            guard try target.selectedRange() == restored else { throw Ownership.changed }
            if let runID { retiredRunIDs.insert(runID) }
            expected = restored; runID = nil; written = ""; original = ""; sessionSpan = nil
            return true
        } catch {
            blocked = true
            report("The field changed. Partial text was left in place; the retry will be copied.")
            return false
        }
    }

    public func finish() async { flushLive(); await fallbackTask?.value }

    public func contextBeforeCursor() -> String {
        guard !blocked, let target, target.isFocused(), let cursor = try? target.selectedRange() else { return "" }
        let length = min(cursor.location, 600)
        return (try? target.text(in: .init(location: cursor.location - length, length: length))) ?? ""
    }
    public func deliver(_ text: String) {
        applyLive(.init(runID: UUID().uuidString, version: 1, segments: [.init(id: 0, text: text, final: true)], complete: true))
    }
    public func stream(_ poll: @MainActor () -> DictationStreamState?) async -> Bool {
        let id = UUID().uuidString
        var version = 0
        while let state = poll() {
            version += 1
            if state.retracted { _ = retractStreamed(); return false }
            applyLive(.init(runID: id, version: version, segments: [.init(id: 0, text: state.text, final: state.isFinal)], complete: state.isFinal))
            if state.isFinal { return false }
            if state.stalled { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }
    public func publish(_ strip: InstructionStrip) {}
    /// Observe a bounded UTF-16 window without moving the selection or inventing unread text.
    private func window(_ target: any TextTarget) throws -> FieldEditCoordinator.Window {
        let selection = try target.selectedRange(), length = try target.textLength()
        guard selection.location >= 0, selection.end <= length else { throw Ownership.changed }
        let lower = max(0, selection.location - FieldReader.defaultCap)
        let upper = min(length, selection.end + FieldReader.defaultCap)
        return .init(documentID: documentID,
                     before: try target.text(in: .init(location: lower, length: selection.location - lower)),
                     after: try target.text(in: .init(location: selection.end, length: upper - selection.end)),
                     selection: selection.length == 0 ? nil : try target.text(in: selection),
                     startsDocument: lower == 0, endsDocument: upper == length)
    }

    /// Every AX mutation must acquire the shared owner before issuing. A throwing host can have
    /// already written; only exact read-back settles it, and uncertainty prohibits another write.
    private func replaceOwned(_ target: any TextTarget, range: UTF16Range, text: String,
                              owner: FieldEditCoordinator.Owner, id: String, revision: FieldRevision? = nil,
                              finalSelection: UTF16Range? = nil) throws {
        coordinator.observe(try window(target))
        guard let lease = coordinator.begin(owner: owner, id: id, expectedRevision: revision) else { throw Ownership.changed }
        let length: Int, prefix: String, suffix: String, lower: Int
        do {
            length = try target.textLength()
            guard range.location >= 0, range.end <= length else { throw Ownership.changed }
            if let finalSelection {
                // Retraction restores the original selected passage; no arbitrary cursor relocation
                // may be smuggled into this replacement transaction.
                guard finalSelection == UTF16Range(location: range.location, length: text.utf16.count) else { throw Ownership.changed }
            }
            lower = max(0, range.location - FieldReader.defaultCap)
            prefix = try target.text(in: .init(location: lower, length: range.location - lower))
            suffix = try target.text(in: .init(location: range.end, length: min(FieldReader.defaultCap, length - range.end)))
        } catch {
            coordinator.finish(lease, settled: true)
            throw error
        }
        let restoresSelection = (finalSelection?.length ?? 0) > 0
        let desired = FieldEditCoordinator.Window(documentID: documentID,
                                                  before: restoresSelection ? prefix : prefix + text,
                                                  after: suffix, selection: restoresSelection ? text : nil,
                                                  startsDocument: lower == 0,
                                                  endsDocument: suffix.utf16.count == length - range.end)
        // WebKit represents a trailing contenteditable space as NBSP. Appending text can
        // turn only that boundary character back into a regular space, outside our range.
        // Its two legal outcomes cannot be predicted as one exact window. Preserve the
        // desired document, then settle only from the narrowly verified actual report.
        let boundarySpace = range.length == 0 && prefix.hasSuffix("\u{00A0}") && text.first.map { !$0.isWhitespace } == true
        guard coordinator.issued(lease, desired: desired, predicted: boundarySpace ? nil : desired) else { throw Ownership.changed }
        do {
            try target.replace(range, with: text)
            let caret = UTF16Range(location: range.location + text.utf16.count, length: 0)
            guard target.isFocused(), try target.selectedRange() == caret,
                  try target.text(in: .init(location: range.location, length: text.utf16.count)) == text else { throw Ownership.changed }
            // Verify the untouched sides and document size as well as the replacement: an AX
            // call reporting success is not proof it kept the rest of a browser editor intact.
            let actualPrefix = try target.text(in: .init(location: lower, length: prefix.utf16.count))
            let normalizedBoundary = boundarySpace && actualPrefix == String(prefix.dropLast()) + " "
            guard try target.textLength() == length - range.length + text.utf16.count,
                  actualPrefix == prefix || normalizedBoundary,
                  try target.text(in: .init(location: caret.location, length: suffix.utf16.count)) == suffix else { throw Ownership.changed }
            if let finalSelection, finalSelection != caret {
                try target.setSelectedRange(finalSelection)
                guard target.isFocused(), try target.selectedRange() == finalSelection else { throw Ownership.changed }
            }
            guard coordinator.confirm(lease, window: try window(target)) else { throw Ownership.changed }
            coordinator.finish(lease, settled: true)
        } catch {
            coordinator.finish(lease, settled: false)
            throw error
        }
    }
    private enum Ownership: Error { case changed }
}
#endif
