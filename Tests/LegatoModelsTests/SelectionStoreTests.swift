import Foundation
import Testing
@testable import LegatoModels

@Suite struct SelectionStoreTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "legato.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func selectionRoundTripsThroughUserDefaults() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SelectionStore(defaults: defaults)
        #expect(store.selected(for: .liveDictation) == nil)
        store.set("nemotron-1120", for: .liveDictation)
        #expect(store.selected(for: .liveDictation) == "nemotron-1120")
        // A second store over the same defaults (a relaunch) sees it.
        #expect(SelectionStore(defaults: defaults).selected(for: .liveDictation) == "nemotron-1120")
    }

    @Test func rolesAreIndependent() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SelectionStore(defaults: defaults)
        store.set("a", for: .liveDictation)
        store.set("b", for: .postPass)
        store.set("c", for: .cleanup)
        #expect(store.selected(for: .liveDictation) == "a")
        #expect(store.selected(for: .postPass) == "b")
        #expect(store.selected(for: .cleanup) == "c")
    }

    @Test func settingNilClearsBackToDefault() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SelectionStore(defaults: defaults)
        store.set("a", for: .cleanup)
        store.set(nil, for: .cleanup)
        #expect(store.selected(for: .cleanup) == nil)
    }

    @Test func prefixesIsolateStores() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let one = SelectionStore(defaults: defaults, prefix: "one.")
        let two = SelectionStore(defaults: defaults, prefix: "two.")
        one.set("a", for: .liveDictation)
        #expect(two.selected(for: .liveDictation) == nil)
    }

    @Test func roleKindsMatchTheirModels() {
        #expect(ModelRole.liveDictation.kind == .speechStreaming)
        #expect(ModelRole.postPass.kind == .speechBatch)
        #expect(ModelRole.cleanup.kind == .llm)
        #expect(ModelRole.liveSpeakers.kind == .speakersLive)
        #expect(ModelRole.meetingSpeakers.kind == .speakersBatch)
        #expect(ModelRole.echoNoiseCancellation.kind == .echoNoise)
    }

    @Test func aSpeakerRoleRoundTripsItsPick() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SelectionStore(defaults: defaults)
        store.set("sortformer-live", for: .liveSpeakers)
        store.set("diarizer-offline", for: .meetingSpeakers)
        #expect(store.selected(for: .liveSpeakers) == "sortformer-live")
        #expect(store.selected(for: .meetingSpeakers) == "diarizer-offline")
        #expect(store.selected(for: .echoNoiseCancellation) == nil)
    }
}
