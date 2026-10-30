#if LEGATO_INTERNAL
import Foundation
import LegatoDevHarness
import AppKit

@MainActor enum DebugBridge {
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["LEGATO_MAC_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        return URL.cachesDirectory.appending(path: "Legato/debug-bridge", directoryHint: .isDirectory)
    }
    private static let harness = DevHarness(root: root)
    private static var started = false
    static func start() {
        guard !started else { return }
        #if !DEBUG
        guard UserDefaults.standard.bool(forKey: "LegatoDebugBridge") else { return }
        #endif
        started = true
        harness.register("state") { _ in let c = MacAppController.shared; return ["status": c.composer.status, "dictating": c.isDictating, "error": c.composer.error ?? "", "text": c.composer.renderedText, "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0, "keyWindow": NSApp.keyWindow?.title ?? ""] }
        harness.register("toggle") { _ in MacAppController.shared.toggle(); return ["status": "starting"] }
        harness.register("stop") { _ in MacAppController.shared.stopComposer(); return ["status": "stopping"] }
        harness.register("composer-insert") { _ in MacAppController.shared.insertComposer(); return nil }
        harness.register("composer-cancel") { _ in MacAppController.shared.cancelComposer(); return nil }
        harness.register("session-probe") { _ in try SessionProbe.start(); return nil }
        harness.register("say") { command in
            guard let parsed = LegatoDevHarness.DebugMessages.parse(command.args, takesChoices: false) else { throw Usage.invalid }
            DebugMessages.shared.say(id: command.id, text: parsed.text); return nil
        }
        harness.register("ask") { command in
            guard let parsed = LegatoDevHarness.DebugMessages.parse(command.args, takesChoices: true) else { throw Usage.invalid }
            DebugMessages.shared.ask(id: command.id, text: parsed.text, choices: parsed.choices, timeout: parsed.timeout, sound: parsed.sound)
            return ["waitFor": "reply"]
        }
        harness.register("status") { command in DebugMessages.shared.setStatus(command.args.first); return nil }
        harness.register("block") { command in DebugMessages.shared.setBlocking(command.args.first == "on"); return nil }
        harness.register("clear") { _ in DebugMessages.shared.clear(); return nil }
        harness.register("foreground") { _ in NSApp.unhide(nil); NSApp.activate(); return nil }
        harness.register("background") { _ in NSApp.hide(nil); return nil }
        harness.start()
    }
    static func emit(id: String, event: String, _ fields: [String: Any] = [:]) { harness.emit(id: id, event: event, fields) }
    enum Usage: Error { case invalid }
}
#endif
