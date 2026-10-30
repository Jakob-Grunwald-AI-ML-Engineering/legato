#if DEBUG
import Foundation
import os

enum E2E {
    static let showsKeyboardHarness = UserDefaults.standard.bool(forKey: "LegatoKeyboardHarness")
    static func log(_ message: String) { Logger(subsystem: "de.gruenwald.legato", category: "e2e").notice("\(message, privacy: .public)") }
    static func quote(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\n", with: " ") + "\"" }
    static func waitForStartWatch() async {}
    static var fakeInBackground: Bool? { nil }
    static var fakeOtherAudioPlaying: Bool? { nil }
}
#endif
