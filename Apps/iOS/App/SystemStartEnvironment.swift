import AVFAudio
import Foundation
import LegatoCore
import UIKit

/// The start environment: where the app is, whether other audio plays, and which start errors mean
/// "the system won't record from the background".
///
/// Device logs: a background mic start works whenever nothing else plays; with other audio playing it
/// fails ('!pla' on `setActive`, then 'what' on the engine start), and Apple requires such a start to
/// begin in the foreground. A foreground start can duck the other audio.
@MainActor
final class SystemStartEnvironment: StartEnvironment {
    /// Codes of a refused background start: `AVAudioSession.ErrorCode` `.cannotStartPlaying` ('!pla'),
    /// `.cannotInterruptOthers` ('!int'), `.cannotStartRecording` ('!rec'), and the engine's
    /// kAUStartIO 'what'.
    nonisolated static let refusalCodes: Set<Int> = [
        561_015_905, // '!pla'
        560_557_684, // '!int'
        561_145_187, // '!rec'
        2_003_329_396, // 'what'
    ]

    /// Set for the one toggle that follows a foreground hop: the system has just brought the app to the
    /// foreground, so the start is a foreground start whatever `applicationState` still says.
    var assumeForeground = false
    /// A held audio session (internal debug switch) is already active, so nothing is activated.
    private let isSessionHeld: @MainActor () -> Bool

    private(set) var lastContext = StartContext.unrestricted

    init(isSessionHeld: @escaping @MainActor () -> Bool = { false }) {
        self.isSessionHeld = isSessionHeld
    }

    func current() -> StartContext {
        var inBackground = !assumeForeground && UIApplication.shared.applicationState == .background
        var otherAudioPlaying = AVAudioSession.sharedInstance().isOtherAudioPlaying && !isSessionHeld()
        #if DEBUG
        if let fake = E2E.fakeInBackground { inBackground = !assumeForeground && fake }
        if let fake = E2E.fakeOtherAudioPlaying { otherAudioPlaying = fake }
        #endif
        lastContext = StartContext(inBackground: inBackground, otherAudioPlaying: otherAudioPlaying)
        return lastContext
    }

    func isBackgroundRefusal(_ error: any Error) -> Bool {
        Self.isRefusal(error)
    }

    /// The error or any error it wraps carries one of `refusalCodes`.
    nonisolated static func isRefusal(_ error: any Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 5 {
            if refusalCodes.contains(ns.code) { return true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }
}
