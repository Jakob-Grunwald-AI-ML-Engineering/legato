import Foundation

/// The single writer of one word-pair file: a ``WordPairModel`` rewritten atomically.
///
/// Share exactly one instance per file (the actor serializes access only within an instance; there is no file
/// locking). The keyboard extension never uses this type for the app's file; it reads with
/// ``WordPairModel/read(from:)``. A file that cannot be read starts an empty model, since the data is derived
/// and ``rebuild(from:now:)`` restores it.
public actor WordPairStore {
    public let fileURL: URL
    private let languages: [String]
    private var cache: WordPairModel?

    public init(fileURL: URL, languages: [String] = []) {
        self.fileURL = fileURL
        self.languages = languages
    }

    /// The model as of now. A missing or unreadable file is an empty model.
    public func model() -> WordPairModel { current() }

    /// Learns the word pairs of `text` and writes the file.
    public func observe(text: String, now: Date = Date()) throws {
        var model = current()
        model.observe(text: text, at: now)
        try commit(model, now: now)
    }

    /// Replaces everything learned with the pairs of `texts` (oldest first) and writes the file.
    public func rebuild(from texts: [String], now: Date = Date()) throws {
        var model = WordPairModel(languages: languages)
        for text in texts { model.observe(text: text, at: now) }
        try commit(model, now: now)
    }

    /// Forgets everything and removes the file.
    public func wipe() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
        cache = WordPairModel(languages: languages)
    }

    private func current() -> WordPairModel {
        if let cache { return cache }
        let model = WordPairModel.read(from: fileURL) ?? WordPairModel(languages: languages)
        cache = model
        return model
    }

    private func commit(_ model: WordPairModel, now: Date) throws {
        var model = model
        model.prune(now: now)
        if !languages.isEmpty { model.languages = languages }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WordPairModel.encode(model).write(to: fileURL, options: .atomic)
        cache = model
    }
}
