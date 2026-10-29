import Foundation
import LegatoCore
import LegatoMac
import LegatoKeyboardCore
import EvaluationSupport

func host(_ raw: String, delivery: HostDelivery = .live, final: Bool = false, revision: HostRevision? = nil, volatile: String = "", finalText: String? = nil) -> HostState {
    HostState(runID:"evaluation",phase:final ? .idle : .listening,target:.keyboard,committed:raw,volatile:volatile,seq:1,beatAt:Date(timeIntervalSince1970:0),leaseUntil:nil,acceptsRemoteStart:false,delivery:delivery,finalText:finalText,revision:revision)
}
@MainActor func interpret(_ ops: [ProxyOp], target: Target) throws {
    for op in ops {
        switch op {
        case .deleteBackward(let n):
            // Modeled Character units; physical deleteBackward units remain unverified.
            let before=(target.value as NSString).substring(to:target.selection.location)
            let tail=String(before.suffix(n))
            try target.replace(UTF16Range(location:target.selection.location-tail.utf16.count,length:tail.utf16.count),with:"")
        case .insert(let text): try target.replace(target.selection,with:text)
        }
    }
}
func proxyOps(_ ops: [ProxyOp]) -> [[String:Any]] {
    ops.map { op in switch op { case .deleteBackward(let n): return ["deleteBackwardCharacters":n]; case .insert(let s): return ["insert":s] } }
}
@MainActor func fieldBaseline(_ f: PatchFixture, variant: String, subcase: String) -> [String:Any] {
    let t=Target(prefix:f.prefix,outside:f.outside)
    let w=FieldWriter(target:t,mode:.streamLive)
    w.apply(.commit(delta:f.old))
    if let newer=f.newer, f.kind == "newer" { w.apply(.commit(delta:newer)) }
    var expected=f.prefix+f.new+(f.kind == "newer" ? f.newer ?? "" : "")+f.outside
    if f.kind == "manual" {
        switch subcase {
        case "text-edit": t.value=f.prefix+"MANUAL "+f.old+f.outside
        case "caret": t.selection.location=f.prefix.utf16.count
        case "selection": t.selection.length=1
        case "focus", "document": t.focused=false
        default: break
        }
        expected=t.value
    }
    let startOps=t.operations.count, startRemoved=t.removed, startInserted=t.inserted
    if f.kind == "fault" { t.fault=subcase }
    let first = TranscriptRevision(n:2,start:0,raw:f.old,text:f.new)
    if variant == "field-live" {
        w.apply(.revise(first))
        if f.kind == "ordering" {
            if subcase == "duplicate" { w.apply(.revise(first)) }
            if subcase == "older" || subcase == "out-of-order" { w.apply(.revise(TranscriptRevision(n:1,start:0,raw:f.old,text:"WRONG STALE"))) }
        }
    } else { _=w.swapWritten(for:f.new+(f.kind == "newer" ? f.newer ?? "" : "")) }
    let count=t.operations.count
    let canonicalNoop=f.kind == "unicode" && f.old==f.new && !byteEqual(f.old,f.new) && count==startOps
    if f.kind == "fault" {
        // Exercise a later revision/append after the uncertain write, without resetting faults.
        w.apply(.revise(TranscriptRevision(n:3,start:0,raw:f.old,text:"NO BLIND RETRY")))
        w.apply(.commit(delta:" later"))
    }
    var checks=["surroundings":t.value.hasPrefix(f.prefix) && t.value.hasSuffix(f.outside)]
    if f.kind == "fault" { checks["noBlindRetryAfterUncertainty"]=count==t.operations.count }
    else { checks["expectedText"]=t.value==expected }
    if f.kind != "fault" && f.kind != "manual" {
        checks["caretAtOwnedEnd"]=t.selection == UTF16Range(location:t.value.utf16.count-f.outside.utf16.count,length:0)
        checks["rawSuffixPreserved"]=t.value.hasSuffix(f.unchangedSuffix+(f.kind == "newer" ? f.newer ?? "" : "")+f.outside) && Array(t.value.utf8).suffix((f.unchangedSuffix+(f.kind == "newer" ? f.newer ?? "" : "")+f.outside).utf8.count) == Array((f.unchangedSuffix+(f.kind == "newer" ? f.newer ?? "" : "")+f.outside).utf8)
    }
    if canonicalNoop {
        checks["canonicalNoopRetainsExactBytes"]=byteEqual(t.value,f.prefix+f.old+f.outside)
        checks["canonicalNoopExactRetainedCaret"]=t.selection==UTF16Range(location:(f.prefix+f.old).utf16.count,length:0)
    }
    return ["canonicalNoop":canonicalNoop,"output":t.value,"caretUTF16":t.selection.location,"operations":Array(t.operations.dropFirst(startOps)),"removedCharacters":t.removed-startRemoved,"insertedCharacters":t.inserted-startInserted,"unchangedSuffixRewritten":t.operations.count>startOps ? ContiguousPatch(old:f.old,new:f.new).suffix.count : 0,"outcome":f.kind == "fault" ? "uncertain-landing" : (f.kind == "manual" ? "safely-declined" : (canonicalNoop ? "no-op-canonical-equivalence" : "verified-applied")),"degrade":String(describing:w.degradeReason),"assertions":checks,"recovery":f.kind == "fault" ? String(describing:w.finish(finalText:f.new)) : "not-needed"]
}
@MainActor func proxyBaseline(_ f: PatchFixture, variant: String, subcase: String) throws -> [String:Any] {
    let t=Target(prefix:f.prefix,outside:f.outside)
    let live=variant == "proxy-live"
    var state=host(f.old,delivery:live ? .live : .replace)
    var plan=ProxyEditPlanner.plan(state:state,cursor:nil,contextBefore:f.prefix,documentID:"doc")
    try interpret(plan.ops,target:t)
    var cursor=plan.cursor
    if let newer=f.newer, f.kind == "newer" {
        state.committed += newer
        plan=ProxyEditPlanner.plan(state:state,cursor:cursor,contextBefore:f.prefix+f.old,documentID:"doc")
        try interpret(plan.ops,target:t); cursor=plan.cursor
    }
    var context=String(t.value.dropLast(f.outside.count))
    var doc="doc"
    if f.kind == "manual" {
        switch subcase {
        case "text-edit": t.value=f.prefix+"MANUAL"+f.old+" edited"+f.outside; context=f.prefix+"MANUAL"+f.old+" edited"
        case "caret", "selection": context=f.prefix; t.selection=UTF16Range(location:f.prefix.utf16.count,length:subcase == "selection" ? 1 : 0)
        case "focus", "document": doc="other"
        default: break
        }
    }
    let before=t.value
    let startOps=t.operations.count, startRemoved=t.removed, startInserted=t.inserted
    if live { state.revision=HostRevision(n:2,start:0,raw:f.old,text:f.new) }
    else { state.phase = .idle; state.finalText=f.new+(f.kind == "newer" ? f.newer ?? "" : "") }
    plan=ProxyEditPlanner.plan(state:state,cursor:cursor,contextBefore:context,documentID:doc)
    var planned=proxyOps(plan.ops)
    try interpret(plan.ops,target:t)
    cursor=plan.cursor
    if f.kind == "ordering" {
        if subcase == "older" || subcase == "out-of-order" { state.revision=HostRevision(n:1,start:0,raw:f.old,text:"WRONG STALE") }
        let again=ProxyEditPlanner.plan(state:state,cursor:cursor,contextBefore:String(t.value.dropLast(f.outside.count)),documentID:doc)
        planned += proxyOps(again.ops); try interpret(again.ops,target:t)
    }
    let expected=f.kind == "manual" ? before : f.prefix+f.new+(f.kind == "newer" ? f.newer ?? "" : "")+f.outside
    let canonicalNoop=f.kind == "unicode" && f.old==f.new && !byteEqual(f.old,f.new) && t.operations.count==startOps
    var checks=["expectedText":t.value==expected,"surroundings":t.value.hasPrefix(f.prefix) && t.value.hasSuffix(f.outside)]
    if f.kind != "manual" {
        let untouched=f.unchangedSuffix+(f.kind == "newer" ? f.newer ?? "" : "")+f.outside
        checks["rawSuffixBytes"]=Array(t.value.utf8).suffix(untouched.utf8.count)==Array(untouched.utf8)
        checks["caretAtOwnedEnd"]=t.selection==UTF16Range(location:t.value.utf16.count-f.outside.utf16.count,length:0)
    }
    if canonicalNoop {
        checks["canonicalNoopRetainsExactBytes"]=byteEqual(t.value,f.prefix+f.old+f.outside)
        checks["canonicalNoopExactRetainedCaret"]=t.selection==UTF16Range(location:(f.prefix+f.old).utf16.count,length:0)
    }
    return ["canonicalNoop":canonicalNoop,"output":t.value,"caretUTF16":t.selection.location,"operations":Array(t.operations.dropFirst(startOps)),"proxyOps":planned,"removedCharacters":t.removed-startRemoved,"insertedCharacters":t.inserted-startInserted,"unchangedSuffixRewritten":plan.ops.isEmpty ? 0 : ContiguousPatch(old:f.old,new:f.new).suffix.count,"outcome":f.kind == "manual" ? "safely-declined" : (canonicalNoop ? "no-op-canonical-equivalence" : "verified-applied"),"assertions":checks,"limitation":"Context and Character cursor units modeled; no native write readback or selection/focus API in planner"]
}
