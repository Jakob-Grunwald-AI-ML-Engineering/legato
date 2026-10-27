import Foundation
import Testing
@testable import LegatoCore

@Suite struct PrivateFilesTests {
    private func temp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("private-files-\(UUID().uuidString)")
    }

    #if os(macOS)
    @Test func foldersAreOwnerOnlyAndFilesAreOwnerReadWrite() throws {
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nested = dir.appendingPathComponent("a/b")
        try PrivateFiles.createDirectory(nested)
        #expect(try FileManager.default.attributesOfItem(atPath: nested.path)[.posixPermissions] as? Int == 0o700)

        let file = nested.appendingPathComponent("x.json")
        try PrivateFiles.write(Data("{}".utf8), to: file)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try Data(contentsOf: file) == Data("{}".utf8))
    }
    #endif

    @Test func aPublicFolderBecomesPrivate() throws {
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try PrivateFiles.createDirectory(dir)
        #if os(macOS)
        #expect(try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int == 0o700)
        #endif
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }
}
