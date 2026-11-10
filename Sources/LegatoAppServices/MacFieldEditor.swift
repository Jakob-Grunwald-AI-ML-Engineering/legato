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
    private var seenRunIDs: Set<String> = []
    private var retiredRunIDs: Set<String> = []
    private var target: (any TextTarget)?
    private var documentID = UUID().uuidString
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
        fallbackTask?.cancel(); fallbackTask = nil
        fallbackAllowed = false; fallbackRuns = []
        seenRunIDs = []; retiredRunIDs = []
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
    public func relinquish() { blocked = true; fallbackAllowed = false }
    public func focusChanged() { if target?.isFocused() == false { relinquish() } }

    public func beginInstruction() {
        let cursorChanged = target.flatMap { try? $0.selectedRange() } != expected
        if target?.isFocused() != true || blocked || cursorChanged {
            // An old pipeline cleanup may finish after Magic binds a different field/selection.
            // Its run remains barred even though the new instruction has explicit fresh ownership.
            let retired = retiredRunIDs.union(seenRunIDs)
            begin()
            retiredRunIDs = retired
        }
        instructionCursor = try? target?.selectedRange()
        if let instructionCursor { expected = instructionCursor }
        readSelection = nil; readText = nil
    }

    public func applyLive(_ snapshot: LiveDictationSnapshot?) {
        guard let snapshot else { return }
        seenRunIDs.insert(snapshot.runID)
        guard !retiredRunIDs.contains(snapshot.runID) else { return }
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
            // Preserve the common prefix and suffix so only changed words touch the host.
            let a = Array(old), b = Array(text)
            var prefix = 0, suffix = 0
            while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
            while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
            let lead = String(a.prefix(prefix)).utf16.count
            let removed = String(a[prefix..<(a.count - suffix)]).utf16.count
            let replacement = String(b[prefix..<(b.count - suffix)])
            try target.replace(.init(location: start + lead, length: removed), with: replacement)
            // AX replacement leaves the caret at its end, possibly before an unchanged suffix.
            // Do not move the user's cursor by guessing: track that exact caret for the next update.
            let actual = try target.selectedRange()
            guard actual.length == 0, actual.location == start + lead + replacement.utf16.count,
                  try target.text(in: .init(location: start, length: text.utf16.count)) == text else { throw Ownership.changed }
            let end = UTF16Range(location: start + text.utf16.count, length: 0)
            if actual != end { try target.setSelectedRange(end) }
            guard try target.selectedRange() == end else { throw Ownership.changed }
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
        var above = try target.text(in: .init(location: lower, length: selection.location - lower))
        var below = try target.text(in: .init(location: selection.end, length: upper - selection.end))
        let selected = selection.length > 0 ? try target.text(in: selection) : nil
        var aboveStop: FieldStop = lower == 0 ? .start : .cap
        var belowStop: FieldStop = upper == length ? .start : .cap
        if let stop = FieldReader.structuralStop(in: above, atFieldStart: lower == 0) {
            above = String(above[stop.index...]); aboveStop = stop.kind
        }
        if let stop = FieldReader.structuralStopBelow(in: below) {
            below = String(below[..<stop.index]); belowStop = stop.kind
        }
        readSelection = selection; readText = snapshot; readRange = range
        var sessionLength = 0
        if let span = sessionSpan, span.range.end == selection.location,
           (try? target.text(in: span.range)) == span.text { sessionLength = min(span.text.count, above.count) }
        return FieldReadReply(id: instructionID, state: .done, above: above, below: below, selection: selected,
                              sessionLength: sessionLength, stop: aboveStop,
                              stopBelow: belowStop, moreAbove: aboveStop == .cap,
                              moreBelow: belowStop == .cap, documentID: documentID)
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
            try target.replace(range, with: edit.target)
            let caret = UTF16Range(location: range.location + edit.target.utf16.count, length: 0)
            guard try target.text(in: .init(location: range.location, length: edit.target.utf16.count)) == edit.target,
                  try target.selectedRange() == caret else {
                blocked = true
                return .init(id: edit.id, applied: false, reason: "The app did not confirm the edit. Check the field before continuing.", stopped: true)
            }
            readSelection = nil; readText = nil; instructionCursor = caret; expected = caret
            sessionSpan = nil; runID = nil
            return .init(id: edit.id, applied: true, cursor: edit.target.utf16.count)
        } catch { return refused("This field cannot safely read and replace that text. Nothing further was edited.") }
    }
    /// Retry/Insert-as-is retract only the last stream's verified text, including restoring
    /// the original selection. A refused retract freezes retries so they cannot duplicate it.
    @discardableResult public func retractStreamed() -> Bool {
        guard runID != nil, !written.isEmpty else { return true }
        guard !blocked, let target, target.isFocused() else { blocked = true; report("The field changed. Partial text was left in place; the retry will be copied."); return false }
        do {
            let range = UTF16Range(location: start, length: written.utf16.count)
            guard try target.selectedRange() == expected, try target.text(in: range) == written else { throw Ownership.changed }
            try target.replace(range, with: replacedOriginal)
            let restored = UTF16Range(location: start, length: replacedOriginal.utf16.count)
            guard try target.text(in: restored) == replacedOriginal else { throw Ownership.changed }
            try target.setSelectedRange(restored)
            guard try target.selectedRange() == restored else { throw Ownership.changed }
            expected = restored; runID = nil; written = ""; original = ""; sessionSpan = nil
            return true
        } catch {
            blocked = true
            report("The field changed. Partial text was left in place; the retry will be copied.")
            return false
        }
    }

    public func finish() async { await fallbackTask?.value }

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
    private enum Ownership: Error { case changed }
}
