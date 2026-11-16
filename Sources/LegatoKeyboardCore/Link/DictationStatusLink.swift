import Foundation
import LegatoCore

public enum AudioRoute: String, Sendable, Codable, CaseIterable { case idle, dictation }
public enum DictationTakePhase: String, Sendable, Codable, Equatable { case buffering, cleaning, failed }

/// Lightweight dictation controls and presentation. Text delivery stays on LiveDictationLink.
public struct DictationStatus: Codable, Equatable, Sendable {
    public var fieldCleanupOutcome: CleanupFieldOutcome?
    /// Acoustic/semantic activity belongs to this run; absent from older hosts.
    public var speechRunID: String?
    public var speechActivity: Bool?

    public var audioRoute = AudioRoute.idle
    public var error: String?
    public var voiceIsolationStatus: String?
    public var dictationTail: String?
    public var dictationTake: String?
    public var dictationTakePhase: DictationTakePhase?
    public var dictationCountdownStart: Double?
    public var dictationCountdownDeadline: Double?
    public var dictationNotice: String?
    public var dictationNoticeID: Int?
    public init() {}
}

public struct DictationControl: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case stop, retry, insertAsIs }
    public var id = UUID().uuidString
    public var action: Action
    public var timestamp = ProcessInfo.processInfo.systemUptime
    public init(action: Action) { self.action = action }
}

public struct DictationStatusLink: Sendable {
    public let store: LinkStore
    public init(store: LinkStore) { self.store = store }
    public func publish(_ value: DictationStatus) { store.write(value, forKey: LinkChannel.Key.dictationStatus) }
    public func read() -> DictationStatus? { store.read(DictationStatus.self, forKey: LinkChannel.Key.dictationStatus) }
    public func send(_ intent: DictationControl) { store.write(intent, forKey: LinkChannel.Key.dictationControlPrefix + intent.id) }
    public func drainIntents() -> [DictationControl] {
        store.keys(withPrefix: LinkChannel.Key.dictationControlPrefix).compactMap { key in
            defer { store.remove(forKey: key) }
            return store.read(DictationControl.self, forKey: key)
        }.sorted { $0.timestamp < $1.timestamp }
    }
}
