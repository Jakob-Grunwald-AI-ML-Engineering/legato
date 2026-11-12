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

    /// The bound element; `refocus` binds a fresh element of the same editor (or, when allowed, another field).
    private var element: AXUIElement
    private let appElement: AXUIElement
    private let pid: pid_t
    private var textOperationSupported: Bool?
    /// What identifies the editor apart from the element object (`Editor`), read at capture and at each rebind.
    private var editor: Editor?

    /// Chromium web text reads through this: its value with the selection mapped into it, or its editable root.
    private var reader: AXFieldReader

    private init(element: AXUIElement, appElement: AXUIElement) {
        var process: pid_t = 0
        AXUIElementGetPid(appElement, &process)
        self.pid = process
        self.element = element
        self.appElement = appElement
        reader = AXFieldReader(element: AXElementText(element))
    }

    /// The field is Chromium web content: its reads go through `reader`.
    private var chromium: Bool { Self.isChromium(pid: pid) }

    /// What `captureFocused` found.
    enum Capture {
        /// A text element we can write into with Accessibility.
        case target(AXTextTarget)
        /// No usable element (Accessibility off, our own app in front, nothing focused, no selection support, or the
        /// element stayed unreadable after the warm-up). The take goes through the notch panel.
        case none
        /// A positively identified password field (`FieldSecurity`): the panel too, without History.
        case password
    }

    /// One read of the focused element; `unknown` when an Accessibility read failed (`prepareFocused` retries those).
    private enum Read {
        case capture(Capture)
        case unknown
    }

    /// Why the last capture came out as it did (the debug bridge reports it).
    private(set) static var lastCaptureNote = ""

    /// The focused text element of the frontmost app. Only a positively identified password field is one; a read that
    /// fails (a timeout, a stale element) is unreadable after `prepareFocused` retried it, and dictates through the panel.
    static func captureFocused() -> Capture {
        switch readFocused() {
        case .capture(let capture): return capture
        case .unknown: return .none
        }
    }

    private static func readFocused() -> Read {
        if IsSecureEventInputEnabled() { lastCaptureNote = "secure-input"; return .capture(.password) }
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { lastCaptureNote = "no-app"; return .capture(.none) }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        let focused: CFTypeRef?
        do {
            focused = try copyAttribute(appElement, kAXFocusedUIElementAttribute)
        } catch AXTargetError.attribute(let error) where Self.isAbsent(error) {
            lastCaptureNote = "no-focus"
            return .capture(.none)
        } catch AXTargetError.attribute(let error) {
            lastCaptureNote = "focus-error \(error.rawValue)"
            return .unknown
        } catch {
            lastCaptureNote = "focus-error"
            return .unknown
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { lastCaptureNote = "no-focus"; return .capture(.none) }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        switch security(of: element) {
        case .password: lastCaptureNote = "password"; return .capture(.password)
        case .unknown: lastCaptureNote = "role-error"; return .unknown
        case .notPassword: break
        }
        let target = AXTextTarget(element: element, appElement: appElement)
        if target.chromium {
            // A web editor reads through its value or its editable root (`AXFieldReader`); one that does not read whole
            // dictates through the panel from the start.
            guard target.reader.readsWhole() else { lastCaptureNote = "unreadable-text"; return .capture(.none) }
        } else {
            guard (try? copyAttribute(element, kAXSelectedTextRangeAttribute)) != nil else { lastCaptureNote = "no-selection"; return .capture(.none) }
            guard let selection = try? target.selectedRange(), (try? target.text(in: selection)) != nil else {
                lastCaptureNote = "unreadable-text"; return .capture(.none)
            }
        }
        target.editor = Editor(of: element)
        lastCaptureNote = "target"
        return .capture(.target(target))
    }

    /// What a typed insert at the end of a take can rely on in the field it started in.
    enum PasteWitness {
        /// The focused element: the insert goes ahead only while it still has focus.
        case element(AXTextTarget)
        /// No element could be read (nothing focused that Accessibility exposes): the app and the key guards decide.
        case unreadable
        /// A password field: the insert goes ahead while its element (when one was read) keeps focus and its length
        /// (when exposed) is unchanged. Secure input hides the user's keys from Legato's tap, so the length stands in.
        case password(AXTextTarget?, length: Int?)

        var isPassword: Bool { if case .password = self { true } else { false } }
        /// An element was read, so focus on it can be checked.
        var verifiesFocus: Bool {
            switch self {
            case .element: true
            case .unreadable: false
            case .password(let target, _): target != nil
            }
        }

        /// The witnessed field still has focus (an unreadable one: no element to check, the app guard decides).
        @MainActor func stillFocused() -> Bool {
            switch self {
            case .element(let target): return target.isFocused()
            case .unreadable: return true
            case .password(let target, let length):
                guard let target else { return true }
                return target.hasFocus() && (length == nil || target.characterCount() == length)
            }
        }
    }

    /// A focus witness for typed inserts. This never reads or replaces the field's contents.
    static func capturePasteWitness() -> PasteWitness {
        let secureInput = IsSecureEventInputEnabled()
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return secureInput ? .password(nil, length: nil) : .unreadable }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        guard let value = (try? copyAttribute(appElement, kAXFocusedUIElementAttribute)) ?? nil,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return secureInput ? .password(nil, length: nil) : .unreadable }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        let target = AXTextTarget(element: element, appElement: appElement)
        switch security(of: element) {
        case .password: return .password(target, length: target.characterCount())
        case .notPassword: return .element(target)
        // Unanswered like the capture, which then dictates through the panel: the app and key guards decide.
        case .unknown: return .unreadable
        }
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

    /// Re-requests a Chromium app's tree although it shows a focused element: the element failed to answer (a stale
    /// tree after the page or the app's web content was rebuilt). Paced like `requestTree`.
    private static func refreshTree(pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier, AXIsProcessTrusted(), isChromium(pid: pid),
              warmup.shouldRequest(pid: pid, now: .now) else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        _ = try? copyAttribute(app, kAXRoleAttribute)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Before a capture (every take): request the frontmost app's tree if it is Chromium, and while that tree is still
    /// being built (`AccessibilityWarmup.budget` after the request) wait for the focused field to become readable. A
    /// read that fails refreshes the tree once and retries for another `budget`; still failing, the capture dictates
    /// through the panel.
    static func prepareFocused() async {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        requestTree(pid: pid)
        var deadline = warmup.retryDeadline(pid: pid, now: .now)
        var refreshed = false
        while !Task.isCancelled {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            switch readFocused() {
            case .unknown:
                if !refreshed {
                    refreshed = true
                    refreshTree(pid: pid)
                    let extended = ContinuousClock.now + AccessibilityWarmup.budget
                    deadline = max(deadline ?? extended, extended)
                }
            case .capture(.none): break
            case .capture: return
            }
            guard let deadline, ContinuousClock.now < deadline else { return }
            try? await Task.sleep(for: AccessibilityWarmup.interval)
        }
    }

    /// Whether Accessibility writes land exactly in this field. Chromium's web content reports success for an
    /// AXSelectedText write and changes nothing.
    var editsInPlace: Bool { !Self.isChromium(pid: pid) }
    /// Chromium fields are edited with synthetic keys, each read back (`MacFieldQueue`). Only an editable element
    /// takes keys: the page itself (AXWebArea) reads as text too, and a letter typed there can be a site's shortcut.
    var typesKeys: Bool { Self.isChromium(pid: pid) && editable }
    private var editableCache: Bool?
    private var editable: Bool {
        if let editableCache { return editableCache }
        let value = Self.isEditable(element)
        editableCache = value
        return value
    }
    private static func isEditable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue { return true }
        return (try? copyAttribute(element, "AXEditableAncestor")) != nil
    }
    var inputMark: Int { RealInput.shared.count }

    /// An absent attribute is the normal case for most elements; any other error (a timeout, a dead
    /// element) leaves the question open.
    private static func isAbsent(_ error: AXError) -> Bool {
        error == .noValue || error == .attributeUnsupported
    }

    private static func probe(_ element: AXUIElement, _ attribute: String) -> AXProbe {
        do { return .value(try copyAttribute(element, attribute) as? String) }
        catch AXTargetError.attribute(let error) where isAbsent(error) { return .absent }
        catch { return .failed }
    }

    /// Secure event input, or the element's subrole or role (`FieldSecurity.classify`).
    private static func security(of element: AXUIElement) -> FieldSecurity {
        FieldSecurity.classify(secureInput: IsSecureEventInputEnabled(),
                               subrole: probe(element, kAXSubroleAttribute), role: probe(element, kAXRoleAttribute))
    }

    /// This app is in front with this element focused; unlike `isFocused`, also for a password field.
    func hasFocus() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = try? Self.copyAttribute(appElement, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        return CFEqual(focused, element)
    }

    /// The field's character count, where it exposes one (a password field's masked length); never its text.
    func characterCount() -> Int? {
        (try? Self.copyAttribute(element, kAXNumberOfCharactersAttribute)) as? Int
    }

    // MARK: TextTarget

    func isFocused() -> Bool {
        guard !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              Self.security(of: element) == .notPassword,
              let focused = try? Self.copyAttribute(appElement, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        return CFEqual(focused, element)
    }

    /// The bound element lost focus while this app stayed in front: binds the focused element when it is a text field
    /// with a readable caret (an editable one for a keystroke field) and either belongs to this editor or `allowOther`.
    /// Chromium recreates a web field's element when the page rewrites its DOM (Enter, a new list line, a re-render) and
    /// moves focus between nested editable elements, so the editor the user is typing in shows up as a new element.
    func refocus(allowOther: Bool) -> FieldRefocus {
        guard !IsSecureEventInputEnabled(), AXIsProcessTrusted(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let value = (try? Self.copyAttribute(appElement, kAXFocusedUIElementAttribute)) ?? nil,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return .lost }
        let focused = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)
        // A keystroke field binds only an editable element (the page itself reads as text too).
        guard Self.security(of: focused) == .notPassword, !typesKeys || Self.isEditable(focused) else { return .lost }
        let focusedReader = AXFieldReader(element: AXElementText(focused))
        let readable: Bool
        if chromium {
            // Through the element's value or its editable root, like every read of a web editor.
            readable = focusedReader.readsWhole()
        } else if let rangeValue = (try? Self.copyAttribute(focused, kAXSelectedTextRangeAttribute)) ?? nil,
                  let selection = try? Self.range(from: rangeValue) {
            readable = Self.readable(focused, selection)
        } else {
            readable = false
        }
        let same = sameEditor(focused)
        // This editor has focus but reads neither itself nor through its root: the take goes on in the panel.
        guard readable else { return same ? .unreadable : .lost }
        guard same || allowOther else { return .declined }
        element = focused
        reader = focusedReader
        editableCache = nil; textOperationSupported = nil
        editor = Editor(of: focused)
        return .rebound(sameEditor: same)
    }

    private static func readable(_ element: AXUIElement, _ range: UTF16Range) -> Bool {
        guard let parameter = try? axValue(for: range) else { return false }
        var result: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &result) == .success
            && result is String
    }

    /// Whether `focused` is the editor this target was bound to: the bound element itself, an element inside it, its
    /// editable root, an element under the same editable root, or a fresh element in the bound one's place (same window,
    /// role, DOM id and classes, and horizontal frame: a growing field keeps its x and width).
    private func sameEditor(_ focused: AXUIElement) -> Bool {
        if CFEqual(focused, element) { return true }
        if Self.ancestors(of: focused).contains(where: { CFEqual($0, element) }) { return true }
        if Self.ancestors(of: element).contains(where: { CFEqual($0, focused) }) { return true }
        guard let editor else { return false }
        let candidate = Editor(of: focused)
        if let root = editor.root, let other = candidate.root, CFEqual(root, other) { return true }
        if let root = editor.root, CFEqual(root, focused) { return true }
        return editor.matches(candidate)
    }

    private static func ancestors(of element: AXUIElement, limit: Int = 16) -> [AXUIElement] {
        var chain: [AXUIElement] = []
        var current = element
        while chain.count < limit, let value = (try? copyAttribute(current, kAXParentAttribute)) ?? nil,
              CFGetTypeID(value) == AXUIElementGetTypeID() {
            current = unsafeDowncast(value, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(current, messagingTimeout)
            chain.append(current)
        }
        return chain
    }

    /// What identifies an editor besides its element object. Chromium keeps the window and the editable root's DOM
    /// attributes when it recreates the element objects.
    @MainActor private struct Editor {
        let window: AXUIElement?
        /// The outermost editable element around it (Chromium: AXHighestEditableAncestor), or the nearest one.
        let root: AXUIElement?
        let role: String?
        let subrole: String?
        let domID: String?
        let domClasses: [String]?
        /// The frame's x and width, rounded: a field that grows with its text keeps both.
        let x: Int?
        let width: Int?

        init(of element: AXUIElement) {
            func string(_ attribute: String) -> String? { (try? AXTextTarget.copyAttribute(element, attribute)) as? String }
            func ref(_ attribute: String) -> AXUIElement? {
                guard let value = (try? AXTextTarget.copyAttribute(element, attribute)) ?? nil,
                      CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                return unsafeDowncast(value, to: AXUIElement.self)
            }
            window = ref(kAXWindowAttribute)
            root = ref("AXHighestEditableAncestor") ?? ref("AXEditableAncestor")
            role = string(kAXRoleAttribute)
            subrole = string(kAXSubroleAttribute)
            domID = string("AXDOMIdentifier").flatMap { $0.isEmpty ? nil : $0 }
            domClasses = ((try? AXTextTarget.copyAttribute(element, "AXDOMClassList")) as? [String]).flatMap { $0.isEmpty ? nil : $0 }
            var point = CGPoint.zero, size = CGSize.zero
            if let value = (try? AXTextTarget.copyAttribute(element, kAXPositionAttribute)) ?? nil, CFGetTypeID(value) == AXValueGetTypeID(),
               AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgPoint, &point) { x = Int(point.x.rounded()) } else { x = nil }
            if let value = (try? AXTextTarget.copyAttribute(element, kAXSizeAttribute)) ?? nil, CFGetTypeID(value) == AXValueGetTypeID(),
               AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size) { width = Int(size.width.rounded()) } else { width = nil }
        }

        /// A fresh element in the same place: same window, role and subrole, DOM id and classes, x and width. Something
        /// beyond the role must be known, so two plain fields of one window never match by role alone.
        func matches(_ other: Editor) -> Bool {
            guard let window, let otherWindow = other.window, CFEqual(window, otherWindow), role != nil else { return false }
            guard domID != nil || domClasses != nil || (x != nil && width != nil) else { return false }
            return role == other.role && subrole == other.subrole && domID == other.domID && domClasses == other.domClasses
                && x == other.x && width == other.width
        }
    }

    func selectedRange() throws -> UTF16Range {
        if chromium { return try reader.selectedRange() }
        guard let value = try Self.copyAttribute(element, kAXSelectedTextRangeAttribute) else { throw AXTargetError.unexpectedValue }
        return try Self.range(from: value)
    }

    func text(in range: UTF16Range) throws -> String {
        if chromium { return try reader.text(in: range) }
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
        if chromium { return try reader.textLength() }
        if let number = try Self.copyAttribute(element, kAXNumberOfCharactersAttribute) as? NSNumber { return number.intValue }
        guard let value = try Self.copyAttribute(element, kAXValueAttribute) as? String else { throw AXTargetError.unexpectedValue }
        return value.utf16.count
    }

    func setSelectedRange(_ range: UTF16Range) throws {
        guard isFocused() else { throw AXTargetError.unexpectedValue }
        let (element, range) = try selectionTarget(range)
        let error = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, try Self.axValue(for: range))
        guard error == .success else { throw AXTargetError.attribute(error) }
    }

    /// Where a selection set goes, and `range` as that element counts it: a web editor's read source, in its selection
    /// space (`AXFieldReader.selectionSpace`).
    private func selectionTarget(_ range: UTF16Range) throws -> (AXUIElement, UTF16Range) {
        guard chromium else { return (element, range) }
        let mapped = try reader.selectionSpace(range)
        return ((reader.source as? AXElementText)?.element ?? element, mapped)
    }

    func replace(_ range: UTF16Range, with text: String) throws {
        guard isFocused(), editsInPlace else { throw AXTargetError.unexpectedValue }
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

    // MARK: Keystrokes

    /// Modifiers that turn a key into a shortcut (fn turns the arrows into Home/End and Backspace into forward delete).
    private static let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]

    /// One key into this field, only while every guard holds: no secure input, this app in front with this element
    /// focused, no real key or click since `mark`, no modifier held, and the selection still `selection`. The input
    /// mark is checked again right before the key goes out.
    func press(_ key: FieldKey, mark: Int, selection: UTF16Range) throws {
        guard isFocused() else { throw FieldKeyRefusal.notFocused }
        guard RealInput.shared.count == mark else { throw FieldKeyRefusal.userInput }
        guard CGEventSource.flagsState(.hidSystemState).intersection(Self.modifiers).isEmpty else { throw FieldKeyRefusal.modifiersHeld }
        guard (try? selectedRange()) == selection else { throw FieldKeyRefusal.selectionMoved }
        guard RealInput.shared.count == mark else { throw FieldKeyRefusal.userInput }
        let sent: Bool
        switch key {
        case .left: sent = SyntheticKeys.tap(kVK_LeftArrow)
        case .right: sent = SyntheticKeys.tap(kVK_RightArrow)
        case .backspace: sent = SyntheticKeys.tap(kVK_Delete)
        case .arrows(let left, let count): sent = SyntheticKeys.taps(left ? kVK_LeftArrow : kVK_RightArrow, count: count)
        case .hop(let hop):
            // The left-hand modifiers: Right Option and Right Command are Legato's own shortcuts.
            switch hop {
            case .wordLeft: sent = SyntheticKeys.chord(kVK_Option, flag: .maskAlternate, kVK_LeftArrow)
            case .wordRight: sent = SyntheticKeys.chord(kVK_Option, flag: .maskAlternate, kVK_RightArrow)
            case .lineStart: sent = SyntheticKeys.chord(kVK_Command, flag: .maskCommand, kVK_LeftArrow)
            case .lineEnd: sent = SyntheticKeys.chord(kVK_Command, flag: .maskCommand, kVK_RightArrow)
            case .documentStart: sent = SyntheticKeys.chord(kVK_Command, flag: .maskCommand, kVK_UpArrow)
            case .documentEnd: sent = SyntheticKeys.chord(kVK_Command, flag: .maskCommand, kVK_DownArrow)
            }
        case .text(let character):
            let text = String(character)
            sent = SyntheticEvent.typeable(text) ? SyntheticKeys.type(text) : paste(text, at: selection)
        }
        guard sent else { throw FieldKeyRefusal.unavailable }
    }

    /// The caret through Accessibility, under the key guards (no modifier check: nothing is typed). Chromium may or
    /// may not honour it; the queue reads it back and remembers per field which way works.
    func setCaret(_ range: UTF16Range, mark: Int, selection: UTF16Range) throws {
        guard isFocused() else { throw FieldKeyRefusal.notFocused }
        guard RealInput.shared.count == mark else { throw FieldKeyRefusal.userInput }
        guard (try? selectedRange()) == selection else { throw FieldKeyRefusal.selectionMoved }
        guard RealInput.shared.count == mark else { throw FieldKeyRefusal.userInput }
        guard let (element, range) = try? selectionTarget(range) else { throw FieldKeyRefusal.unavailable }
        let error = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, try Self.axValue(for: range))
        guard error == .success else { throw FieldKeyRefusal.unavailable }
    }

    /// The bound element: the same field bound again is equal (`CFEqual`), so the queue's per-field memory follows it.
    var fieldKey: AnyHashable? { AnyHashable(ElementKey(element: element)) }
    private struct ElementKey: Hashable {
        let element: AXUIElement
        static func == (a: Self, b: Self) -> Bool { CFEqual(a.element, b.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    /// A line break, tab or oversized grapheme: never a Return or Tab key. It is pasted (⌘V, paired), the field is
    /// watched until it shows the text, and the clipboard comes back unless someone else wrote to it meanwhile.
    private func paste(_ text: String, at selection: UTF16Range) -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteService.Snapshot(of: pasteboard)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: PasteService.transientType)
        guard pasteboard.writeObjects([item]) else { snapshot.restore(to: pasteboard); return false }
        let ours = pasteboard.changeCount
        guard SyntheticKeys.commandV() else { snapshot.restore(to: pasteboard); return false }
        let range = UTF16Range(location: selection.location, length: text.utf16.count)
        for _ in 0..<50 where (try? self.text(in: range)) != text { usleep(20_000) }
        if pasteboard.changeCount == ours { snapshot.restore(to: pasteboard) }
        return true
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

/// One element's raw text reads over Accessibility (`AXFieldReader` decides how they fit together).
@MainActor final class AXElementText: AXTextElement {
    let element: AXUIElement
    init(_ element: AXUIElement) {
        self.element = element
        AXUIElementSetMessagingTimeout(element, AXTextTarget.messagingTimeout)
    }

    private func copy(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
    private func parameter(_ attribute: String, _ argument: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, argument, &value) == .success ? value : nil
    }

    var axValue: String? { copy(kAXValueAttribute) as? String }
    var axCharacterCount: Int? { (copy(kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue }
    var axSelection: UTF16Range? {
        guard let value = copy(kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) else { return nil }
        return UTF16Range(location: range.location, length: range.length)
    }
    func axString(in range: UTF16Range) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let argument = AXValueCreate(.cfRange, &cfRange) else { return nil }
        return parameter(kAXStringForRangeParameterizedAttribute, argument) as? String
    }
    var axMarkerText: String? {
        guard let range = parameter("AXTextMarkerRangeForUIElement", element) else { return nil }
        return parameter("AXStringForTextMarkerRange", range) as? String
    }
    func axAfterHiddenBreak(end: Bool) -> Bool? {
        guard let value = copy("AXSelectedTextMarkerRange"), CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
        let selection = unsafeDowncast(value, to: AXTextMarkerRange.self)
        let marker = end ? AXTextMarkerRangeCopyEndMarker(selection) : AXTextMarkerRangeCopyStartMarker(selection)
        // No marker before it: the caret is at the very start, not after a break.
        guard let previous = parameter("AXPreviousTextMarkerForTextMarker", marker) else { return false }
        guard let span = parameter("AXTextMarkerRangeForUnorderedTextMarkers", [previous, marker] as CFArray),
              let text = parameter("AXStringForTextMarkerRange", span) as? String else { return nil }
        return text.isEmpty
    }
    var axEditableRoots: [any AXTextElement] {
        var roots: [AXUIElement] = []
        for attribute in ["AXEditableAncestor", "AXHighestEditableAncestor"] {
            guard let value = copy(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            let root = unsafeDowncast(value, to: AXUIElement.self)
            if !CFEqual(root, element), !roots.contains(where: { CFEqual($0, root) }) { roots.append(root) }
        }
        return roots.map { AXElementText($0) }
    }
}
