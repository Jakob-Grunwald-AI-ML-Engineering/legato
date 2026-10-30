import AppKit
import ApplicationServices
import AVFAudio
import Observation

@MainActor @Observable final class Permissions {
    enum MicState: Equatable { case undetermined, granted, denied }
    var mic = Permissions.currentMic()
    var accessibility = AXIsProcessTrusted()
    var hotkeyTapActive = false
    var micGranted: Bool { mic == .granted }
    var needsInputMonitoring: Bool { accessibility && !hotkeyTapActive }
    func refresh() { mic = Self.currentMic(); accessibility = AXIsProcessTrusted() }
    func requestMicrophone() async {
        if mic == .undetermined { _ = await AVAudioApplication.requestRecordPermission(); refresh() }
        else if mic == .denied { Self.openSettings("Privacy_Microphone") }
    }
    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        Self.openSettings("Privacy_Accessibility")
    }
    func requestInputMonitoring() { _ = CGRequestListenEventAccess(); Self.openSettings("Privacy_ListenEvent") }
    private static func currentMic() -> MicState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }
    private static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}
