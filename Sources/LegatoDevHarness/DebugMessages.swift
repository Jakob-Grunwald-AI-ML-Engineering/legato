import Foundation
import Observation

/// Message state only. Platform presenters explicitly acknowledge visibility before an ask is shown.
@MainActor @Observable public final class DebugMessages {
    public typealias Sink = @MainActor (String, String, [String: Any]) -> Void
    public typealias Sleep = @MainActor (Duration) async throws -> Void
    public struct Item: Identifiable, Equatable {
        public let id: String
        public let text: String
        public let choices: [String]
    }
    public struct Parsed: Equatable {
        public var text: String
        public var choices: [String]
        public var timeout: Double?
        public var sound: Bool
    }
    public private(set) var queue: [Item] = []
    public private(set) var status: String?
    public private(set) var blocking = false
    public var current: Item? { queue.first }
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let sink: Sink
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private var shownIDs: Set<String> = []
    @ObservationIgnored private var timeouts: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var limits: [String: Double] = [:]

    public init(emit: @escaping Sink, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        sink = emit; self.sleep = sleep
    }

    public static func parse(_ args: [String], takesChoices: Bool) -> Parsed? {
        var rest: [String] = [], timeout: Double?, sound = false, i = 0
        while i < args.count {
            switch args[i] {
            case "--timeout":
                guard i + 1 < args.count, let value = Double(args[i + 1]), value > 0, value.isFinite else { return nil }
                timeout = value; i += 1
            case "--sound": sound = true
            default: rest.append(args[i])
            }
            i += 1
        }
        guard let text = rest.first, !text.isEmpty else { return nil }
        let choices = takesChoices ? Array(rest.dropFirst()) : []
        guard !takesChoices || !choices.isEmpty else { return nil }
        return Parsed(text: text, choices: choices, timeout: timeout, sound: sound)
    }

    public func say(id: String, text: String) { enqueue(Item(id: id, text: text, choices: [])) }
    public func ask(id: String, text: String, choices: [String], timeout: Double?, sound: Bool = false) {
        if let timeout, timeout.isFinite, timeout > 0 { limits[id] = timeout }
        enqueue(Item(id: id, text: text, choices: choices))
    }
    private func enqueue(_ item: Item) { queue.append(item); onChange?() }

    /// Call only when the front card is actually presented. Enqueueing or showing a status is insufficient.
    public func presented(id: String?) {
        guard let id, let front = current, front.id == id, !front.choices.isEmpty,
              shownIDs.insert(id).inserted else { return }
        sink(id, "shown", [:])
        guard let limit = limits[id] else { return }
        let sleep = sleep
        timeouts[id] = Task { @MainActor [weak self] in
            do { try await sleep(.seconds(limit)); try Task.checkCancellation() }
            catch { return }
            self?.reply(id: id, choice: "timeout")
        }
    }

    public func setStatus(_ text: String?) { status = (text?.isEmpty ?? true) ? nil : text; onChange?() }
    public func setBlocking(_ on: Bool) { blocking = on; onChange?() }
    public func reply(id: String, choice: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let item = queue.remove(at: index)
        timeouts.removeValue(forKey: id)?.cancel()
        limits[id] = nil; shownIDs.remove(id)
        sink(id, item.choices.isEmpty ? "dismissed" : "reply", ["choice": choice])
        onChange?()
    }
    public func clear() {
        blocking = false; status = nil
        let old = queue
        queue = []; shownIDs = []
        for timer in timeouts.values { timer.cancel() }
        timeouts = [:]; limits = [:]
        for item in old where !item.choices.isEmpty { sink(item.id, "reply", ["choice": "cleared"]) }
        onChange?()
    }
}
