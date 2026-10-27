// CI-ONLY STUB of the `HuggingFace` module. Never shipped; used only when Package.swift runs with
// LEGATO_STUB_DEPS=1 so CI can compile and test the package without building swift-huggingface.
// It declares ONLY the symbols Legato's own code and tests use, with matching signatures and no behaviour.
// When the real dependency is bumped, or Legato calls a new API from it, update this stub to match.

import Foundation

public enum Repo {
    public struct ID: RawRepresentable, Sendable, Hashable {
        public var rawValue: String
        public init?(rawValue: String) { self.rawValue = rawValue }
    }
}

public enum TokenProvider: Sendable { case none }

public struct HubCache: Sendable {
    public init(cacheDirectory: URL) {}
}

public final class HubClient: Sendable {
    public static let defaultHost = URL(string: "https://huggingface.co")!

    public init(session: URLSession, host: URL, tokenProvider: TokenProvider, cache: HubCache?) {}

    @discardableResult
    public func downloadSnapshot(
        of repo: Repo.ID, to destination: URL, revision: String, matching globs: [String],
        progressHandler: (@MainActor @Sendable (Progress) -> Void)?
    ) async throws -> URL {
        fatalError("stub: HubClient.downloadSnapshot")
    }
}
