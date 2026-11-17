#!/usr/bin/env swift
// mac-ax-probe: measures how the focused text field of any Mac app answers Accessibility, for the Mac field queue.
// Prints one JSON object per line (`kind` names the line). Internal measuring tool; never shipped.
//
// Build (the Mac test VM has no compiler; build on the host and stage the binary in the VM's `incoming` share):
//   swiftc -O -o mac-ax-probe scripts/device/mac-ax-probe.swift
// Run it in the GUEST (never against the host desktop) from a process that has Accessibility (guest Settings), with
// the field focused in the frontmost app. Chromium builds its AX tree on request: the probe sets AXManualAccessibility
// on the app first (`--no-warm` skips it).
//
//   mac-ax-probe info                       the focused element: app, role, advertised/settable attributes
//   mac-ax-probe fill N [--caret end|mid|start]
//                                           make the field hold N characters (AXValue set; else select-all + paste)
//   mac-ax-probe caret start|mid|end       move the caret (AXSelectedTextRange) without changing the text
//   mac-ax-probe read [--reps 30]           time of AXValue, AXNumberOfCharacters, AXSelectedTextRange,
//                                           AXStringForRange (min/median/p90/max ms) at the field's current length
//   mac-ax-probe watch [--secs 10] [--on element|app|both]
//                                           print value/selection notifications as they arrive (type in the field)
//   mac-ax-probe write hunk|value [--reps 5] [--on ...] [--poll value|range]
//                                           an AX replace of a 20-char hunk mid-text (hunk: AXSelectedTextRange +
//                                           AXSelectedText, or WebKit's AXTextOperation) or of the whole AXValue; the
//                                           time until a read shows it and the notifications that followed
//   mac-ax-probe keys [--type STR] [--backspaces N] [--then STR] [--reps 3] [--on ...]
//                                           a back-to-back burst of synthetic unicode keys and backspaces at the end
//                                           of the text (caret moved there with Cmd+Down first), no waits between
//                                           keys; whether the end state lands and how long a read takes to show it
//
// Times are milliseconds from CLOCK_UPTIME_RAW. Output is a measurement, not a verdict; the raw lines are the record.
import AppKit
import ApplicationServices

// MARK: Output and time

// Monotonic system uptime in milliseconds (the clock the app's edit journal uses).
func ms() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e6 }
func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
func emit(_ d: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    fflush(stdout)
}
func die(_ message: String) -> Never { emit(["kind": "error", "message": message]); exit(1) }

// MARK: Accessibility helpers

func attr(_ el: AXUIElement, _ name: String) -> (CFTypeRef?, AXError) {
    var v: CFTypeRef?
    let e = AXUIElementCopyAttributeValue(el, name as CFString, &v)
    return (v, e)
}
func axRange(_ r: CFRange) -> AXValue { var r = r; return AXValueCreate(.cfRange, &r)! }
func readValue(_ el: AXUIElement) -> String? { attr(el, "AXValue").0 as? String }
func readCount(_ el: AXUIElement) -> Int? { (attr(el, "AXNumberOfCharacters").0 as? NSNumber)?.intValue }
func readSelection(_ el: AXUIElement) -> CFRange? {
    guard let v = attr(el, kAXSelectedTextRangeAttribute).0, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var r = CFRange()
    return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
}
func param(_ el: AXUIElement, _ name: String, _ arg: CFTypeRef) -> (CFTypeRef?, AXError) {
    var v: CFTypeRef?
    let e = AXUIElementCopyParameterizedAttributeValue(el, name as CFString, arg, &v)
    return (v, e)
}
func readRange(_ el: AXUIElement, _ r: CFRange) -> String? { param(el, "AXStringForRange", axRange(r)).0 as? String }
func settable(_ el: AXUIElement, _ name: String) -> Bool {
    var b: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(el, name as CFString, &b) == .success && b.boolValue
}
func names(_ el: AXUIElement, parameterized: Bool) -> [String] {
    var out: CFArray?
    _ = parameterized ? AXUIElementCopyParameterizedAttributeNames(el, &out) : AXUIElementCopyAttributeNames(el, &out)
    return (out as? [String]) ?? []
}
func utf16Slice(_ s: String, _ loc: Int, _ len: Int) -> String? {
    let u = Array(s.utf16)
    guard loc >= 0, len >= 0, loc + len <= u.count else { return nil }
    return String(decoding: u[loc..<(loc + len)], as: UTF16.self)
}

