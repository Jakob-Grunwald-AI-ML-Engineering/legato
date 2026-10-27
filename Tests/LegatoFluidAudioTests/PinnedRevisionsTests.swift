import FluidAudio
import Foundation
import Testing
@testable import LegatoFluidAudio

/// `ModelRegistry.revisionOverrides` is process-wide, so these tests run one at a time and restore it.
@Suite("Pinned revisions", .serialized)
struct PinnedRevisionsTests {
    private static let repos: [Repo] = [
        .nemotronMultilingual, .parakeetV3, .parakeetUltra, .parakeetEou160, .parakeetEou320,
        .sortformer, .diarizer, .localVqe,
    ]

    private func isCommitHash(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private func withCleanRegistry(_ body: () -> Void) {
        let saved = ModelRegistry.revisionOverrides
        ModelRegistry.revisionOverrides = [:]
        defer { ModelRegistry.revisionOverrides = saved }
        body()
    }

    @Test func everyDownloadedRepositoryHasA40CharacterCommit() {
        for repo in Self.repos {
            let revision = FluidAudioModels.pinnedRevisions[repo.remotePath]
            #expect(revision.map(isCommitHash) == true, "\(repo.remotePath): \(revision ?? "no pin")")
        }
    }

    @Test func theMapPinsNothingElse() {
        let expected = Set(Self.repos.map(\.remotePath))
        #expect(Set(FluidAudioModels.pinnedRevisions.keys) == expected)
        #expect(FluidAudioModels.pinnedRevisions.values.allSatisfy(isCommitHash))
    }

    @Test func pinningFillsTheRegistryOverrides() {
        withCleanRegistry {
            FluidAudioModels.pinRevisions()
            for repo in Self.repos {
                #expect(ModelRegistry.revisionOverrides[repo.remotePath] != nil)
                #expect(ModelRegistry.revisionOverrides[repo.remotePath] == FluidAudioModels.pinnedRevisions[repo.remotePath])
            }
        }
    }

    @Test func pinningKeepsAnOverrideTheAppSetItself() {
        withCleanRegistry {
            let mirror = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
            ModelRegistry.revisionOverrides = [mirror: "mirror-branch"]
            FluidAudioModels.pinRevisions()
            #expect(ModelRegistry.revisionOverrides[mirror] == "mirror-branch")
            #expect(ModelRegistry.revisionOverrides[Repo.nemotronMultilingual.remotePath] != nil)
        }
    }

    @Test func pinningTwiceChangesNothing() {
        withCleanRegistry {
            FluidAudioModels.pinRevisions()
            let once = ModelRegistry.revisionOverrides
            FluidAudioModels.pinRevisions()
            #expect(ModelRegistry.revisionOverrides == once)
        }
    }
}
