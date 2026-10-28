import Foundation
import EvaluationSupport

@MainActor func run() throws -> Int32 {
    let fixtures=try JSONDecoder().decode([PatchFixture].self,from:Data(contentsOf:URL(fileURLWithPath:pathArg("--fixtures"))))
    guard fixtures.count==12, Set(fixtures.map(\.id))==Set((1...12).map { String(format:"P%02d",$0) }) else { throw NSError(domain:"FixtureCount",code:1) }
    let report=try Records(path:pathArg("--report"))
    var timings:[Double]=[], outcomes:[String:Int]=[:], volume:[String:[String:Int]]=[:]
    for f in fixtures {
        let subs=f.subcases ?? ["standard"]
        let variants=["field-live","field-final","proxy-live","proxy-final","experimental"]
        for variant in variants {
            for sub in subs {
                let boundaries=f.kind == "fault" && variant == "experimental" ? f.boundaries ?? [""] : [""]
                for boundary in boundaries {
                    let start=Date()
                    var v:[String:Any]
                    if f.kind == "sent" {
                        if variant == "proxy-live" { v=try sent(f,subcase:sub) }
                        else { v=["outcome":"unsupported","assertions":["unsupportedExplicit":true],"limitation":"FieldWriter has no sent boundary. Scratch patch has no sent-session coordinator. Final delivery is not live send handling."] }
                    } else if f.kind == "settling" {
                        if variant == "proxy-live" { v=try settling(f,subcase:sub) }
                        else { v=["outcome":"unsupported","assertions":["unsupportedExplicit":true],"limitation":"Delayed context settling exercised through actual TypewriterReveal only; no fake FieldWriter or experimental baseline"] }
                    } else if f.kind == "fault", variant.hasPrefix("proxy") {
                        v=["outcome":"unsupported","assertions":["unsupportedExplicit":true],"limitation":"Proxy planner exposes plans/cursor but no write acknowledgement/readback API; uncertain landing cannot be verified by this production seam"]
                    } else if variant == "experimental" { v=experiment(f,subcase:sub,boundary:boundary) }
                    else if variant.hasPrefix("field") { v=fieldBaseline(f,variant:variant,subcase:sub) }
                    else { v=try proxyBaseline(f,variant:variant,subcase:sub) }
                    let ms=Date().timeIntervalSince(start)*1000
                    timings.append(ms)
                    v["id"]=f.id; v["variant"]=variant; v["subcase"]=sub; v["boundary"]=boundary; v["latencyMs"]=ms
                    v["inputs"]=["old":f.old,"new":f.new,"prefix":f.prefix,"outside":f.outside,"newer":f.newer ?? ""]
                    v["operationCount"]=(v["operations"] as? [[String:Any]])?.count ?? 0
                    let outcome=v["outcome"] as? String ?? "missing"
                    outcomes[outcome,default:0] += 1
                    for key in ["removedCharacters","insertedCharacters","unchangedSuffixRewritten","operationCount"] { volume[variant,default:[:]][key,default:0] += v[key] as? Int ?? 0 }
                    try report.emit(v)
                }
            }
        }
    }
    try jsonWrite(["evidence":"harness","scenarioCount":fixtures.count,"records":report.count,"assertionFailures":report.failures,"outcomes":outcomes,"operationVolume":volume,"latency":latencySummary(timings),"nativeLatency":"unmeasured","physicalPhone":false],path:pathArg("--summary"))
    print("Patch records: \(report.count); safety assertion failures: \(report.failures)")
    return report.failures==0 ? 0 : 1
}
do { exit(try run()) } catch { fputs("Patch runner error: \(error)\n",stderr); exit(1) }