struct Target { let element: AXUIElement; let app: AXUIElement; let pid: pid_t }

func findFocused(warm: Bool) -> Target {
    guard AXIsProcessTrusted() else { die("this process is not trusted for Accessibility (grant it in the guest's Settings)") }
    var pid: pid_t = 0
    let system = AXUIElementCreateSystemWide()
    if let v = attr(system, kAXFocusedUIElementAttribute).0, CFGetTypeID(v) == AXUIElementGetTypeID() {
        AXUIElementGetPid(v as! AXUIElement, &pid)
    }
    if pid == 0, let front = NSWorkspace.shared.frontmostApplication { pid = front.processIdentifier }
    guard pid != 0 else { die("no frontmost app") }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 5)
    if warm {
        _ = attr(app, kAXRoleAttribute)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
    for _ in 0..<40 {
        if let v = attr(app, kAXFocusedUIElementAttribute).0, CFGetTypeID(v) == AXUIElementGetTypeID() {
            let el = v as! AXUIElement
            AXUIElementSetMessagingTimeout(el, 5)
            return Target(element: el, app: app, pid: pid)
        }
        usleep(100_000)
    }
    die("the app (pid \(pid)) exposes no focused element")
}

// MARK: Notifications

var events: [(t: Double, name: String, role: String, sameAsFocused: Bool, via: String)] = []
var focusedForCallback: AXUIElement?
let callback: AXObserverCallback = { _, element, notification, refcon in
    let t = ms()
    let role = (attr(element, kAXRoleAttribute).0 as? String) ?? "?"
    let same = focusedForCallback.map { CFEqual($0, element) } ?? false
    let via = refcon.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? ""
    events.append((t, notification as String, role, same, via))
}
let observed = [kAXValueChangedNotification, kAXSelectedTextChangedNotification]
var viaStrings: [UnsafeMutablePointer<CChar>] = []

/// Registers on the app element and/or the focused element; returns the AXError of each registration.
func observe(_ t: Target, on: String) -> [String: Any] {
    focusedForCallback = t.element
    var obs: AXObserver?
    guard AXObserverCreate(t.pid, callback, &obs) == .success, let observer = obs else { return ["observer": "create failed"] }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    var result: [String: Any] = [:]
    for (label, el) in [("element", t.element), ("app", t.app)] where on == "both" || on == label {
        let tag = strdup(label)!
        viaStrings.append(tag)
        for n in observed {
            result["\(label):\(n)"] = Int(AXObserverAddNotification(observer, el, n as CFString, tag).rawValue)
        }
    }
    keepAlive.append(observer)
    return result
}
var keepAlive: [AnyObject] = []

func pump(_ seconds: Double) {
    let end = ms() + seconds * 1000
    while ms() < end { CFRunLoopRunInMode(.defaultMode, 0.001, false) }
}
/// Polls `done` (pumping the run loop between polls) until it holds or `timeoutMs` passes; returns elapsed ms or nil.
func waitUntil(_ timeoutMs: Double, _ done: () -> Bool) -> Double? {
    let start = ms()
    while ms() - start < timeoutMs {
        if done() { return ms() - start }
        CFRunLoopRunInMode(.defaultMode, 0.0005, false)
    }
    return done() ? ms() - start : nil
}
func eventLines(since t0: Double) -> [[String: Any]] {
    events.map { ["name": $0.name.replacingOccurrences(of: "AX", with: ""), "ms": r2($0.t - t0), "role": $0.role,
                  "focusedElement": $0.sameAsFocused, "registeredOn": $0.via] }
}

// MARK: Synthetic keys

