import Foundation
import LegatoModels

/// The file transport boundary; the installer owns path, revision and content verification.
public protocol CoreMLFileFetcher: Sendable {
    func fetch(_ source: URL, to destination: URL) async throws
}
public struct CoreMLHTTPFetcher: CoreMLFileFetcher {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        self.session = session ?? URLSession(configuration: configuration)
    }
    public func fetch(_ source: URL, to destination: URL) async throws {
        let (temporary, response) = try await session.download(from: source)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw CoreMLInstallError.invalidResponse }
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: temporary, to: destination)
    }
}
public enum CoreMLInstallError: Error, Sendable, Equatable {
    case invalidManifest, invalidPath(String), invalidFile(String), incomplete, invalidResponse
}

/// Downloading is opt-in. Every file is checked against the shipped manifest before publishing a receipt.
public struct CoreMLInstaller: ModelInstaller {
    let spec: CoreMLModelSpec
    let fetcher: any CoreMLFileFetcher
    private let manifestOverride: CoreMLManifest?
    public init(spec: CoreMLModelSpec, fetcher: any CoreMLFileFetcher = CoreMLHTTPFetcher()) {
        self.spec = spec; self.fetcher = fetcher; self.manifestOverride = nil
    }
    init(spec: CoreMLModelSpec, fetcher: any CoreMLFileFetcher, manifest: CoreMLManifest) {
        self.spec = spec; self.fetcher = fetcher; self.manifestOverride = manifest
    }
    private func manifest() throws -> CoreMLManifest {
        let manifest = try manifestOverride ?? CoreMLManifest.bundled(for: spec)
        try manifest.validate(for: spec)
        return manifest
    }
    public func installFolder(root: URL) -> URL { spec.folder(root: root) }
    private func checkedFolder(root: URL) throws -> URL {
        var current = root.standardizedFileURL
        for component in ["coreml", spec.folderName] {
            current.append(path: component)
            if FileManager.default.fileExists(atPath: current.path) {
                let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw CoreMLInstallError.invalidPath(component) }
            }
        }
        return current
    }
    public func isInstalled(root: URL) async -> Bool {
        guard let manifest = try? manifest(), let folder = try? checkedFolder(root: root) else { return false }
        return CoreMLReceipt.isComplete(folder: folder, manifest: manifest)
    }
    public func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let manifest = try manifest()
        let folder = try checkedFolder(root: root)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let total = manifest.files.reduce(Int64(0)) { $0 + $1.bytes }
        var completed: Int64 = 0
        progress(0)
        for file in manifest.files {
            try Task.checkCancellation()
            let destination = try CoreMLReceipt.safeURL(file.path, folder: folder)
            let valid = (try? CoreMLReceipt.stamp(destination).bytes) == Int(file.bytes)
                && (try? CoreMLReceipt.hash(destination)) == file.sha256
            if !valid {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temporary = destination.appendingPathExtension("partial-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let source = URL(string: "https://huggingface.co/\(spec.repo)/resolve/\(spec.revision)/\(file.path)") else { throw CoreMLInstallError.invalidManifest }
                try await fetcher.fetch(source, to: temporary)
                try Task.checkCancellation()
                guard try CoreMLReceipt.stamp(temporary).bytes == Int(file.bytes), try CoreMLReceipt.hash(temporary) == file.sha256 else {
                    throw CoreMLInstallError.invalidFile(file.path)
                }
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            completed += file.bytes
            progress(Double(completed) / Double(total))
        }
        try Task.checkCancellation()
        let stamps = try CoreMLReceipt.inspect(folder: folder, manifest: manifest, verifyHashes: true)
        let receipt = CoreMLReceipt(manifest: try manifest.fingerprint, stamps: stamps)
        let receiptURL = try CoreMLReceipt.safeURL(CoreMLReceipt.name, folder: folder)
        try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
        try Task.checkCancellation()
    }
    public func warm(root: URL) async throws {
        let backend = await CoreMLModelStore.shared.backend(for: spec, root: root)
        try await backend.prepare()
    }
    /// Full initial-load verification is deliberately independent of the cheap install receipt check.
    static func validateInstalled(folder: URL, spec: CoreMLModelSpec) throws {
        let manifest = try CoreMLManifest.bundled(for: spec)
        guard CoreMLReceipt.isComplete(folder: folder, manifest: manifest) else { throw CoreMLInstallError.incomplete }
        _ = try CoreMLReceipt.inspect(folder: folder, manifest: manifest, verifyHashes: true)
    }
}
