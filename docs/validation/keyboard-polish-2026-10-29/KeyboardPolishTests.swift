import XCTest

@MainActor
final class KeyboardPolishTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "de.gruenwald.legato")
    private var field: XCUIElement { app.textFields["systemfield.document"] }
    private func point(_ x: Double, _ y: Double) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }
    private func open(_ text: String) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-LegatoKeyboardHarness", "YES", "-LegatoHarnessSystemField", "YES",
            "-LegatoHarnessAutocap", "NO", "-LegatoHarnessSingleField", "YES",
            "-LegatoHarnessAppearance", "light", "-LegatoHarnessInitialText", text]
        app.launch()
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        XCTAssertTrue(app.buttons["Next keyboard"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(field.value as? String, text)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testHoldSpaceCursor() {
        open("abcdef")
        point(201,774).press(forDuration: 0.7)
        XCTAssertEqual(field.value as? String, "abcdef")
        point(201,774).press(forDuration: 0.7, thenDragTo: point(177,774))
        point(123,720).tap()
        XCTAssertEqual(field.value as? String, "abcxdef")
        capture("polish-cursor-left")
        point(201,774).press(forDuration: 0.7, thenDragTo: point(225,774))
        point(123,720).tap()
        XCTAssertEqual(field.value as? String, "abcxdefx")
        capture("polish-cursor-right")
    }
    func testEmojiCursorAndDoubleSpace() {
        open("ab👩‍💻")
        point(201,774).press(forDuration: 0.7, thenDragTo: point(185,774))
        point(123,720).tap()
        XCTAssertEqual(field.value as? String, "axb👩‍💻")
        capture("polish-cursor-emoji")
        open("hello")
        point(201,774).doubleTap()
        XCTAssertEqual(field.value as? String, "hello. ")
        capture("polish-double-space")
    }
}
