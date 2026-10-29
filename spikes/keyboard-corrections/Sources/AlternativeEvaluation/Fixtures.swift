import Foundation
import EvaluationSupport
import LegatoVocabulary
import LegatoKeyboardCore

struct SpanFixture: Decodable { let location, length: Int }
struct AlternativeFixture: Decodable {
    let id, group, sentence, tapped, intent, oracle, evidence, rankerContextLimit: String
    let occurrence: Int
    let rangeUTF16: SpanFixture
    let languages, acceptable, vocabulary, versions, harmful: [String]
    let repairNeeded, ambiguous: Bool
    func context() throws -> AlternativeContext {
        guard let range=Range(NSRange(location:rangeUTF16.location,length:rangeUTF16.length),in:sentence), String(sentence[range])==tapped else { throw NSError(domain:"InvalidSpan-"+id,code:1) }
        return AlternativeContext(sentence:sentence,wordRange:range,languages:languages)
    }
}
func key(_ text: String) -> String { text.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() }
func makeSources(_ f: AlternativeFixture, context: AlternativeContext, platform: Bool) -> [any AlternativeSource] {
    var sources:[any AlternativeSource]=[]
    if !f.versions.isEmpty, let index=VersionWordsSource.tokenIndex(of:context.wordRange,in:f.sentence) {
        sources.append(VersionWordsSource(texts:f.versions,shown:0,wordIndex:index))
    }
    if !f.vocabulary.isEmpty {
        let entries=f.vocabulary.enumerated().map { i,text in VocabularyEntry(id:UUID(uuidString:String(format:"00000000-0000-0000-0000-%012d",i+1))!,text:text,lastSeen:Date(timeIntervalSince1970:0)) }
        sources.append(VocabularySource(snapshot:VocabularySnapshot(entries:entries)))
    }
    if platform { sources.append(SpellCheckerSource(checker:PlatformSpellChecker())) }
    return sources
}
func sourceProvenance(_ kind: AlternativeKind) -> String {
    switch kind {
    case .engine: return "VersionWordsSource: authored dictation-version difference tagged .engine; synthetic rank, not recognizer hypothesis/confidence"
    case .vocabulary: return "VocabularySource: bounded fixture-provided personal vocabulary, not inferred speaker intent"
    case .spellChecker: return "SpellCheckerSource(checker: PlatformSpellChecker()): macOS NSSpellChecker, not iPhone UITextChecker"
    }
}
func judgment(_ text: String, fixture f: AlternativeFixture) -> String {
    if f.harmful.map(key).contains(key(text)) { return "harmful-in-context" }
    if f.ambiguous { return "ambiguous-requires-choice" }
    if !f.repairNeeded { return "unnecessary-offer" }
    if f.acceptable.map(key).contains(key(text)) { return "useful-contextual-repair" }
    return "semantic-miss-or-unassessed"
}
func stateObservations(_ f: AlternativeFixture, context: AlternativeContext, active: Bool) -> ([String:Any],[String:Bool]) {
    var state=SuggestionState()
    let now=Date(timeIntervalSince1970:0)
    state.runActive(active)
    let cursor=f.sentence.index(after:context.wordRange.lowerBound)
    let before=String(f.sentence[..<cursor]), after=String(f.sentence[cursor...])
    let content=state.cursorMoved(contextBefore:before,contextAfter:after,hasSelection:false,at:now)
    var observed:[String:Any]=["active":active,"visibleAlternatives":false,"content":String(describing:content)]
    var checks:[String:Bool]=[:]
    if active { checks["activeSuppression"]=content == .empty }
    else {
        if case .alternatives(let word,_,let id)=content {
            observed["visibleAlternatives"]=true; observed["requestID"]=id
            checks["stoppedTapWord"]=word==f.tapped
            let repeatContent=state.cursorMoved(contextBefore:before,contextAfter:after,hasSelection:false,at:now.addingTimeInterval(1))
            checks["sameTapKeepsID"]=repeatContent==content
            let another=state.cursorMoved(contextBefore:"fresh t",contextAfter:"oken",hasSelection:false,at:now.addingTimeInterval(2))
            if case .alternatives(_,_,let next)=another { checks["newTapAdvancesID"]=next>id } else { checks["newTapAdvancesID"]=false }
        } else { checks["stoppedTapWord"]=false }
    }
    var own=SuggestionState()
    own.willApplyOwnEdit(expectedContextBefore:before,at:now)
    let early=own.cursorMoved(contextBefore:before,contextAfter:after,hasSelection:false,at:now.addingTimeInterval(0.1))
    checks["ownEditSettlingSuppresses"]=early == .empty
    let late=own.cursorMoved(contextBefore:before,contextAfter:after,hasSelection:false,at:now.addingTimeInterval(0.7))
    if case .alternatives(let word,_,_)=late { checks["ownEditExpires"]=word==f.tapped } else { checks["ownEditExpires"]=false }
    observed["ownEditEarly"]=String(describing:early); observed["ownEditLate"]=String(describing:late)
    return (observed,checks)
}
