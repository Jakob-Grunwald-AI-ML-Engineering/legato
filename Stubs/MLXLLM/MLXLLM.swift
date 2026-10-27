// CI-ONLY STUB of the `MLXLLM` module. Never shipped; used only when Package.swift runs with
// LEGATO_STUB_DEPS=1 so CI can compile and test the package without building mlx-swift-lm.
// It declares ONLY the symbols Legato's own code and tests use, with matching signatures and no behaviour.
// When the real dependency is bumped, or Legato calls a new API from it, update this stub to match.

import Foundation
import MLXLMCommon

public final class LLMModelFactory: Sendable {
    public static let shared = LLMModelFactory()

    public func loadContainer(
        from downloader: some Downloader, using tokenizerLoader: some TokenizerLoader,
        configuration: ModelConfiguration
    ) async throws -> ModelContainer {
        fatalError("stub: LLMModelFactory.loadContainer")
    }
}