let source = CGEventSource(stateID: .hidSystemState)
enum Stroke { case char(String), backspace, commandDown }
func post(_ strokes: [Stroke]) -> Double {
    var evs: [CGEvent] = []
    func key(_ code: CGKeyCode, _ down: Bool, flags: CGEventFlags = [], unicode: String? = nil) {
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
        e.flags = flags
        if let u = unicode { let units = Array(u.utf16); e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units) }
        evs.append(e)
    }
    for s in strokes {
        switch s {
        case .char(let c): key(0, true, unicode: c); key(0, false, unicode: c)
        case .backspace: key(51, true); key(51, false)
        case .commandDown: key(55, true, flags: .maskCommand); key(125, true, flags: .maskCommand); key(125, false, flags: .maskCommand); key(55, false)
        }
    }
    let t0 = ms()
    for e in evs { e.post(tap: .cghidEventTap) }
    return ms() - t0
}

// MARK: Arguments

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String, _ fallback: String) -> String {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return fallback
}
let warm = !args.contains("--no-warm")
guard let command = args.first else { die("usage: see the header of mac-ax-probe.swift") }
let target = findFocused(warm: warm)
let el = target.element
let appName = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier ?? "?"
let baseline = ms()

func sampleText(_ n: Int) -> String {
    var s = ""
    var i = 0
    while s.utf16.count < n { s += "word\(String(format: "%04d", i % 10000)) "; i += 1 }
    return String(s.prefix(n))
}
func wait(_ cond: @autoclosure () -> Bool, _ timeoutMs: Double = 3000) -> Double? { waitUntil(timeoutMs, cond) }

switch command {
case "info":
    emit(["kind": "info", "app": appName, "pid": Int(target.pid),
          "version": NSRunningApplication(processIdentifier: target.pid).flatMap { Bundle(url: $0.bundleURL!)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "?",
          "role": (attr(el, kAXRoleAttribute).0 as? String) ?? "?", "subrole": (attr(el, kAXSubroleAttribute).0 as? String) ?? "",
          "domId": (attr(el, "AXDOMIdentifier").0 as? String) ?? "", "domClasses": (attr(el, "AXDOMClassList").0 as? [String]) ?? [],
          "value": readValue(el).flatMap { $0.utf16.count <= 5000 ? $0 : nil } as Any,
          "characters": readCount(el) as Any, "valueLength": readValue(el)?.utf16.count as Any,
          "selection": readSelection(el).map { [$0.location, $0.length] } as Any,
          "settable": ["AXValue": settable(el, "AXValue"), "AXSelectedText": settable(el, "AXSelectedText"),
                       "AXSelectedTextRange": settable(el, "AXSelectedTextRange")],
          "attributes": names(el, parameterized: false), "parameterized": names(el, parameterized: true)])

case "fill":
    guard args.count > 1, let n = Int(args[1]) else { die("fill N") }
    let text = sampleText(n)
    var via = "axvalue"
    var err = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString)
    if err != .success || wait(readValue(el) == text, 1500) == nil {
        via = "paste"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        var evs: [CGEvent] = []
        for down in [true, false] { let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)!; e.flags = .maskCommand; evs.append(e) }  // Cmd+A
        for e in evs { e.post(tap: .cghidEventTap) }
        usleep(200_000)
        evs = []
        for down in [true, false] { let e = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)!; e.flags = .maskCommand; evs.append(e) }
        for e in evs { e.post(tap: .cghidEventTap) }
        err = .success
        _ = wait(readValue(el) == text, 5000)
    }
    let caret = option("--caret", "end")
    let at = caret == "start" ? 0 : caret == "mid" ? n / 2 : n
    _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axRange(CFRange(location: at, length: 0)))
    usleep(100_000)
    emit(["kind": "fill", "requested": n, "via": via, "axError": Int(err.rawValue), "valueLength": readValue(el)?.utf16.count as Any,
          "characters": readCount(el) as Any, "matches": readValue(el) == text, "selection": readSelection(el).map { [$0.location, $0.length] } as Any])

