import Foundation

/// Where private recordings go: folders and files only this user (and this app) can read.
///
/// - **macOS:** folders are `0700`, files `0600`.
/// - **iOS:** `completeUntilFirstUserAuthentication`, set explicitly: a meeting records while the phone is
///   locked, so "complete" protection would make the recording fail, and no protection would leave it
///   readable before the first unlock. New files inherit their folder's class.
public enum PrivateFiles {
    #if os(iOS)
    private static var directoryAttributes: [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }
    private static var fileAttributes: [FileAttributeKey: Any] { directoryAttributes }
    #else
    private static var directoryAttributes: [FileAttributeKey: Any] { [.posixPermissions: 0o700] }
    private static var fileAttributes: [FileAttributeKey: Any] { [.posixPermissions: 0o600] }
    #endif

    /// Creates `url` and any missing parents as private folders, and makes an existing `url` private too.
    public static func createDirectory(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: directoryAttributes)
        try fm.setAttributes(directoryAttributes, ofItemAtPath: url.path)
    }

    /// Makes a file that already exists (one a library created, like an audio file) private.
    public static func protect(fileAt url: URL) {
        try? FileManager.default.setAttributes(fileAttributes, ofItemAtPath: url.path)
    }

    /// Writes `data` to `url` atomically as a private file.
    public static func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        protect(fileAt: url)
    }
}
