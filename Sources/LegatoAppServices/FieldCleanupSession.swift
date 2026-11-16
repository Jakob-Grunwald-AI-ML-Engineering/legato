import Foundation
import LegatoAgent
import LegatoCore
import LegatoKeyboardCore

/// Cleanup and Magic share the field's read/conditional-write interface. Speech remains in the
/// dictation queue; this owner never publishes a cleaned transcript back over a user's field.
@MainActor public final class FieldCleanupSession {
    public weak var field: (any InstructionField)?
    public var canApply: @MainActor () -> Bool = { true }
    public var clean: @MainActor (String, Bool) async -> String? = { _, _ in nil }
    public var onResult: @MainActor (String, String, CleanupFieldStatus) async -> Void = { _, _, _ in }
    public var diagnostics: (@MainActor (String, [String: Any]) -> Void)?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var requestID: String?
    private var requested = false
    private var finalRequested = false
    private var lastRead = ""
    private var coverage = FieldCleanupChunks.Coverage()
    private var pendingText = ""
    public private(set) var lastApplied = false

    public init() {}

    public func reset() {
        generation += 1
        task?.cancel(); task = nil
        if let requestID { field?.cancel(instructionID: requestID) }
        requestID = nil; requested = false; finalRequested = false; lastRead = ""; coverage = .init()
        pendingText = ""; lastApplied = false
    }

    /// Repeated pauses coalesce. A stop always gets a fresh pass, including long takes.
    public func request(final: Bool = false, pendingText: String = "") {
        requested = true; finalRequested = finalRequested || final
        if !pendingText.isEmpty { self.pendingText = pendingText }
        guard task == nil else { return }
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            while requested, !Task.isCancelled, token == generation {
                guard canApply() else { break }
                let final = finalRequested
                let pending = self.pendingText
                self.pendingText = ""
                requested = false; finalRequested = false
                await pass(final: final, pending: pending, generation: token)
            }
            if token == generation { task = nil }
        }
    }

    public func settle() async { await task?.value }

    private func pass(final: Bool, pending: String, generation token: Int) async {
        guard let field else { return }
        lastApplied = false
        let id = UUID().uuidString
        requestID = id
        defer { field.cancel(instructionID: id); if requestID == id { requestID = nil } }
        do {
            let reply = try await field.read(.cleanup, instructionID: id, reading: {})
            guard token == generation, !Task.isCancelled else { return }
            guard reply.state == .done, reply.selection?.isEmpty != false else {
                await onResult("", "", .undelivered); return
            }
            let baseline = reply.above + reply.below
            let insertion = FieldInsertion.prepare(pending, contextBefore: reply.above, capitalization: .none)
            let following = insertion.isEmpty ? "" : FieldInsertion.trailingSeparator(after: insertion, before: reply.below.first)
            let source = reply.above + insertion + following + reply.below
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  final || source != lastRead else { return }
            let complete = reply.stop == .start && reply.stopBelow == .start
            let start = final ? source.startIndex : coverage.start(in: source, documentID: reply.documentID, complete: complete)
            let passage = String(source[start...])
            guard final || FieldCleanupChunks.wordStarts(in: passage).count >= FieldCleanupChunks.words else { return }
            lastRead = source
            let cleaned = await clean(passage, final)
            guard token == generation, !Task.isCancelled else { return }
            guard let cleaned else {
                await onResult(source, baseline, pending.isEmpty ? .keptAsTyped : .undelivered)
                return
            }
            let target = String(source[..<start]) + cleaned
            // A provider may finish after speech resumes. Keep its result until a pause, but never
            // hold up the incoming words or apply against a different read after a reset.
            while !canApply(), token == generation, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard token == generation, !Task.isCancelled else { return }
            // Re-read just before applying: existing shared three-way merge keeps user changes
            // and accepts only cleanup changes in untouched words. Bounded windows cannot prove
            // common document extent, so they require an exact match instead.
            let fresh = try await field.read(.cleanup, instructionID: id, reading: {})
            guard token == generation, !Task.isCancelled else { return }
            guard fresh.state == .done, fresh.documentID == reply.documentID, fresh.draftID == reply.draftID, fresh.selection?.isEmpty != false else {
                await onResult(source, "", .undelivered); return
            }
            let current = fresh.above + fresh.below
            // Sending can clear a host field without changing its document ID. An empty
            // successor is no longer this cleanup's draft, including buffered speech not
            // yet inserted. Adapters also supply draftID to catch clear-then-type races.
            guard !current.isEmpty || baseline.isEmpty else {
                await onResult(source, "", .undelivered); return
            }
            let whole = reply.stop == .start && reply.stopBelow == .start && fresh.stop == .start && fresh.stopBelow == .start
            guard current == baseline || whole else { await onResult(source, current, pending.isEmpty ? .keptAsTyped : .undelivered); return }
            let merged = String(FieldMerge.rebase(base: Array(baseline), kept: Array(current), incoming: Array(target)).text)
            if current == merged {
                lastApplied = pending.isEmpty
                if pending.isEmpty { coverage.confirm(proposed: target, actual: current, documentID: fresh.documentID, complete: whole) }
                await onResult(source, current, pending.isEmpty ? .keptAsTyped : .undelivered)
                return
            }
            let edit = ScopedEdit(instructionID: id, documentID: reply.documentID,
                                  before: fresh.above, after: fresh.below, target: merged, draftID: fresh.draftID)
            let ack = await field.apply(edit)
            guard token == generation else { return }
            lastApplied = ack?.applied == true
            if ack?.applied == true { coverage.confirm(proposed: target, actual: merged, documentID: fresh.documentID, complete: whole) }
            let status: CleanupFieldStatus = ack?.applied == true ? (target == source ? .keptAsTyped : .cleaned) : ack?.stopped == true || ack == nil ? .undelivered : .keptAsTyped
            await onResult(source, ack?.applied == true ? merged : ack?.partial ?? current, status)
            diagnostics?("field.cleanup", ["final": final, "sourceChars": source.count, "targetChars": target.count, "status": status.rawValue])
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            await onResult("", "", .undelivered)
            diagnostics?("field.cleanup", ["final": final, "status": "readFailed"])
        }
    }
}