case "caret":
    let n = readValue(el)?.utf16.count ?? 0
    let at = args.count > 1 && args[1] == "start" ? 0 : args.count > 1 && args[1] == "mid" ? n / 2 : n
    let err = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axRange(CFRange(location: at, length: 0)))
    usleep(100_000)
    emit(["kind": "caret", "axError": Int(err.rawValue), "requested": at, "selection": readSelection(el).map { [$0.location, $0.length] } as Any])

case "read":
    let reps = Int(option("--reps", "30")) ?? 30
    guard let text = readValue(el) else { die("AXValue unreadable") }
    let n = text.utf16.count
    let mid = CFRange(location: n / 2, length: min(20, n / 2))
    func time(_ label: String, _ op: () -> AXError) {
        var samples: [Double] = []
        var last = AXError.success
        for _ in 0..<reps { let t = ms(); last = op(); samples.append(ms() - t) }
        samples.sort()
        emit(["kind": "read", "app": appName, "attribute": label, "length": n, "reps": reps, "axError": Int(last.rawValue),
              "minMs": r2(samples[0]), "medianMs": r2(samples[samples.count / 2]), "p90Ms": r2(samples[Int(Double(samples.count) * 0.9)]),
              "maxMs": r2(samples[samples.count - 1])])
    }
    var tmp: CFTypeRef?
    time("AXValue") { AXUIElementCopyAttributeValue(el, "AXValue" as CFString, &tmp) }
    time("AXNumberOfCharacters") { AXUIElementCopyAttributeValue(el, "AXNumberOfCharacters" as CFString, &tmp) }
    time("AXSelectedTextRange") { AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &tmp) }
    time("AXStringForRange(20)") { AXUIElementCopyParameterizedAttributeValue(el, "AXStringForRange" as CFString, axRange(mid), &tmp) }
    time("AXStringForRange(all)") { AXUIElementCopyParameterizedAttributeValue(el, "AXStringForRange" as CFString, axRange(CFRange(location: 0, length: n)), &tmp) }

case "watch":
    let secs = Double(option("--secs", "10")) ?? 10
    let reg = observe(target, on: option("--on", "both"))
    emit(["kind": "watch.start", "app": appName, "registrations": reg, "secs": secs])
    var seen = 0
    let end = ms() + secs * 1000
    while ms() < end {
        CFRunLoopRunInMode(.defaultMode, 0.01, false)
        while seen < events.count {
            let e = events[seen]; seen += 1
            emit(["kind": "notification", "name": e.name, "ms": r2(e.t - baseline), "role": e.role, "focusedElement": e.sameAsFocused, "registeredOn": e.via,
                  "selection": readSelection(el).map { [$0.location, $0.length] } as Any])
        }
    }

