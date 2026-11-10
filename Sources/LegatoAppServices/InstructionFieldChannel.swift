import Foundation
import LegatoAgent
import LegatoKeyboardCore

/// The app's end of the instruction link (`InstructionLink` over the App Group): read requests and scoped edits go to
/// the keyboard with their Darwin notes, and the answers are awaited by id with a timeout, like Refine's.
@MainActor public final class InstructionFieldChannel: InstructionField {
    private let link: InstructionLink
    private let post: @Sendable (String) -> Void
    private let poll: Duration
    private let now: @MainActor () -> ContinuousClock.Instant
    private let ackTimeout: TimeInterval
    private let readTimeout: TimeInterval
    private let editTimeout: TimeInterval
    private let landTimeout: TimeInterval

    public init(store: LinkStore, post: @escaping @Sendable (String) -> Void = { DarwinObserver.post($0) }, poll: Duration = .milliseconds(30),
                ackTimeout: TimeInterval = LinkChannel.readAckTimeout, readTimeout: TimeInterval = LinkChannel.readTimeout,
                editTimeout: TimeInterval = LinkChannel.editTimeout, landTimeout: TimeInterval = LinkChannel.editLandTimeout,
                now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        link = InstructionLink(store: store); self.post = post; self.poll = poll
        self.ackTimeout = ackTimeout; self.readTimeout = readTimeout; self.editTimeout = editTimeout
        self.landTimeout = landTimeout; self.now = now
    }

    public func cancel(instructionID: String) {
        link.cancelInstruction(id: instructionID)
        post(LinkChannel.Note.instructionEdit)
        post(LinkChannel.Note.read)
    }

    public func publish(_ strip: InstructionStrip) {
        link.publish(strip)
        post(LinkChannel.Note.instruction)
    }

    /// The keyboard's intents (strip taps), oldest first.
    public func drainIntents() -> [InstructionIntent] { link.drainIntents() }

    /// Removes every instruction value from the App Group (the keyboard session closed).
    public func clear() { link.clearAll(); post(LinkChannel.Note.instruction) }

    public func read(_ kind: FieldReadRequest.Kind, instructionID: String, reading: @escaping @MainActor () -> Void) async throws -> FieldReadReply {
        let request = FieldReadRequest(instructionID: instructionID, kind: kind)
        link.request(request)
        post(LinkChannel.Note.read)
        let start = now()
        var walking = false
        while true {
            if Task.isCancelled {
                cancel(instructionID: instructionID)
                _ = link.takeRequest(id: request.id)
                throw CancellationError()
            }
            if let reply = link.takeReply(id: request.id) {
                switch reply.state {
                case .reading: if !walking { walking = true; reading() }
                case .done: return reply
                case .failed:
                    let message = reply.error ?? "The text could not be read."
                    throw reply.lasting == true ? InstructionFailure.unreadable(message) : InstructionFailure.read(message)
                }
            }
            if seconds(since: start) >= (walking ? readTimeout : ackTimeout) {
                // Nobody took it: it must not be served later, when the field may be another.
                _ = link.takeRequest(id: request.id)
                cancel(instructionID: instructionID)
                throw InstructionFailure.read(walking ? "Reading the text took too long." : "Legato's keyboard didn't answer. Is it still on screen?")
            }
            do { try await Task.sleep(for: poll) }
            catch {
                cancel(instructionID: instructionID)
                _ = link.takeRequest(id: request.id)
                throw error
            }
        }
    }

    public func apply(_ edit: ScopedEdit) async -> ScopedEditAck? {
        guard !Task.isCancelled, !link.cancelledInstruction(id: edit.instructionID) else {
            return ScopedEditAck(id: edit.id, applied: false, reason: "The instruction was cancelled.")
        }
        link.publish(edit)
        post(LinkChannel.Note.instructionEdit)
        let start = now()
        var deadline = editTimeout, landing = false
        while true {
            if let ack = link.takeAck(id: edit.id) { return ack }
            if Task.isCancelled || link.cancelledInstruction(id: edit.instructionID) {
                cancel(instructionID: edit.instructionID)
                let unread = link.takeEdit(id: edit.id) != nil
                return ScopedEditAck(id: edit.id, applied: false,
                                     reason: unread ? "The instruction was cancelled before editing." : "The instruction was cancelled. Check the field before continuing.",
                                     stopped: unread ? nil : true)
            }
            if seconds(since: start) >= deadline {
                // Still unread: taken back, so it can never land late. Already taken: it is landing op by op; wait for it.
                if link.takeEdit(id: edit.id) != nil { return nil }
                if landing {
                    cancel(instructionID: edit.instructionID)
                    return ScopedEditAck(id: edit.id, applied: false,
                                         reason: "The edit could not be confirmed. Check the field before continuing.", stopped: true)
                }
                landing = true; deadline = editTimeout + landTimeout
            }
            try? await Task.sleep(for: poll)
        }
    }

    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: now()).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
