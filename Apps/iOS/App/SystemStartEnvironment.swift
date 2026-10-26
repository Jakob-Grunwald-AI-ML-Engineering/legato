import AVFAudio
import Foundation
import LegatoAudio
import LegatoCore
import UIKit

/// The start environment: where the app is, whether other audio plays, and which start errors mean
/// "the system won't record from the background".
///
/// A background start is always attempted: it can work next to other audio (ducked) when the press
/// itself launched the app, and fails ('!pla' on `setActive`, then 'what' on the engine start) in
/// other cases. `otherAudioPlaying` is kept for the `start.route` diagnostics only. The selected audio
/// policy rides along, so the coordinator can fall back to the default when a non-default one is refused.
@MainActor
final class SystemStartEnvironment: StartEnvironment {
    /// Codes of a refused background start: `AVAudioSession.ErrorCode` `.cannotStartPlaying` ('!pla'),
    /// `.cannotInterruptOthers` ('!int'), `.cannotStartRecording` ('!rec'), and the engine's
    /// kAUStartIO 'what'. `MicSourceError.invalidInputFormat` (0 Hz input after all retries) counts too.
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
        lastContext = StartContext(
            inBackground: inBackground, otherAudioPlaying: otherAudioPlaying, audioPolicy: Settings.audioPolicy)
        return lastContext
    }

    func isBackgroundRefusal(_ error: any Error) -> Bool {
        Self.isRefusal(error)
    }

    /// The error is the mic reporting no input format (0 Hz right after activation, which retries did
    /// not clear), or it or any error it wraps carries one of `refusalCodes`.
    nonisolated static func isRefusal(_ error: any Error) -> Bool {
        if let mic = error as? MicSourceError, mic == .invalidInputFormat { return true }
        return refusalCode(of: error) != nil
    }

    /// A short name for a refusal, for logs: the code as a FourCC when it is one ('!int'), else the
    /// number, else the error's description.
    nonisolated static func refusalLabel(_ error: any Error) -> String {
        if let mic = error as? MicSourceError { return String(describing: mic) }
        let code = refusalCode(of: error) ?? (error as NSError).code
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        if code > 0, code <= Int(UInt32.max), bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(code)
    }

    /// The first code in the error chain that is one of `refusalCodes`.
    nonisolated private static func refusalCode(of error: any Error) -> Int? {
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 5 {
            if refusalCodes.contains(ns.code) { return ns.code }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }
}