case "write":
    let mode = args.count > 1 ? args[1] : "hunk"
    let reps = Int(option("--reps", "5")) ?? 5
    let poll = option("--poll", "value")
    let reg = observe(target, on: option("--on", "element"))
    let ops = names(el, parameterized: true)
    for rep in 0..<reps {
        guard let before = readValue(el) else { die("AXValue unreadable") }
        let n = before.utf16.count
        let len = min(20, n / 2)
        let loc = max(0, n / 2 - len / 2)
        let marker = String(format: "[%02d]", rep)
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let replacement = String((marker + String((0..<16).map { letters[(rep * 3 + $0) % 26] })).prefix(len))
        let expected = String(decoding: Array(before.utf16)[0..<loc] + Array(replacement.utf16) + Array(before.utf16)[(loc + len)...], as: UTF16.self)
        events.removeAll()
        var line: [String: Any] = ["kind": "write", "app": appName, "mode": mode, "rep": rep, "length": n, "hunkLocation": loc, "hunkLength": len]
        var tWrite = 0.0, writeErr = AXError.success, via = "axvalue"
        if mode == "value" {
            tWrite = ms()
            writeErr = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, expected as CFString)
        } else {
            let tSel0 = ms()
            let selErr = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axRange(CFRange(location: loc, length: len)))
            let selAck = wait({ let s = readSelection(el); return s?.location == loc && s?.length == len }(), 2000)
            line["selectErr"] = Int(selErr.rawValue); line["selectAckMs"] = selAck.map(r2) as Any; line["selectCallMs"] = r2(ms() - tSel0)
            pump(0.15)
            line["selectNotifications"] = eventLines(since: tSel0)
            events.removeAll()
            if ops.contains("AXTextOperation"), let markers = attr(el, "AXSelectedTextMarkerRange").0 {
                via = "AXTextOperation"
                let op: NSDictionary = ["AXTextOperationMarkerRanges": [markers], "AXTextOperationType": "TextOperationReplacePreserveCase",
                                        "AXTextOperationReplacementString": replacement, "AXTextOperationSmartReplace": false]
                tWrite = ms()
                writeErr = param(el, "AXTextOperation", op).1
            } else {
                via = "AXSelectedText"
                tWrite = ms()
                writeErr = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, replacement as CFString)
            }
        }
        let tReturn = ms()
        let visible: Double? = waitUntil(3000) {
            if mode == "value" || poll == "value" { return readValue(el) == expected }
            return readRange(el, CFRange(location: loc, length: replacement.utf16.count)) == replacement
        }
        pump(0.4)
        let after = readValue(el)
        line["via"] = via; line["writeErr"] = Int(writeErr.rawValue); line["writeCallMs"] = r2(tReturn - tWrite)
        line["visibleAfterWriteMs"] = visible.map { r2($0 + (tReturn - tWrite)) } as Any
        line["visibleAfterReturnMs"] = visible.map(r2) as Any
        line["endStateMatches"] = after == expected
        line["registrations"] = reg
        line["notifications"] = eventLines(since: tWrite)
        line["selectionAfter"] = readSelection(el).map { [$0.location, $0.length] } as Any
        emit(line)
        usleep(200_000)
    }

case "keys":
    let typed = option("--type", "legato-burst-0123456789")
    let backs = Int(option("--backspaces", "6")) ?? 6
    let then = option("--then", "XY")
    let reps = Int(option("--reps", "3")) ?? 3
    let reg = observe(target, on: option("--on", "element"))
    for rep in 0..<reps {
        _ = post([.commandDown])  // caret to the end of the text
        usleep(300_000)
        guard let before = readValue(el) else { die("AXValue unreadable") }
        let strokes: [Stroke] = typed.map { .char(String($0)) } + Array(repeating: .backspace, count: backs) + then.map { .char(String($0)) }
        var expectedChars = Array(before)
        for c in typed { expectedChars.append(c) }
        expectedChars.removeLast(min(backs, expectedChars.count))
        for c in then { expectedChars.append(c) }
        let expected = String(expectedChars)
        // A real caret end can differ (trailing newline in the host); expectation is relative to the value read before.
        events.removeAll()
        let t0 = ms()
        let postMs = post(strokes)
        let tPosted = ms()
        var firstChange: Double?
        let landed = waitUntil(5000) {
            let v = readValue(el)
            if firstChange == nil, v != before { firstChange = ms() - t0 }
            return v == expected
        }
        pump(0.4)
        let after = readValue(el) ?? ""
        emit(["kind": "keys", "app": appName, "rep": rep, "length": before.utf16.count, "keys": strokes.count, "keyEvents": strokes.count * 2,
              "postMs": r2(postMs), "firstChangeVisibleMs": firstChange.map(r2) as Any, "endStateVisibleAfterPostMs": landed.map { r2($0 + (tPosted - t0)) } as Any,
              "endStateMatches": after == expected, "valueDelta": after.utf16.count - before.utf16.count, "expectedDelta": expected.utf16.count - before.utf16.count,
              "tail": String(after.suffix(40)), "expectedTail": String(expected.suffix(40)), "registrations": reg, "notifications": eventLines(since: t0)])
        usleep(300_000)
    }

default:
    die("unknown command \(command); see the header of mac-ax-probe.swift")
}
