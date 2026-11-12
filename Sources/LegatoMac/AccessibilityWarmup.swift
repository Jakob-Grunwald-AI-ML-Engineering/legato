import Foundation

/// Chromium-based apps (Chrome, Edge, their installed web apps, Electron) build their Accessibility tree only after
/// an assistive client asks for it, and then asynchronously: Chrome, an Edge window and VS Code exposed their focused
/// element 0.05 to 0.13 s after the request. The tree is requested only while the app exposes no focused element at
/// all, at most once per `budget` (a request sent while the app was still launching is lost); a capture right after a
/// request keeps retrying within `budget`, every other capture reads once.
public struct AccessibilityWarmup: Sendable {
    /// How long a capture keeps retrying after the tree was requested.
    public static let budget = Duration.milliseconds(500)
    /// The pause between attempts.
    public static let interval = Duration.milliseconds(50)

    private var requestedAt: [Int32: ContinuousClock.Instant] = [:]

    public init() {}

    /// The app shows no focused element: whether to request its tree now (never asked, or the last request is older
    /// than `budget` and evidently did not take). Records the request.
    public mutating func shouldRequest(pid: Int32, now: ContinuousClock.Instant) -> Bool {
        if let last = requestedAt[pid], now < last + Self.budget { return false }
        requestedAt[pid] = now
        return true
    }

    /// Until when a capture of `pid` keeps retrying: within `budget` of the request, else nil (read once).
    public func retryDeadline(pid: Int32, now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard let requested = requestedAt[pid] else { return nil }
        let deadline = requested + Self.budget
        return now < deadline ? deadline : nil
    }

    /// The process ended; a new one with the same pid is requested afresh.
    public mutating func forget(pid: Int32) { requestedAt[pid] = nil }

    /// Calls `probe` until it yields a value, then every `interval` until `deadline`; nil when it never did.
    /// The first attempt always runs, even past the deadline.
    @MainActor
    public static func retry<T>(until deadline: ContinuousClock.Instant?,
                                interval: Duration = AccessibilityWarmup.interval,
                                now: () -> ContinuousClock.Instant = { .now },
                                sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                                probe: () -> T?) async -> T? {
        if let value = probe() { return value }
        guard let deadline else { return nil }
        while now() < deadline, !Task.isCancelled {
            await sleep(interval)
            if let value = probe() { return value }
        }
        return nil
    }
}

/// Whether an app runs on Chromium. Its web content exposes text for reading but implements no Accessibility text
/// replacement (an AXSelectedText write reports success and changes nothing), so dictation types into it instead.
public enum ChromiumHost {
    /// `executableName`: the bundle's executable; `frameworks`: the names in `Contents/Frameworks`;
    /// `fileExists`: whether a path relative to `Contents/Frameworks` exists.
    public static func matches(executableName: String?, frameworks: [String], fileExists: (String) -> Bool) -> Bool {
        // The shim of a web app installed from Chrome or Edge; its windows are the browser's web content.
        if executableName == "app_mode_loader" { return true }
        return frameworks.contains { name in
            name == "Electron Framework.framework" || name == "Chromium Embedded Framework.framework"
                || (name.hasSuffix(" Framework.framework") && fileExists(name + "/Resources/icudtl.dat"))
        }
    }
}
