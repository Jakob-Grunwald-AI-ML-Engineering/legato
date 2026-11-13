import Foundation
import Testing
@testable import LegatoKeyboardCore

struct LiveCorrectionMetadataTests {
    @Test func singleCleanedSegmentRetainsOriginalASRText() {
        var run = LiveDictationRun()
        run.addFinal(key: 0, text: "please bring the blue folder")
        run.setCleaned(key: 0, text: "Please Bring The Blue Folder")
        run.finish()
        #expect(run.snapshot.rawText == "please bring the blue folder")
        #expect(run.snapshot.segments.first?.text == "Please Bring The Blue Folder")
    }
    @Test func oldSnapshotsStillDecodeWithoutRawMetadata() throws {
        let data = Data(#"{"runID":"old","version":1,"segments":[],"complete":true}"#.utf8)
        #expect(try JSONDecoder().decode(LiveDictationSnapshot.self, from: data).rawText == nil)
    }
}
