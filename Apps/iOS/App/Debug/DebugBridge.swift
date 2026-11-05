#if LEGATO_INTERNAL
import Foundation
import LegatoDevHarness
import LegatoAppServices
import LegatoKeyboardCore
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
        harness.register("meeting-state") { _ in await AppController.shared.meetings.diagnostics() }
        harness.register("state") { _ in
            #if DEBUG
            return AppController.shared.composer.debugState
            #else
            return ["status": AppController.shared.composer.status]
            #endif
        }
        #if DEBUG
        for name in ComposerSession.debugCommands {
            harness.register(name) { command in try await AppController.shared.composer.debugControl(name, args: command.args) }
        }
        harness.register("microphone-arm") { _ in
            await AppController.shared.readyMicrophone()
            return AppController.shared.composer.debugState
        }
        harness.register("microphone-release") { _ in
            await AppController.shared.releaseMicrophone()
            return AppController.shared.composer.debugState
        }
        // The keyboard mic key's gate on the current surface (the typing surface has no mic key yet).
        harness.register("keyboard-tap") { _ in
            _ = await AppController.shared.keyboardSession.tap()
            return AppController.shared.composer.debugState
        }
        // ABC dictation route without speech: a finalized line (or live partial) enters where Soniox lines do.
        harness.register("dictation-debug-line") { command in
            guard command.args.count == 1 else { throw Usage.invalid }
            try await AppController.shared.keyboardSession.debugDictationLine(command.args[0])
            return AppController.shared.composer.debugState
        }
        harness.register("dictation-debug-tail") { command in
            guard command.args.count <= 1 else { throw Usage.invalid }
            try AppController.shared.keyboardSession.debugDictationTail(command.args.first ?? "")
            return AppController.shared.composer.debugState
        }
        // Ends the take as the keyboard's mic key does (no microphone): the held take is cleaned and typed now.
        harness.register("dictation-debug-stop") { _ in
            try AppController.shared.keyboardSession.debugDictationStop()
            return AppController.shared.dictation.takeState
        }
        harness.register("dictation-state") { _ in AppController.shared.dictation.takeState }
        // The next N take cleanups (default 1) fail twice, so the failed state is reachable without network faults.
        harness.register("dictation-debug-fail-take") { command in
            guard command.args.count <= 1, let count = command.args.first.map({ Int($0) }) ?? 1, count >= 0 else { throw Usage.invalid }
            AppController.shared.dictation.debugFailTakes = count
            return AppController.shared.dictation.takeState
        }
        // Scripted streaming cleaner for the next take cleanups: `<chunkMs> [failAfterChunks]` (first stream only fails),
        // `<chunkMs> reply <text>` (every take streams that text), or `off`.
        harness.register("dictation-debug-stream") { command in
            if command.args == ["off"] { AppController.shared.dictation.debugStreamCleaner = nil; return AppController.shared.dictation.takeState }
            if command.args.count >= 3, command.args[1] == "reply", let ms = Int(command.args[0]), ms >= 0 {
                AppController.shared.dictation.debugStreamCleaner = DebugStreamingCleaner(chunkMilliseconds: ms, reply: command.args[2...].joined(separator: " "))
                return AppController.shared.dictation.takeState
            }
            guard (1...2).contains(command.args.count), let ms = Int(command.args[0]), ms >= 0 else { throw Usage.invalid }
            let fail = command.args.count == 2 ? Int(command.args[1]) : nil
            if command.args.count == 2, fail == nil { throw Usage.invalid }
            AppController.shared.dictation.debugStreamCleaner = DebugStreamingCleaner(chunkMilliseconds: ms, failAfterChunks: fail)
            return AppController.shared.dictation.takeState
        }
        // The keyboard's Retry / Insert as-is buttons act through the link; these act on the host directly.
        harness.register("dictation-retry") { _ in
            await AppController.shared.dictation.retry()
            return AppController.shared.dictation.takeState
        }
        harness.register("dictation-insert-raw") { _ in
            await AppController.shared.dictation.insertRaw()
            return AppController.shared.dictation.takeState
        }
        harness.register("composer-import-keys") { command in
            guard command.args == ["credentials.json"] else { throw Usage.invalid }
            return try ComposerSession.importDebugKeys(file: root.appending(path: "credentials.json"))
        }
        #endif
        harness.register("toggle") { _ in _ = await AppController.shared.toggle(); return ["status": AppController.shared.notice] }
        harness.register("stop") { _ in await AppController.shared.stopIfRunning(); return ["status": AppController.shared.composer.status] }
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
        // The in-app keyboard (the real KeyboardController over a text view): what the field and the keys show.
        harness.register("harness-state") { _ in KeyboardHarnessModel.shared.state }
        // The keyboard comes on screen / leaves it, as the extension's viewWillAppear / viewDidDisappear.
        harness.register("harness-visible") { _ in KeyboardHarnessModel.shared.setVisible(true) }
        harness.register("harness-hidden") { _ in KeyboardHarnessModel.shared.setVisible(false) }
        // The surface on screen: `composer` or `typing` (ABC, the dictation surface).
        harness.register("harness-surface") { command in
            guard command.args.count == 1, let surface = KeyboardSurface(rawValue: command.args[0]) else { throw Usage.invalid }
            return KeyboardHarnessModel.shared.show(surface)
        }
        // The composer's Send key, and the take's Retry / Insert as-is buttons: the keyboard's intents over the link.
        harness.register("harness-send") { _ in KeyboardHarnessModel.shared.press { $0.insertComposer() } }
        harness.register("harness-retry") { _ in KeyboardHarnessModel.shared.press { $0.retryTake() } }
        harness.register("harness-insert-raw") { _ in KeyboardHarnessModel.shared.press { $0.insertTakeRaw() } }
        harness.register("harness-clear") { _ in KeyboardHarnessModel.shared.clearDocument() }
        #endif
        harness.start()
    }
    static func emit(id: String, event: String, _ fields: [String: Any] = [:]) { harness.emit(id: id, event: event, fields) }
    enum Usage: Error { case invalid }
}
#endif
