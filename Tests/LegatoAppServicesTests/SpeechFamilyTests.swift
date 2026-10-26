import Foundation
import LegatoModels
import Testing
@testable import LegatoAppServices

private struct Rig {
    let root = FileManager.default.temporaryDirectory.appending(path: "legato-families-\(UUID().uuidString)")
    let suite = "legato.families.\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    @MainActor func services() -> ModelServices {
        ModelServices(root: root, defaults: defaults, platform: .macOS)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor @Suite struct SpeechFamilyTests {
    @Test func theSpeechScreenListsThreeFamiliesNotSevenModels() {
        let rig = Rig()
        defer { rig.cleanUp() }
        let services = rig.services()
        #expect(services.streamingModels.count == 8, "the eight downloads stay in the catalog")
        #expect(services.streamingFamilies.map(\.id) == ["nemotron-multilingual", "nemotron-latin", "parakeet-eou"])
    }

    @Test func nothingPickedShowsTheDefaultTierAndNoActiveFamily() {
        let rig = Rig()
        defer { rig.cleanUp() }
        let services = rig.services()
        let nemotron = services.streamingFamilies[0]
        #expect(services.activeFamily == nil)
        #expect(services.chosenTier(of: nemotron) == 1120)
        #expect(services.chosenTier(of: services.streamingFamilies[2]) == 320)
    }

    @Test func aPickWrittenBeforeFamiliesExistedReadsAsThatFamilyAtThatTier() {
        let rig = Rig()
        defer { rig.cleanUp() }
        SelectionStore(defaults: rig.defaults).set("nemotron-latin-2240", for: .liveDictation)
        let services = rig.services()
        #expect(services.activeFamily?.id == "nemotron-latin")
        #expect(services.chosenTier(of: services.streamingFamilies[1]) == 2240)
        #expect(services.chosenTier(of: services.streamingFamilies[0]) == 1120, "other families keep their default")
        #expect(services.selected(.liveDictation) == "nemotron-latin-2240", "the persisted id is untouched")
    }

    @Test func settingTheTierOfAFamilyThatIsNotLiveOnlyRemembersIt() {
        let rig = Rig()
        defer { rig.cleanUp() }
        SelectionStore(defaults: rig.defaults).set("parakeet-eou-160", for: .liveDictation)
        let services = rig.services()
        let nemotron = services.streamingFamilies[0]

        let started = services.setTier(560, of: nemotron) { _ in Issue.record("no pick should run") }

        #expect(!started, "no download starts")
        #expect(services.chosenTier(of: nemotron) == 560)
        #expect(services.selected(.liveDictation) == "parakeet-eou-160")
        // A relaunch sees the remembered tier.
        #expect(rig.services().chosenTier(of: rig.services().streamingFamilies[0]) == 560)
    }

    @Test func theChosenModelIsTheCatalogEntryOfTheChosenTier() {
        let rig = Rig()
        defer { rig.cleanUp() }
        SelectionStore(defaults: rig.defaults).set("nemotron-latin-2240", for: .liveDictation)
        let services = rig.services()
        #expect(services.chosenModel(of: services.streamingFamilies[0])?.id == "nemotron-multilingual-1120")
        #expect(services.chosenModel(of: services.streamingFamilies[1])?.id == "nemotron-latin-2240")
        #expect(services.chosenModel(of: services.streamingFamilies[2])?.id == "parakeet-eou-320")
    }

    // MARK: a tier flurry downloads only the last tier

    @Test func aNewerTierOfTheSameFamilySupersedesThePickInFlight() {
        #expect(ModelServices.supersededPick(inFlight: "nemotron-multilingual-560", next: "nemotron-multilingual-1120")
            == "nemotron-multilingual-560")
        #expect(ModelServices.supersededPick(inFlight: "nemotron-multilingual-1120", next: "nemotron-multilingual-2240")
            == "nemotron-multilingual-1120")
    }

    /// Requirement changed (review of PR #30): a pick of another family also stops the download in flight.
    @Test func aPickOfAnotherFamilySupersedesThePickInFlightTheSameModelNothing() {
        #expect(ModelServices.supersededPick(inFlight: "nemotron-multilingual-560", next: "parakeet-eou-320") == "nemotron-multilingual-560")
        #expect(ModelServices.supersededPick(inFlight: "nemotron-latin-560", next: "nemotron-multilingual-560") == "nemotron-latin-560")
        #expect(ModelServices.supersededPick(inFlight: "nemotron-multilingual-560", next: "nemotron-multilingual-560") == nil)
        #expect(ModelServices.supersededPick(inFlight: nil, next: "nemotron-multilingual-560") == nil)
    }

    @Test func theLiveLabelNamesTheFamilyAndItsTier() {
        let rig = Rig()
        defer { rig.cleanUp() }
        let services = rig.services()
        let eou = services.streamingFamilies[2]
        #expect(services.liveLabel(of: eou) == "Parakeet EOU · 320 ms")
        #expect(services.liveLabel(of: services.streamingFamilies[0]) == "Nemotron multilingual · 1120 ms")
    }
}
