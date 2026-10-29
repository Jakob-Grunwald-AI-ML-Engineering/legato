import Foundation
import Testing
import EvaluationSupport

@Suite struct ScratchPatchBoundaries {
    @Test(arguments: [
        ("send teh report suffix", "send the report suffix", " report suffix"),
        ("a b suffix", "a new b suffix", "b suffix"),
        ("a extra b suffix", "a b suffix", "b suffix"),
        ("go go go home", "go go stay home", " home"),
        ("Cafe\u{301} and cafe\u{301}", "Café and cafe\u{301}", " and cafe\u{301}"),
        ("👩🏽‍💻 teh 🇩🇪 👨‍👩‍👧‍👦", "👩🏽‍💻 the 🇩🇪 👨‍👩‍👧‍👦", " 🇩🇪 👨‍👩‍👧‍👦"),
        ("same", "same", "same"), ("", "new", ""), ("old", "", "")
    ]) func patchRoundTripAndRawSuffix(input: (String,String,String)) {
        let (old,new,suffix)=input
        let patch=ContiguousPatch(old:old,new:new)
        #expect(byteEqual(patch.apply(to:old) ?? "<failed>",new))
        #expect(Array((patch.apply(to:old) ?? "<failed>").utf8).suffix(suffix.utf8.count)==Array(suffix.utf8))
        #expect(patch.location+patch.removed.count <= old.count)
    }
    @Test func staleOwnedTextIsRejected() {
        let patch=ContiguousPatch(old:"a wrong tail",new:"a right tail")
        #expect(patch.apply(to:"a manual tail")==nil)
    }
    @Test func normalizationDifferenceIsNotHidden() {
        let patch=ContiguousPatch(old:"Cafe\u{301} tail",new:"Café tail")
        #expect(patch.removed.utf16.count==2)
        #expect(patch.inserted.utf16.count==1)
        #expect(byteEqual(patch.suffix," tail"))
    }
}
