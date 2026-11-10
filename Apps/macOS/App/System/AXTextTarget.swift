import AppKit
import ApplicationServices
import Carbon.HIToolbox
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
    private let pid: pid_t

    private init(element: AXUIElement, appElement: AXUIElement) {
        var process: pid_t = 0
        AXUIElementGetPid(appElement, &process)
        self.pid = process
        self.element = element
        self.appElement = appElement
    }

    /// What `captureFocused` found.
    enum Capture {
        /// A text element we can write into with Accessibility.
        case target(AXTextTarget)
        /// No usable element (Accessibility off, our own app in front, nothing focused, no selection
        /// support). Text is delivered by paste, where that is allowed.
        case none
        /// A secure (password) field, or one we could not rule out as secure: no AX writes, no
        /// synthesized paste, the text is only copied.
        case secure
    }

    /// The focused text element of the frontmost app. Fails closed: secure event input being on, or
    /// any failure to read the focused element's role or subrole beyond "the attribute is not there",
    /// counts as a secure field.
    static func captureFocused() -> Capture {
        if IsSecureEventInputEnabled() { return .secure }
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return .none }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        let focused: CFTypeRef?
        do {
            focused = try copyAttribute(appElement, kAXFocusedUIElementAttribute)
        } catch AXTargetError.attribute(let error) where Self.isAbsent(error) {
            return .none
        } catch {
            return .secure
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .none }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        switch secureState(of: element) {
        case .secure, .unknown: return .secure
        case .notSecure: break
        }
        guard (try? copyAttribute(element, kAXSelectedTextRangeAttribute)) != nil else { return .none }
        let target = AXTextTarget(element: element, appElement: appElement)
        guard let selection = try? target.selectedRange(), (try? target.text(in: selection)) != nil else { return .none }
        return .target(target)
    }

    /// A focus/security witness for paste-only editors. This never reads or replaces their contents.
    static func capturePasteTarget() -> AXTextTarget? {
        guard !IsSecureEventInputEnabled(), AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        guard let value = try? copyAttribute(appElement, kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        guard case .notSecure = secureState(of: element) else { return nil }
        return AXTextTarget(element: element, appElement: appElement)
    }

    private enum SecureState { case secure, notSecure, unknown }

    /// An absent attribute is the normal case for most elements; any other error (a timeout, a dead
    /// element) leaves the question open.
    private static func isAbsent(_ error: AXError) -> Bool {
        error == .noValue || error == .attributeUnsupported
    }

    private static func secureState(of element: AXUIElement) -> SecureState {
        for attribute in [kAXSubroleAttribute, kAXRoleAttribute] {
            do {
                if let value = try copyAttribute(element, attribute) as? String,
                   value == "AXSecureTextField" || value.localizedCaseInsensitiveContains("secure") {
                    return .secure
                }
            } catch AXTargetError.attribute(let error) where isAbsent(error) {
                continue
            } catch {
                return .unknown
            }
        }
        return .notSecure
    }

    // MARK: TextTarget

    func isFocused() -> Bool {
        guard !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              case .notSecure = Self.secureState(of: element),
              let focused = try? Self.copyAttribute(appElement, kAXFocusedUIElementAttribute),
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

    func textLength() throws -> Int {
        guard isFocused() else { throw AXTargetError.unexpectedValue }
        if let number = try Self.copyAttribute(element, kAXNumberOfCharactersAttribute) as? NSNumber { return number.intValue }
        guard let value = try Self.copyAttribute(element, kAXValueAttribute) as? String else { throw AXTargetError.unexpectedValue }
        return value.utf16.count
    }

    func setSelectedRange(_ range: UTF16Range) throws {
        guard isFocused() else { throw AXTargetError.unexpectedValue }
        let error = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, try Self.axValue(for: range))
        guard error == .success else { throw AXTargetError.attribute(error) }
    }

    func replace(_ range: UTF16Range, with text: String) throws {
        guard isFocused() else { throw AXTargetError.unexpectedValue }
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
