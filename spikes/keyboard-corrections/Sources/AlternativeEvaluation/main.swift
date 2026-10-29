import Foundation
import AppKit
import LegatoVocabulary
import LegatoKeyboardCore
import EvaluationSupport

@MainActor func run() async throws -> Int32 {
    let fixtures=try JSONDecoder().decode([AlternativeFixture].self,from:Data(contentsOf:URL(fileURLWithPath:pathArg("--fixtures"))))
    guard fixtures.count==24, Set(fixtures.map(\.id))==Set(["DE","EN","MX"].flatMap { g in (1...8).map { String(format:"%@%02d",g,$0) } }) else { throw NSError(domain:"FixtureCount",code:1) }
    let report=try Records(path:pathArg("--report"))
    let languages=NSSpellChecker.shared.availableLanguages
    var summaries:[String:Any]=[:]
    for arm in ["lexical","macOS-platform"] {
        var times:[Double]=[], firstTimes:[Double]=[], laterTimes:[Double]=[]
        var totals:[String:Int]=["opportunities":0,"repairNeeded":0,"usefulAt1":0,"usefulAt3":0,"repairUsefulAt1":0,"repairUsefulAt3":0,"empty":0,"unnecessaryOffers":0,"harmfulOffers":0,"ambiguousOffers":0,"semanticMissOrUnassessed":0]
        var groupTotals:[String:[String:Int]]=[:]
        for f in fixtures {
            let context=try f.context()
            guard f.versions.isEmpty || f.versions[0]==f.sentence else { throw NSError(domain:"VersionShownSpan-"+f.id,code:1) }
            let sources=makeSources(f,context:context,platform:arm == "macOS-platform")
            for active in [true,false] {
                let (observation,stateChecks)=stateObservations(f,context:context,active:active)
                for rep in 0..<3 {
                    let start=ContinuousClock.now
                    // Disconnected harness call during listening; production state remains paused.
                    let ranked=await WordAlternatives.rank(word:f.tapped,context:context,sources:sources)
                    let duration=start.duration(to:.now)
                    let ms=Double(duration.components.seconds)*1000+Double(duration.components.attoseconds)/1e15
                    times.append(ms)
                    if rep==0 && active { firstTimes.append(ms) } else { laterTimes.append(ms) }
                    var checks=stateChecks
                    checks["limitThree"]=ranked.count<=3
                    checks["deduplicated"]=Set(ranked.map { key($0.text) }).count==ranked.count
                    checks["omitsOriginal"] = !ranked.contains { key($0.text)==key(f.tapped) }
                    checks["finiteSortedScores"]=ranked.allSatisfy { $0.score.isFinite } && zip(ranked,ranked.dropFirst()).allSatisfy { $0.score >= $1.score }
                    let candidates:[[String:Any]]=ranked.map { c in
                        ["text":c.text,"score":c.score,"sourceTag":c.source.rawValue,"sourceProvenance":sourceProvenance(c.source),"judgment":judgment(c.text,fixture:f),"usefulAvailableInVocabulary":f.vocabulary.map(key).contains(key(c.text)),"usefulAlreadyInAnotherVersion":f.versions.dropFirst().contains { $0.localizedCaseInsensitiveContains(c.text) },"proposedSentence":f.sentence.replacingCharacters(in:context.wordRange,with:c.text)]
                    }
                    let judgments=ranked.map { judgment($0.text,fixture:f) }
                    let at1=judgments.first=="useful-contextual-repair", at3=judgments.contains("useful-contextual-repair")
                    if !active && rep==0 {
                        totals["opportunities",default:0] += 1
                        totals["repairNeeded",default:0] += f.repairNeeded ? 1 : 0
                        totals["usefulAt1",default:0] += at1 ? 1 : 0
                        totals["usefulAt3",default:0] += at3 ? 1 : 0
                        totals["repairUsefulAt1",default:0] += f.repairNeeded && at1 ? 1 : 0
                        totals["repairUsefulAt3",default:0] += f.repairNeeded && at3 ? 1 : 0
                        totals["empty",default:0] += ranked.isEmpty ? 1 : 0
                        totals["unnecessaryOffers",default:0] += judgments.filter { $0=="unnecessary-offer" }.count
                        totals["harmfulOffers",default:0] += judgments.filter { $0=="harmful-in-context" }.count
                        totals["ambiguousOffers",default:0] += judgments.filter { $0=="ambiguous-requires-choice" }.count
                        totals["semanticMissOrUnassessed",default:0] += judgments.filter { $0=="semantic-miss-or-unassessed" }.count
                        groupTotals[f.group,default:[:]]["opportunities",default:0] += 1
                        groupTotals[f.group,default:[:]]["usefulAt3",default:0] += at3 ? 1 : 0
                    }
                    try report.emit(["id":f.id,"arm":arm,"active":active,"repetition":rep,"firstInvocationForOpportunityArm":active && rep==0,"latencyMs":ms,"candidates":candidates,"usefulAt1":at1,"usefulAt3":at3,"stateObservation":observation,"assertions":checks,"rankerInvocation":"disconnected harness call; independent of actual SuggestionState visibility","inputSentence":f.sentence,"inputWord":f.tapped,"rangeUTF16":[f.rangeUTF16.location,f.rangeUTF16.length],"languageOrder":f.languages,"fixtureVocabulary":f.vocabulary,"fixtureVersions":f.versions,"intent":f.intent,"repairNeeded":f.repairNeeded,"ambiguous":f.ambiguous,"oracle":f.oracle,"rankerContextLimit":f.rankerContextLimit,"fixtureEvidence":f.evidence])
                }
            }
        }
        summaries[arm] = ["counts":totals,"groups":groupTotals,"timingsAll":latencySummary(times),"timingsFirstPerOpportunity":latencySummary(firstTimes),"timingsLater":latencySummary(laterTimes),"stateObservationsUnique":48,"qualityScoring":"stopped-context repetition 0 only; synthetic contextual intent; semantic misses valid outcomes","usefulAt1RateAll":Double(totals["usefulAt1"]!)/24,"usefulAt3RateAll":Double(totals["usefulAt3"]!)/24,"usefulAt1RateRepairNeeded":Double(totals["repairUsefulAt1"]!)/Double(totals["repairNeeded"]!),"usefulAt3RateRepairNeeded":Double(totals["repairUsefulAt3"]!)/Double(totals["repairNeeded"]!)]
    }
    try jsonWrite(["evidence":"harness","opportunities":24,"records":report.count,"assertionFailures":report.failures,"arms":summaries,"platformAvailableLanguages":languages,"requestedLanguageAvailability":["de":languages.contains { $0=="de" || $0.hasPrefix("de_") || $0.hasPrefix("de-") },"en":languages.contains { $0=="en" || $0.hasPrefix("en_") || $0.hasPrefix("en-") }],"physicalPhone":false,"actualAcceptedCorrections":"unmeasured","audioGroundtruth":"none; authored diagnostic contexts","runtimeRecognizerCandidatesConfidence":"unmeasured","manualChoicePrecedence":"unmeasured; no UIKit tap/controller path exercised"],path:pathArg("--summary"))
    print("Alternative records: \(report.count); contract/state assertion failures: \(report.failures)")
    return report.failures==0 ? 0 : 1
}
do { exit(try await run()) } catch { fputs("Alternative runner error: \(error)\n",stderr); exit(1) }
