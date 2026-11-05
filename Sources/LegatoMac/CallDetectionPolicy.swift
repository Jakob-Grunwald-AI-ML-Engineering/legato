import Foundation

/// The pure rule behind call detection: when another app's call begins and when it is over.
///
/// - A **call** is a process other than Legato (by pid and by bundle-ID prefix) seen with the mic *and* the speakers
///   running. A page that only checks the mic, or a player that only plays, is not one.
/// - A call **begins** once it has been seen without a break for `startDebounce`, so a blip never fires. It begins at
///   most once: the same call going on, also after the user dismissed the prompt, does not begin again.
/// - Nothing begins while a dictation or the composer runs (it waits, and the debounce starts again after). A call
///   seen while a meeting records is taken as handled without an event, so stopping that meeting does not prompt for
///   the call that is still on.
/// - A call is **over** once its process has had neither mic nor speakers for `endGrace`; a mute that closes the mic
///   (the app still plays) and a brief drop do not end it. The next call can then begin.
public struct CallDetectionPolicy: Sendable {
    /// The process of a call; the app shows the app's name from it.
    public struct Call: Sendable, Equatable {
        public var pid: Int32
        public var bundleID: String
    }

    public enum Event: Sendable, Equatable {
        case began(Call)
        case ended

        /// Only a meeting that started by itself stops by itself; one the user started, from the prompt too, never.
        public func stopsMeeting(startedAutomatically: Bool) -> Bool {
            self == .ended && startedAutomatically
        }
    }

    private let ownPID: Int32
    private let ownBundlePrefix: String
    private let startDebounce: TimeInterval
    private let endGrace: TimeInterval
    private var candidate: (pid: Int32, since: TimeInterval)?
    private var current: Call?
    private var goneSince: TimeInterval?

    /// - Parameters:
    ///   - ownPID: our own process, never a call.
    ///   - ownBundlePrefix: our bundle ID and those of our helpers, never a call.
    public init(ownPID: Int32, ownBundlePrefix: String, startDebounce: TimeInterval = 3, endGrace: TimeInterval = 10) {
        self.ownPID = ownPID
        self.ownBundlePrefix = ownBundlePrefix
        self.startDebounce = startDebounce
        self.endGrace = endGrace
    }

    /// - Parameters:
    ///   - processes: the processes with the mic or the speakers running now.
    ///   - dictationBusy: a dictation or the composer is in use.
    ///   - meetingActive: a meeting records, or is about to.
    ///   - now: a monotonic time in seconds.
    public mutating func update(processes: [AutoMuteProcess], dictationBusy: Bool, meetingActive: Bool, at now: TimeInterval) -> Event? {
        let calls = processes.filter(isCall).sorted { $0.pid < $1.pid }
        if let current {
            if processes.contains(where: { $0.pid == current.pid && ($0.isRunningInput || $0.isRunningOutput) }) {
                goneSince = nil
                return nil
            }
            let since = goneSince ?? now
            goneSince = since
            guard now - since >= endGrace else { return nil }
            (self.current, goneSince, candidate) = (nil, nil, nil)
            return .ended
        }
        guard let process = calls.first else { candidate = nil; return nil }
        let call = Call(pid: process.pid, bundleID: process.bundleID)
        if meetingActive { (current, candidate) = (call, nil); return nil }
        if dictationBusy { candidate = nil; return nil }
        if candidate?.pid != call.pid { candidate = (call.pid, now) }
        guard let candidate, now - candidate.since >= startDebounce else { return nil }
        (current, self.candidate) = (call, nil)
        return .began(call)
    }

    private func isCall(_ process: AutoMuteProcess) -> Bool {
        process.isRunningInput && process.isRunningOutput && process.pid != ownPID
            && !(process.bundleID.hasPrefix(ownBundlePrefix) && !ownBundlePrefix.isEmpty)
    }
}
