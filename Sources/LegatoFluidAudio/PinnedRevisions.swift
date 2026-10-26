import FluidAudio
import Foundation
import Synchronization

extension FluidAudioModels {
    /// The Hugging Face commit each downloaded repository is pinned to, keyed by the repository path
    /// FluidAudio uses (`ModelRegistry.revisionOverrides`' key format; longest-prefix matching, so one
    /// entry covers every tier folder of a repository). FluidAudio downloads from `main` by default, which
    /// lets an upstream push change the files a released build loads.
    ///
    /// Bumping a commit is a deliberate commit: read the repository's changes, fetch the new hash with
    /// `curl -s https://huggingface.co/api/models/<repo>` (`sha`), and update the date below.
    /// Last reviewed 2026-10-26.
    public static let pinnedRevisions: [String: String] = [
        "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML": "1a41b75758b0337ff67db7d5408280aaaf23074e",
        "FluidInference/parakeet-tdt-0.6b-v3-coreml": "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
        "FluidInference/parakeet-ultra-coreml": "95eaa59a39d4394f047a4dc5cce480388a60d1b6",
        "FluidInference/parakeet-realtime-eou-120m-coreml": "40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355",
    ]

    /// Serializes this module's writes to the registry's process-wide (unsynchronized) overrides.
    private static let pinLock = Mutex(())

    /// Makes FluidAudio download the pinned commits: adds ``pinnedRevisions`` to
    /// `ModelRegistry.revisionOverrides`, except for repositories the app already set. Safe to call any number
    /// of times; the installers and ``FluidAudioCatalog``'s manager call it before
    /// they download, and an app that downloads some other way calls it first.
    public static func pinRevisions() {
        pinLock.withLock { _ in
            var overrides = ModelRegistry.revisionOverrides
            for (repository, revision) in pinnedRevisions where overrides[repository] == nil {
                overrides[repository] = revision
            }
            if overrides != ModelRegistry.revisionOverrides { ModelRegistry.revisionOverrides = overrides }
        }
    }

    /// Whether FluidAudio will download every pinned repository at its pinned commit (or the commit an app
    /// chose for it) rather than from `main`.
    public static var revisionsArePinned: Bool {
        pinLock.withLock { _ in
            pinnedRevisions.keys.allSatisfy { ModelRegistry.revisionOverrides[$0] != nil }
        }
    }
}
