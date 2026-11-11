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
    private var textOperationSupported: Bool?

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

    /// What a typed insert at the end of a take can rely on in the field it started in.
    enum PasteWitness {
        /// The focused element: the insert goes ahead only while it still has focus.
        case element(AXTextTarget)
        /// No element could be read (nothing focused that Accessibility exposes): the app and the key guards decide.
        case unreadable
        /// A secure field, or one that could not be ruled out: copy only.
        case secure
    }

    /// A focus/security witness for typed inserts. This never reads or replaces the field's contents.
    static func capturePasteWitness() -> PasteWitness {
        if IsSecureEventInputEnabled() { return .secure }
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return .unreadable }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        let value: CFTypeRef?
        do { value = try copyAttribute(appElement, kAXFocusedUIElementAttribute) }
        catch AXTargetError.attribute(let error) where isAbsent(error) { return .unreadable }
        catch { return .secure }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unreadable }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        guard case .notSecure = secureState(of: element) else { return .secure }
        return .element(AXTextTarget(element: element, appElement: appElement))
    }

    // MARK: Chromium

    private static var warmup = AccessibilityWarmup()
    private static var chromium: [pid_t: Bool] = [:]

    /// Whether `pid` runs on Chromium (cached per process): its web text can be read, not replaced, through
    /// Accessibility.
    static func isChromium(pid: pid_t) -> Bool {
        if let known = chromium[pid] { return known }
        guard let app = NSRunningApplication(processIdentifier: pid), let bundle = app.bundleURL else { return false }
        let frameworks = bundle.appending(path: "Contents/Frameworks", directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        let result = ChromiumHost.matches(executableName: app.executableURL?.lastPathComponent, frameworks: names) {
            FileManager.default.fileExists(atPath: frameworks.appending(path: $0).path)
        }
        chromium[pid] = result
        return result
    }

    /// Asks a Chromium app that exposes no focused element to build its Accessibility tree (`AccessibilityWarmup`
    /// paces the requests). Chrome, Edge, their web apps and Electron turn on their native Accessibility API when a
    /// client reads the application's role (Chromium does this for Voice Control-style assistive apps); the tree is
    /// there about 0.1 s later. Older Electron apps also honour `AXManualAccessibility`. `AXEnhancedUserInterface`
    /// is never set: it has window-manager side effects, and Chrome debounces it by seconds.
    static func requestTree(pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier, AXIsProcessTrusted(), isChromium(pid: pid) else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var focused: CFTypeRef?
        guard isAbsent(AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)),
              warmup.shouldRequest(pid: pid, now: .now) else { return }
        _ = try? copyAttribute(app, kAXRoleAttribute)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// A process ended: forget what was learned about its pid.
    static func forget(pid: pid_t) {
        warmup.forget(pid: pid)
        chromium[pid] = nil
    }

    /// Before a capture: request the frontmost app's tree if it is Chromium, and while that tree is still being
    /// built (`AccessibilityWarmup.budget` after the request) wait for the focused field to become readable.
    static func prepareFocused() async {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        requestTree(pid: pid)
        _ = await AccessibilityWarmup.retry(until: warmup.retryDeadline(pid: pid, now: .now)) { () -> Bool? in
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return true }
            if case .none = captureFocused() { return nil }
            return true
        }
    }

    /// Whether Accessibility writes land exactly in this field. Chromium's web content reports success for an
    /// AXSelectedText write and changes nothing.
    var editsInPlace: Bool { !Self.isChromium(pid: pid) }

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
        if !editsInPlace { return try replaceByPaste(range, with: text) }
        let original = try self.text(in: range)
        // Streaming appends already own this caret. Avoid an unnecessary browser selection
        // mutation, which can scroll the editor or briefly highlight its contents.
        if try selectedRange() != range { try setSelectedRange(range) }
        guard isFocused(), try selectedRange() == range, try self.text(in: range) == original else {
            throw AXTargetError.unexpectedValue
        }
        if supportsTextOperation() {
            try replaceSelectedMarkerRange(range, original: original, with: text)
        } else {
            let error = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
            guard error == .success else { throw AXTargetError.attribute(error) }
        }
    }

    /// For a field that takes pastes, not Accessibility writes: before anything is written, the app is still in front
    /// with no modifier held, and exactly `range` is selected with its text unchanged.
    func prepareReplace(_ range: UTF16Range) throws {
        guard !editsInPlace else { return }
        guard isFocused(), Self.pasteAllowed(pid: pid) else { throw AXTargetError.unexpectedValue }
        if try selectedRange() != range {
            let original = try text(in: range)
            try setSelectedRange(range)
            guard Self.waitFor({ (try? self.selectedRange()) == range }), try text(in: range) == original else {
                throw AXTargetError.unexpectedValue
            }
        }
    }

    /// A synthesized paste or Delete lands in the app that started the edit, never in a secure field, never while the
    /// user holds a modifier (the key would arrive as a shortcut).
    private static func pasteAllowed(pid: pid_t) -> Bool {
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && !IsSecureEventInputEnabled()
            && CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty
    }

    /// Chromium's web content ignores Accessibility text writes but moves its selection. One replacement (a Magic
    /// edit or its undo) selects exactly `range`, pastes the text (or deletes the selection) as the user would, and
    /// waits for the field to show it. The clipboard comes back once the paste has landed.
    private func replaceByPaste(_ range: UTF16Range, with text: String) throws {
        try prepareReplace(range)
        guard Self.pasteAllowed(pid: pid), try selectedRange() == range else { throw AXTargetError.unexpectedValue }
        if range.length == 0, text.isEmpty { return }
        let pasteboard = NSPasteboard.general
        var restore: (snapshot: PasteService.Snapshot, count: Int)?
        if text.isEmpty {
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: down) else { continue }
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.userData)
                event.post(tap: .cghidEventTap)
            }
        } else {
            let snapshot = PasteService.Snapshot(of: pasteboard)
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            item.setData(Data(), forType: PasteService.transientType)
            guard pasteboard.writeObjects([item]) else { throw AXTargetError.unexpectedValue }
            restore = (snapshot, pasteboard.changeCount)
            PasteService.postCommandV()
        }
        let caret = UTF16Range(location: range.location + text.utf16.count, length: 0)
        let landed = Self.waitFor {
            (try? self.selectedRange()) == caret && (try? self.text(in: .init(location: range.location, length: text.utf16.count))) == text
        }
        if let restore, pasteboard.changeCount == restore.count { restore.snapshot.restore(to: pasteboard) }
        guard landed else { throw AXTargetError.unexpectedValue }
    }

    /// Polls `condition` while the other app applies an asynchronous change: at most about a second.
    private static func waitFor(_ condition: () -> Bool) -> Bool {
        for _ in 0..<50 {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    private func supportsTextOperation() -> Bool {
        if let textOperationSupported { return textOperationSupported }
        var names: CFArray?
        let result = AXUIElementCopyParameterizedAttributeNames(element, &names)
        let supported = result == .success && (names as? [String])?.contains("AXTextOperation") == true
        textOperationSupported = supported
        return supported
    }

    /// WebKit advertises AXSelectedText as settable but its setSelectedText implementation is
    /// empty. Its advertised AXTextOperation performs an exact scoped replacement instead.
    /// Marker text and bounds must both agree with the requested AX range: never search for
    /// matching words elsewhere, and never replace the document's AXValue.
    private func replaceSelectedMarkerRange(_ range: UTF16Range, original: String, with text: String) throws {
        guard let markers = try Self.copyAttribute(element, "AXSelectedTextMarkerRange"),
              let markerText = try parameter("AXStringForTextMarkerRange", markers) as? String,
              markerText == original,
              let markerBounds = try parameter("AXBoundsForTextMarkerRange", markers),
              let rangeBounds = try parameter(kAXBoundsForRangeParameterizedAttribute, Self.axValue(for: range)),
              try Self.rect(from: markerBounds) == Self.rect(from: rangeBounds),
              isFocused(), try selectedRange() == range, try self.text(in: range) == original else {
            throw AXTargetError.unexpectedValue
        }
        // ReplacePreserveCase keeps the supplied text exactly; ordinary Replace changes its
        // capitalization. Disable WebKit's smart spacing/quotes for the same reason.
        let operation: NSDictionary = [
            "AXTextOperationMarkerRanges": [markers],
            "AXTextOperationType": "TextOperationReplacePreserveCase",
            "AXTextOperationReplacementString": text,
            "AXTextOperationSmartReplace": false
        ]
        let result = try parameter("AXTextOperation", operation) as? [String]
        guard result == [text], isFocused(),
              try self.text(in: .init(location: range.location, length: text.utf16.count)) == text else {
            throw AXTargetError.unexpectedValue
        }
        // WebKit selects a nonempty replacement. Every TextTarget replacement promises a
        // caret after it, so collapse only that verified replacement and confirm the result.
        let caret = UTF16Range(location: range.location + text.utf16.count, length: 0)
        if try selectedRange() != caret { try setSelectedRange(caret) }
        guard try selectedRange() == caret else { throw AXTargetError.unexpectedValue }
    }

    private func parameter(_ key: String, _ value: CFTypeRef) throws -> CFTypeRef? {
        var result: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element, key as CFString, value, &result)
        guard error == .success else { throw AXTargetError.attribute(error) }
        return result
    }

    private static func rect(from value: CFTypeRef) throws -> CGRect {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { throw AXTargetError.unexpectedValue }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgRect, &rect) else { throw AXTargetError.unexpectedValue }
        return rect
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
