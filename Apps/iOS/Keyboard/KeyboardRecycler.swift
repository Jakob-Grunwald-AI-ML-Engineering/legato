import Darwin
import Foundation
import LegatoKeyboardCore
import os
import UIKit

/// Ends the keyboard's process once it is unhealthy and its host's session with the keyboard has ended (`KeyboardRecyclePolicy`,
/// #342), so iOS starts a fresh one on the next show: only a new process recovered a preview that stopped drawing. The cause
/// measured since, a background UIKit never ended, is repaired as the keyboard shows (`KeyboardForeground`); this stays for any other.
///
/// When that happens is what matters. Ended while the host still holds the keyboard (hidden, but the host in front), iOS shows
/// Apple's keyboard on the next show. The host is done with it once it has resigned active and then the keyboard's scene
/// disconnects, about half a second after the host leaves the foreground. A disconnect alone is not enough: switching keyboards
/// with the globe disconnects one while the host stays in front. iOS may suspend the process soon after, so the decision is made
/// synchronously there, or as the keyboard hides if that comes later. `NSExtensionHostDidEnterBackground` never reaches a
/// keyboard (measured, iOS 26 simulator).
/// In every build; extension only (the app compiles `KeyboardUI` for its harness, never this).
@MainActor
enum KeyboardRecycler {
    private static let policy = KeyboardRecyclePolicy()
    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "keyboard-process")
    private static var observers: [any NSObjectProtocol] = []
    private static var hostActive = true
    /// The scenes a keyboard appeared in (identity only). A keyboard process also sees scenes connect and disconnect while it
    /// launches, before any keyboard shows (measured): those are not a host's session ending.
    private static var keyboardScenes: Set<ObjectIdentifier> = []
    private static var sessionEnded = false
    private static var lastWait: PreviewDiagnostics.Recycle?

    /// Follows the host's activity and the keyboard's scenes; the first keyboard view to load calls it. A keyboard extension's
    /// only scenes are the windows its hosts show it in.
    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSExtensionHostWillResignActive, object: nil, queue: nil) { _ in
                onMain { hostActive = false }
            },
            center.addObserver(forName: .NSExtensionHostDidBecomeActive, object: nil, queue: nil) { _ in
                onMain { hostActive = true; sessionWillStart() }
            },
            center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: nil) { note in
                let scene = (note.object as AnyObject?).map(ObjectIdentifier.init)
                onMain {
                    guard let scene, keyboardScenes.remove(scene) != nil, !hostActive else { return }
                    sessionDidEnd()
                }
            },
            center.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: nil) { _ in
                onMain { sessionWillStart() }
            },
        ]
    }

    /// UIKit posts scene notifications on the main thread; the hop is only a fallback.
    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated(body) } else { DispatchQueue.main.async(execute: body) }
    }

    private static func sessionDidEnd() {
        sessionEnded = true
        #if DEBUG || LEGATO_INTERNAL
        PreviewDiagnostics.keyboard.record(.sessionEnded, census: true)
        #endif
        check()
    }

    private static func sessionWillStart() {
        guard sessionEnded else { return }
        sessionEnded = false
        lastWait = nil
        #if DEBUG || LEGATO_INTERNAL
        PreviewDiagnostics.keyboard.record(.sessionStarted, census: true)
        #endif
    }

    /// A keyboard appeared in `scene`: its disconnect, once the host has resigned active, ends the host's session.
    static func keyboardAppeared(in scene: UIScene?) {
        if let scene { keyboardScenes.insert(ObjectIdentifier(scene)) }
    }

    /// A keyboard hid or memory ran low: acts only once the session has ended (a keyboard still on screen when it did).
    static func keyboardChanged() {
        if sessionEnded { check() }
    }

    private static func check() {
        let facts = KeyboardProcess.recycleFacts(sessionEnded: sessionEnded, forced: isForced, published: LinkClient().readLiveDictation())
        switch policy.decide(facts) {
        case .healthy:
            return
        case .wait(let reason, let blocker):
            noteWait(.init(reason: reason, blocker: blocker, owesWork: facts.owesWork))
        case .recycle(let reason):
            recycle(reason, facts: facts)
        }
    }

    /// Debug builds recycle on every host leave while `keyboard-recycle-force` exists in the keyboard's own Caches directory
    /// (an unsigned simulator build has no App Group), to test the recycle and the next show without waiting for a real fault.
    private static var isForced: Bool {
        #if DEBUG
        FileManager.default.fileExists(atPath: URL.cachesDirectory.appending(path: "keyboard-recycle-force").path)
        #else
        return false
        #endif
    }

    private static func noteWait(_ wait: PreviewDiagnostics.Recycle) {
        #if DEBUG || LEGATO_INTERNAL
        // Once per reason and blocker per session, not on every hide.
        guard lastWait?.reason != wait.reason || lastWait?.blocker != wait.blocker else { return }
        lastWait = wait
        PreviewDiagnostics.keyboard.record(.recycleWait, sampleMemory: true, census: true, recycle: wait)
        #endif
    }

    private static func recycle(_ reason: KeyboardRecyclePolicy.Reason, facts: KeyboardRecyclePolicy.Facts) -> Never {
        log.notice("""
            recycle reason=\(reason.rawValue, privacy: .public) hidden=\(facts.hiddenControllers) \
            uptime=\(Int(facts.uptimeSeconds)) footprint=\(KeyboardProcess.footprint() ?? 0)
            """)
        #if DEBUG || LEGATO_INTERNAL
        // Written synchronously (`RotatingLineFile`), so it is on disk before the process ends.
        PreviewDiagnostics.keyboard.record(.processRecycled, sampleMemory: true, census: true,
                                           recycle: .init(reason: reason, blocker: nil, owesWork: facts.owesWork))
        #endif
        exit(0)
    }
}
