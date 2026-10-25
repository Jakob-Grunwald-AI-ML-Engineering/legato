import AppKit
import ApplicationServices
import LegatoMac

enum AXTargetError: Error {
    case attribute(AXError)
    case unexpectedValue
}

/// `TextTarget` over the focused `AXUIElement` of the frontmost app, captured when dictation starts.
/// Every call is synchronous and bounded by a 0.25 s Accessibility messaging timeout.
@MainActor
final class AXTextTarget: TextTarget {
    nonisolated static let messagingTimeout: Float = 0.25

    private let element: AXUIElement
    private let appElement: AXUIElement

    private init(element: AXUIElement, appElement: AXUIElement) {
        self.element = element
        self.appElement = appElement
    }

    /// The focused text element of the frontmost app; nil when Accessibility is not granted, our own
    /// app is in front, nothing is focused, the field is secure or exposes no selection.
    static func captureFocused() -> AXTextTarget? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        guard let focused = try? copyAttribute(appElement, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        if let subrole = try? copyAttribute(element, kAXSubroleAttribute) as? String, subrole == "AXSecureTextField" {
            return nil
        }
        guard (try? copyAttribute(element, kAXSelectedTextRangeAttribute)) != nil else { return nil }
        return AXTextTarget(element: element, appElement: appElement)
    }

    // MARK: TextTarget

    func isFocused() -> Bool {
        guard let focused = try? Self.copyAttribute(appElement, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        return CFEqual(focused, element)
    }

    func selectedRange() throws -> UTF16Range {
        guard let value = try Self.copyAttribute(element, kAXSelectedTextRangeAttribute) else { throw AXTargetError.unexpectedValue }
        return try Self.range(from: value)
    }

    func text(in range: UTF16Range) throws -> String {
        let parameter = try Self.axValue(for: range)
        var result: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &result)
        guard error == .success else { throw AXTargetError.attribute(error) }
        guard let string = result as? String else { throw AXTargetError.unexpectedValue }
        return string
    }

    func replace(_ range: UTF16Range, with text: String) throws {
        var error = AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, try Self.axValue(for: range))
        guard error == .success else { throw AXTargetError.attribute(error) }
        error = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        guard error == .success else { throw AXTargetError.attribute(error) }
    }

    // MARK: Helpers

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { throw AXTargetError.attribute(error) }
        return value
    }

    private static func range(from value: CFTypeRef) throws -> UTF16Range {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { throw AXTargetError.unexpectedValue }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { throw AXTargetError.unexpectedValue }
        return UTF16Range(location: range.location, length: range.length)
    }

    private static func axValue(for range: UTF16Range) throws -> AXValue {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { throw AXTargetError.unexpectedValue }
        return value
    }
}
