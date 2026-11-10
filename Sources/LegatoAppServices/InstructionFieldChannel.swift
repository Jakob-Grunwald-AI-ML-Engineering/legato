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
            try Task.checkCancellation()
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
                _ = link.takeRequest()
                throw InstructionFailure.read(walking ? "Reading the text took too long." : "Legato's keyboard didn't answer. Is it still on screen?")
            }
            try await Task.sleep(for: poll)
        }
    }

    public func apply(_ edit: ScopedEdit) async -> ScopedEditAck? {
        link.publish(edit)
        post(LinkChannel.Note.instructionEdit)
        let start = now()
        var deadline = editTimeout, landing = false
        while true {
            if let ack = link.takeAck(id: edit.id) { return ack }
            if seconds(since: start) >= deadline {
                // Still unread: taken back, so it can never land late. Already taken: it is landing op by op; wait for it.
                if landing || link.takeEdit() != nil { return nil }
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
