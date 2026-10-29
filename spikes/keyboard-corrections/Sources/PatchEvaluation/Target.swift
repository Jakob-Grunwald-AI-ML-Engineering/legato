import Foundation
import LegatoMac
import EvaluationSupport

@MainActor final class Target: TextTarget {
    var value: String
    var selection: UTF16Range
    var focused = true
    var fault = ""
    var readFault = false
    var operations: [[String: Any]] = []
    var removed = 0
    var inserted = 0
    enum Failure: Error { case unreadable, write }
    init(prefix: String, outside: String) {
        value = prefix + outside
        selection = UTF16Range(location: prefix.utf16.count, length: 0)
    }
    func isFocused() -> Bool { focused }
    func selectedRange() throws -> UTF16Range { if readFault { throw Failure.unreadable }; return selection }
    func text(in range: UTF16Range) throws -> String {
        if readFault { throw Failure.unreadable }
        guard range.location >= 0, range.location <= value.utf16.count else { throw Failure.unreadable }
        return (value as NSString).substring(with: NSRange(location: range.location, length: min(range.length, value.utf16.count-range.location)))
    }
    func select(_ range: UTF16Range) throws {
        if readFault { throw Failure.unreadable }
        selection = range
    }
    func replace(_ range: UTF16Range, with text: String) throws {
        let previous = try self.text(in: range)
        operations.append(["op":"replace", "locationUTF16":range.location, "lengthUTF16":range.length,"text":text])
        if fault == "throw" { throw Failure.write }
        if fault == "ignored" { return }
        let landed = (fault == "partial" || fault == "truncated") ? String(text.prefix(max(0,text.count/2))) : text
        guard let rr = Range(NSRange(location:range.location,length:range.length), in:value) else { throw Failure.write }
        value.replaceSubrange(rr, with:landed)
        selection = UTF16Range(location:range.location+landed.utf16.count,length:0)
        removed += previous.count; inserted += landed.count
        if fault == "read-fail" || fault == "read-delayed" { readFault = true }
    }
}

struct PatchFixture: Decodable {
    let id, kind, old, new, prefix, outside, unchangedSuffix: String
    let newer: String?
    let subcases: [String]?
    let boundaries: [String]?
}

@MainActor final class ScratchPatchSession {
    let target: Target
    let fixture: PatchFixture
    var stopped = false
    var lastRevision = 0
    var trace: [[String:Any]] = []
    init(target: Target, fixture: PatchFixture) { self.target=target; self.fixture=fixture }
    func apply(n: Int, suffix: String = "", fault: String = "", boundary: String = "") -> String {
        guard !stopped else { return "safely-declined" }
        guard n > lastRevision else { return "safely-declined" }
        lastRevision=n
        let old=fixture.old+suffix, new=fixture.new+suffix
        let start=fixture.prefix.utf16.count
        guard target.focused, !target.readFault,
              target.selection == UTF16Range(location:start+old.utf16.count,length:0),
              byteEqual(target.value, fixture.prefix+old+fixture.outside) else { stopped=true; return "safely-declined" }
        let patch=ContiguousPatch(old:old,new:new)
        let patchStart=start+String(old.prefix(patch.location)).utf16.count
        var expected=target.value
        var caret=target.selection.location
        func step(_ name: String, _ action: () throws -> Void) -> Bool {
            let before=target.value
            let beforeCaret=target.selection
            do {
                try action()
                if boundary == name {
                    switch fault {
                    case "ignored": target.value=before; target.selection=beforeCaret
                    case "partial", "truncated":
                        // A corrupt partial operation at this boundary, never a successful landing.
                        if name == "after-insert" { target.value=before; target.selection=beforeCaret }
                        else { target.selection.location=max(0,target.selection.location-1) }
                    case "throw": throw Target.Failure.write
                    case "read-fail", "read-delayed": target.readFault=true
                    default: break
                    }
                }
                trace.append(["boundary":name,"expected":expected,"observed":target.value,"caretUTF16":target.selection.location])
                guard !target.readFault, byteEqual(target.value,expected), target.selection == UTF16Range(location:caret,length:0) else { stopped=true; return false }
                return true
            } catch { stopped=true; trace.append(["boundary":name,"error":String(describing:error)]); return false }
        }
        // This is a scratch-only cursor primitive: neither TextTarget nor ProxyOp exposes it.
        if boundary == "before-move", !fault.isEmpty { stopped=true; trace.append(["boundary":"before-move","fault":fault]); return "safely-declined" }
        caret=patchStart+patch.removed.utf16.count
        if !step("after-move", { target.selection = UTF16Range(location:caret,length:0) }) { return "uncertain-landing" }
        if let range=Range(NSRange(location:patchStart,length:patch.removed.utf16.count),in:expected) { expected.replaceSubrange(range,with:"") }
        caret=patchStart
        if !step("after-delete", { try target.replace(UTF16Range(location:patchStart,length:patch.removed.utf16.count),with:"") }) { return "uncertain-landing" }
        if let range=Range(NSRange(location:patchStart,length:0),in:expected) { expected.replaceSubrange(range,with:patch.inserted) }
        caret=patchStart+patch.inserted.utf16.count
        if !step("after-insert", { try target.replace(UTF16Range(location:patchStart,length:0),with:patch.inserted) }) { return "uncertain-landing" }
        caret=start+new.utf16.count
        if !step("after-restore", { target.selection=UTF16Range(location:caret,length:0) }) { return "uncertain-landing" }
        return "verified-applied"
    }
}
