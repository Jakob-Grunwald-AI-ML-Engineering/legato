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
            picker.buttons[parts[1]].tap()
            XCTAssertFalse(picker.exists, "Selecting a mode must close the picker")
            XCTAssertTrue(app.buttons[parts[1]].waitForExistence(timeout: 5), "Selected mode must reach the keyboard")
        case "tap": try coordinate(1).tap()
        case "hold": try coordinate(1).press(forDuration: number(3))
        case "swipe":
            if parts.count == 6 {
                let hold = try number(5)
                guard hold >= 0 else { throw ControlError.invalidArguments }
                try coordinate(1).press(forDuration: 0.1, thenDragTo: coordinate(3),
                    withVelocity: .slow, thenHoldForDuration: hold)
            } else {
                try coordinate(1).press(forDuration: 0.1, thenDragTo: coordinate(3))
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
