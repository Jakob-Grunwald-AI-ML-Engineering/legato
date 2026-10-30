#if LEGATO_INTERNAL
import Foundation
import LegatoDevHarness
import UIKit

@MainActor enum DebugBridge {
    static var root: URL {
        return URL.cachesDirectory.appending(path: "debug-bridge", directoryHint: .isDirectory)
    }
    private static let harness = DevHarness(root: root)
    private static var started = false
    static func start() {
        guard !started else { return }
        #if !DEBUG
        guard UserDefaults.standard.bool(forKey: "LegatoDebugBridge") else { return }
        #endif
        started = true
        harness.register("state") { _ in ["status": "Composer coming", "dictating": false] }
        harness.register("toggle") { _ in _ = await AppController.shared.toggle(); return ["status": "Composer coming"] }
        harness.register("stop") { _ in return ["status": "idle"] }
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
        harness.register("foreground") { _ in UIApplication.shared.open(URL(string: "legato://open")!); return nil }
        harness.register("background") { _ in  return nil }
        #if DEBUG
        harness.register("harness-type") { _ in
            let model = KeyboardHarnessModel.shared
            model.run("harness-type")
            return ["text": model.document.text]
        }
        harness.register("harness-status") { _ in
            let model = KeyboardHarnessModel.shared
            return ["text": model.document.text, "status": model.controller.dictationStatus ?? "Composer coming"]
        }
        #endif
        harness.start()
    }
    static func emit(id: String, event: String, _ fields: [String: Any] = [:]) { harness.emit(id: id, event: event, fields) }
    enum Usage: Error { case invalid }
}
#endif
