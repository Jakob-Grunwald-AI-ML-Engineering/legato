import XCTest

/// Disposable, explicit native gestures against an already installed app. Never launches/reinstalls it.
@MainActor final class NativeControl: XCTestCase {
    func testControl() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication(bundleIdentifier: environment["LEGATO_NATIVE_BUNDLE"] ?? "de.gruenwald.legato")
        guard app.state != .notRunning else { XCTFail("Target app must already be running; use ctl.sh to launch the desired harness first."); return }
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let parts = (environment["LEGATO_NATIVE_COMMAND"] ?? "tree").split(separator: " ").map(String.init)
        func number(_ index: Int) throws -> Double {
            guard parts.indices.contains(index), let value = Double(parts[index]), value.isFinite else { throw ControlError.invalidArguments }
            return value
        }
        func coordinate(_ index: Int) throws -> XCUICoordinate {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: try number(index), dy: try number(index + 1)))
        }
        switch parts.first {
        case "background-mic-settings":
            app.tabBars.buttons["Settings"].tap()
            let toggle = app.switches["settings.keepMicrophoneActive"]
            for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
            XCTAssertTrue(toggle.isHittable, "Background microphone setting must be reachable")
            let original = toggle.value as? String
            XCTAssertNotNil(original)
            toggle.tap()
            let changed = toggle.value as? String
            XCTAssertNotEqual(changed, original)
            app.terminate()
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            app.tabBars.buttons["Settings"].tap()
            for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
            XCTAssertEqual(toggle.value as? String, changed, "Background microphone choice must survive relaunch")
            toggle.tap()
            XCTAssertEqual(toggle.value as? String, original, "Restore the user's original preference")
        case "companion-settings":
            let settings = app.tabBars.buttons["Settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings must be directly reachable from the companion")
            settings.tap()
            app.buttons["settings.personalInstructionsLink"].tap()
            let instructions = app.descendants(matching: .any).matching(identifier: "settings.personalInstructions").firstMatch
            XCTAssertTrue(instructions.waitForExistence(timeout: 5))
            let original = instructions.value as? String ?? ""
            instructions.tap()
            instructions.typeText("Native keyboard check")
            XCTAssertTrue(app.keyboards.firstMatch.exists, "Instructions must have a usable keyboard")
            // Restore the user's preference without logging its contents.
            if let value = instructions.value as? String {
                instructions.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
            }
            if !original.isEmpty && !original.hasPrefix("For example:") { instructions.typeText(original) }
            app.buttons["Done"].tap()
            app.navigationBars.buttons.firstMatch.tap()
            for provider in ["Claude", "Soniox"] {
                app.buttons.containing(.staticText, identifier: provider).firstMatch.tap()
                let field = app.secureTextFields["settings.\(provider.lowercased())Key"]
                XCTAssertTrue(field.waitForExistence(timeout: 5))
                let save = app.buttons["Replace \(provider) key"]
                XCTAssertTrue(save.exists, "Existing provider key must remain configured")
                XCTAssertFalse(save.isEnabled, "Blank replacement must never overwrite a saved key")
                field.tap(); field.typeText("   ")
                XCTAssertFalse(save.isEnabled, "Whitespace must never overwrite a saved key")
                app.buttons["Done"].tap()
                app.navigationBars.buttons.firstMatch.tap()
            }
            app.tabBars.buttons["Compose"].tap()
            XCTAssertTrue(app.buttons["Compose"].exists)
        case "typing-fallback":
            // Prepare the DEBUG keyboard harness with an empty target field and
            // composer-debug-seed "Typing fallback retained draft" before this command.
            let retainedDraft = app.staticTexts["Typing fallback retained draft"]
            XCTAssertTrue(retainedDraft.waitForExistence(timeout: 5), "Seeded voice draft must be visible before switching")
            let field = app.textViews["harness.document"]
            XCTAssertTrue(field.exists, "This bounded check requires the DEBUG keyboard harness")
            XCTAssertEqual(field.value as? String ?? "", "", "Use an empty disposable external field")
            let abc = app.buttons["composer.typingKeyboard"]
            XCTAssertTrue(abc.isHittable, "ABC must be reachable from the composer")
            abc.tap()
            func typingKey(_ identifier: String) -> XCUIElement {
                app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            }
            for key in ["key.a", "key.b", "key.c"] {
                let button = typingKey(key)
                XCTAssertTrue(button.isHittable, "Typing key must be reachable: \(key)")
                button.tap()
            }
            XCTAssertEqual((field.value as? String)?.lowercased(), "abc")
            typingKey("key.delete").tap()
            XCTAssertEqual((field.value as? String)?.lowercased(), "ab")
            typingKey("key.space").tap()
            typingKey("key.return").tap()
            XCTAssertEqual((field.value as? String)?.lowercased(), "ab \n")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "typing-fallback-native-grid"; shot.lifetime = .keepAlways; add(shot)
            app.buttons["typing.composer"].tap()
            XCTAssertTrue(retainedDraft.waitForExistence(timeout: 5), "Typing must retain the voice draft when returning")
            XCTAssertTrue(abc.isHittable)
            XCTAssertEqual((field.value as? String)?.lowercased(), "ab \n", "Returning must preserve external typing")
        case "tree": break
        case "keyboard":
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 42, dy: 820)).press(forDuration: 1.2)
            let keyboard = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Legato")).firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Legato missing from native keyboard chooser")
            keyboard.tap()
            XCTAssertTrue(app.buttons["Insert"].waitForExistence(timeout: 10), "Selected Legato composer did not appear")
        case "mode":
            guard parts.count == 2 else { throw ControlError.invalidArguments }
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 30, dy: 774)).tap()
            let picker = app.descendants(matching: .any).matching(identifier: "keyboard.mode-picker").firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 5), "A tap must open the keyboard-owned picker")
            for mode in ["Message", "Email", "Prompt", "Note"] {
                XCTAssertTrue(picker.buttons[mode].isHittable, "Every mode must be visible")
            }
            let popup = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            popup.name = "keyboard-mode-picker"; popup.lifetime = .keepAlways; add(popup)
            let choice = picker.buttons[parts[1]]
            if !choice.isHittable { picker.swipeUp() }
            choice.tap()
            XCTAssertFalse(picker.exists, "Selecting a mode must close the picker")
            XCTAssertTrue(app.buttons[parts[1]].waitForExistence(timeout: 5), "Selected mode must reach the keyboard")
        case "tap": try coordinate(1).tap()
        case "hold": try coordinate(1).press(forDuration: number(3))
        case "scroll":
            XCTAssertTrue(app.scrollViews.firstMatch.exists)
            app.scrollViews.firstMatch.swipeUp(velocity: .fast)
        case "quote":
            try coordinate(1).press(forDuration: 0.45, thenDragTo: coordinate(3), withVelocity: .slow, thenHoldForDuration: 0.15)
        case "swipe":
            if parts.count == 6 {
                let hold = try number(5)
                guard hold >= 0 else { throw ControlError.invalidArguments }
                try coordinate(1).press(forDuration: 0.1, thenDragTo: coordinate(3),
                    withVelocity: .slow, thenHoldForDuration: hold)
            } else {
                try coordinate(1).press(forDuration: 0.01, thenDragTo: coordinate(3), withVelocity: .fast, thenHoldForDuration: 0)
            }
        case "label":
            let label = parts.dropFirst().joined(separator: " ")
            let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 5), "No native element labelled \(label)")
            element.tap()
        default: throw ControlError.invalidArguments
        }
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "native-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "physical-full-screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private enum ControlError: Error { case invalidArguments }
}
