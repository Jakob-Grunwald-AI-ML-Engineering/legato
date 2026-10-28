import Foundation
import Synchronization
import Testing
@testable import LegatoFluidAudio

private final class SpeechWeights: Sendable {
    let transcript = Mutex("live transcript")
    let callback = Mutex("active callback")
}

struct SelectedSpeechModelCacheTests {
    @Test func selectedWeightsSurviveMeetingTierEvictionAndMaintenanceWithoutResettingRunState() async throws {
        let cache = SelectedSpeechModelCache<SpeechWeights>()
        let selected = URL(fileURLWithPath: "/models/selected")
        let meeting = URL(fileURLWithPath: "/models/meeting")
        let loads = Mutex(0)
        let active = try await cache.model(at: selected) { loads.withLock { $0 += 1 }; return SpeechWeights() }
        await cache.retainSelected(active, at: selected)
        _ = try await cache.model(at: meeting) { SpeechWeights() }
        await cache.evictUnselected(exceptFolder: selected)
        let resumed = try await cache.model(at: selected) { loads.withLock { $0 += 1 }; return SpeechWeights() }
        #expect(active === resumed)
        #expect(loads.withLock { $0 } == 1)
        #expect(resumed.transcript.withLock { $0 } == "live transcript")
        #expect(resumed.callback.withLock { $0 } == "active callback")
    }

    @Test func releasingSelectedWeightsDoesNotResetAnActiveConsumersReference() async throws {
        let cache = SelectedSpeechModelCache<SpeechWeights>()
        let folder = URL(fileURLWithPath: "/models/selected")
        let active = try await cache.model(at: folder) { SpeechWeights() }
        await cache.retainSelected(active, at: folder)
        await cache.evictAll()
        let replacement = try await cache.model(at: folder) { SpeechWeights() }
        #expect(active !== replacement)
        #expect(active.transcript.withLock { $0 } == "live transcript")
        #expect(active.callback.withLock { $0 } == "active callback")
    }

    @Test func maintenanceWithAnOldSelectionSnapshotCannotEvictNewSelectedWeights() async throws {
        let cache = SelectedSpeechModelCache<SpeechWeights>()
        let old = URL(fileURLWithPath: "/models/old")
        let current = URL(fileURLWithPath: "/models/current")
        let meeting = URL(fileURLWithPath: "/models/meeting")
        let weights = try await cache.model(at: current) { SpeechWeights() }
        await cache.retainSelected(weights, at: current)
        _ = try await cache.model(at: meeting) { SpeechWeights() }
        await cache.evictUnselected(exceptFolder: old)
        let resumed = try await cache.model(at: current) { SpeechWeights() }
        #expect(weights === resumed)
    }
}
