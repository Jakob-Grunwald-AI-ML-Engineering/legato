import CryptoKit
import Foundation

struct CoreMLArtifact: Codable, Sendable, Hashable { let path: String; let bytes: Int64; let sha256: String }
struct CoreMLManifest: Codable, Sendable {
    let repository: String
    let revision: String
    let files: [CoreMLArtifact]

    func validate(for spec: CoreMLModelSpec) throws {
        for file in files { try Self.validatePath(file.path) }
        let required = spec.requiredArtifactPaths
        guard repository == spec.repo, revision == spec.revision, revision.count == 40,
              revision.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              Set(files.map(\.path)) == required, files.count == required.count,
              files.allSatisfy({ $0.bytes > 0 && $0.sha256.count == 64 && $0.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase } }) else {
            throw CoreMLInstallError.invalidManifest
        }
    }
    static func validatePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CoreMLInstallError.invalidPath(path)
        }
    }
    static func bundled(for spec: CoreMLModelSpec) throws -> CoreMLManifest {
        guard let url = Bundle.module.url(forResource: spec.manifestResource, withExtension: "json") else { throw CoreMLInstallError.invalidManifest }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try manifest.validate(for: spec)
        return manifest
    }
    var fingerprint: String {
        get throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return Self.digest(try encoder.encode(self))
        }
    }
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}

/// The install receipt pins the exact manifest and file modification stamps. State reads do no weight hashing.
struct CoreMLReceipt: Codable {
    static let name = ".legato-coreml-verified.json"
    let manifest: String
    let stamps: [String: FileStamp]
    struct FileStamp: Codable, Equatable {
        let bytes: Int
        let modified: Date
    }
    static func stamp(_ url: URL) throws -> FileStamp {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize, let modified = values.contentModificationDate else {
            throw CoreMLInstallError.invalidFile(url.lastPathComponent)
        }
        return .init(bytes: bytes, modified: modified)
    }
    static func safeURL(_ path: String, folder: URL) throws -> URL {
        try CoreMLManifest.validatePath(path)
        var current = folder.standardizedFileURL
        let rootValues = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard rootValues.isSymbolicLink != true else { throw CoreMLInstallError.invalidPath(path) }
        for component in path.split(separator: "/") {
            current.append(path: String(component))
            if FileManager.default.fileExists(atPath: current.path) {
                let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw CoreMLInstallError.invalidPath(path) }
            }
        }
        return current
    }
    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation(); digest.update(data: bytes)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func inspect(folder: URL, manifest: CoreMLManifest, verifyHashes: Bool) throws -> [String: FileStamp] {
        var result: [String: FileStamp] = [:]
        for file in manifest.files {
            try Task.checkCancellation()
            let url = try safeURL(file.path, folder: folder)
            let stamp = try stamp(url)
            guard Int64(stamp.bytes) == file.bytes else { throw CoreMLInstallError.invalidFile(file.path) }
            if verifyHashes {
                guard try hash(url) == file.sha256, try self.stamp(url) == stamp else { throw CoreMLInstallError.invalidFile(file.path) }
            }
            result[file.path] = stamp
        }
        return result
    }
    static func isComplete(folder: URL, manifest: CoreMLManifest) -> Bool {
        do {
            let url = try safeURL(name, folder: folder)
            let receipt = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard receipt.manifest == (try manifest.fingerprint), receipt.stamps.count == manifest.files.count else { return false }
            return try inspect(folder: folder, manifest: manifest, verifyHashes: false) == receipt.stamps
        } catch { return false }
    }
}
