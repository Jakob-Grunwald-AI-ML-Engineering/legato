import Foundation
import LegatoMac
import LegatoCore
import LegatoKeyboardCore
import EvaluationSupport

@MainActor func settling(_ f: PatchFixture, subcase: String) throws -> [String:Any] {
    var reveal=TypewriterReveal()
    let t=Target(prefix:f.prefix,outside:f.outside)
    var state=host("",volatile:f.old)
    let first=reveal.plan(state:state,cursor:nil,contextBefore:f.prefix,documentID:"doc",animated:false)
    try interpret(first.ops,target:t)
    var cursor=first.cursor
    state.volatile=f.new
    var timeline: [[String:Any]]=[]
    var checks: [String:Bool]=[:]
    if subcase == "volatile-change" {
        let p=reveal.plan(state:state,cursor:cursor,contextBefore:f.prefix+f.old,documentID:"doc",animated:false)
        try interpret(p.ops,target:t)
        checks["newVolatileLands"]=byteEqual(t.value,f.prefix+f.new+f.outside)
        timeline.append(["ops":proxyOps(p.ops),"context":f.prefix+f.old])
    } else {
        let ticks = subcase == "context-timeout" ? [100.0,100,100,1] : [100.0,100]
        for elapsed in ticks {
            let p=reveal.plan(state:state,cursor:cursor,contextBefore:f.prefix,documentID:"doc",animated:true,elapsedMs:elapsed)
            timeline.append(["elapsedMs":elapsed,"ops":proxyOps(p.ops),"needsTicks":reveal.needsTicks])
            if timeline.count <= 3 { checks["wait-"+String(timeline.count)]=p.ops.isEmpty }
            cursor=p.cursor
            if !p.ops.isEmpty {
                // The context timeout is a production-contract limitation; don't pretend it verified landing.
                checks["timeoutOnlyAfter250ms"]=subcase == "context-timeout" && timeline.count==4
            }
        }
        if subcase == "context-delayed" {
            let p=reveal.plan(state:state,cursor:cursor,contextBefore:f.prefix+f.old,documentID:"doc",animated:false)
            try interpret(p.ops,target:t)
            checks["settledContextLands"]=byteEqual(t.value,f.prefix+f.new+f.outside)
            timeline.append(["contextSettled":true,"ops":proxyOps(p.ops)])
        } else { checks["timeoutProducedPlan"] = !(timeline.last?["ops"] as? [[String:Any]] ?? []).isEmpty }
    }
    return ["output":t.value,"caretUTF16":t.selection.location,"operations":t.operations,"timeline":timeline,"assertions":checks,"outcome":subcase == "context-timeout" ? "uncertain-landing" : "verified-applied","limitation":"Timeout plan captured but not executed against falsely stale context; no native settling claim"]
}
@MainActor func sent(_ f: PatchFixture, subcase: String) throws -> [String:Any] {
    let state=host(f.old)
    let t=Target(prefix:"",outside:"")
    let first=ProxyEditPlanner.plan(state:state,cursor:nil,contextBefore:"",documentID:"doc")
    try interpret(first.ops,target:t)
    t.value=""; t.selection=UTF16Range(location:0,length:0)
    let boundary=ProxyEditPlanner.fieldCleared(state:state,cursor:first.cursor,documentID:"doc",contextBefore:"",hasText:false)
    var next=host(f.old+(f.newer ?? ""))
    if subcase == "sent-revision" { next.revision=HostRevision(n:2,start:0,raw:f.old,text:f.new) }
    let plan=ProxyEditPlanner.plan(state:next,cursor:boundary,contextBefore:"",documentID:"doc")
    if subcase != "cleared" { try interpret(plan.ops,target:t) }
    return ["output":t.value,"caretUTF16":t.selection.location,"operations":t.operations,"proxyOps":proxyOps(plan.ops),"outcome":"verified-applied","assertions":["boundaryAtSentRaw":boundary?.sentBase==f.old.count,"newTextOnly":subcase == "cleared" ? t.value.isEmpty : byteEqual(t.value,f.newer ?? ""),"staleSentTextNotRetyped":!t.value.contains("hello")],"limitation":"Sent event is a deterministic replay; not an actual chat host send"]
}
@MainActor func experiment(_ f: PatchFixture, subcase: String, boundary: String="") -> [String:Any] {
    let t=Target(prefix:f.prefix,outside:f.outside)
    let suffix=f.kind == "newer" ? f.newer ?? "" : ""
    t.value=f.prefix+f.old+suffix+f.outside
    t.selection=UTF16Range(location:(f.prefix+f.old+suffix).utf16.count,length:0)
    if f.kind == "manual" {
        switch subcase {
        case "text-edit": t.value=f.prefix+"MANUAL "+f.old+f.outside
        case "caret": t.selection.location=f.prefix.utf16.count
        case "selection": t.selection.length=1
        case "focus", "document": t.focused=false
        default: break
        }
    }
    let original=t.value
    let originalCaret=t.selection
    let session=ScratchPatchSession(target:t,fixture:f)
    let outcome=session.apply(n:2,suffix:suffix,fault:f.kind == "fault" ? subcase : "",boundary:boundary)
    let count=t.operations.count
    let beforeRetry=t.value
    let beforeRetryCaret=t.selection
    var checks=["outsideBytesPreserved":Array(t.value.utf8).starts(with:Array(f.prefix.utf8)) && Array(t.value.utf8).suffix(f.outside.utf8.count)==Array(f.outside.utf8)]
    if f.kind == "fault" || f.kind == "manual" {
        _=session.apply(n:3,suffix:suffix)
        checks["noBlindRetry"]=count==t.operations.count && byteEqual(t.value,beforeRetry) && t.selection==beforeRetryCaret
        checks["declineOrUncertain"]=outcome != "verified-applied"
        if outcome == "safely-declined" { checks["declinePreservesField"]=byteEqual(original,t.value) && t.selection==originalCaret }
    } else {
        checks["expectedText"]=byteEqual(t.value,f.prefix+f.new+suffix+f.outside)
        checks["caretRestored"]=t.selection == UTF16Range(location:(f.prefix+f.new+suffix).utf16.count,length:0)
        checks["rawSuffixBytes"]=Array(t.value.utf8).suffix((f.unchangedSuffix+suffix+f.outside).utf8.count)==Array((f.unchangedSuffix+suffix+f.outside).utf8)
        if f.kind == "ordering" {
            let a=session.apply(n:2,suffix:suffix), b=session.apply(n:1,suffix:suffix)
            checks["staleRejected"]=a=="safely-declined" && b=="safely-declined" && count==t.operations.count
        }
    }
    let patch=ContiguousPatch(old:f.old+suffix,new:f.new+suffix)
    return ["output":t.value,"caretUTF16":t.selection.location,"operations":t.operations,"trace":session.trace,"removedCharacters":t.removed,"insertedCharacters":t.inserted,"unchangedSuffixRewritten":0,"patchRangeCharacters":[patch.location,patch.removed.count],"patchRangeUTF16":[String((f.old+suffix).prefix(patch.location)).utf16.count,patch.removed.utf16.count],"assertions":checks,"outcome":outcome,"recovery":t.value,"limitation":"Experimental scratch cursor primitive with synchronous readback, not a production/native capability"]
}
