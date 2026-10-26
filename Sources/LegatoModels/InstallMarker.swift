import Foundation

/// The file a model folder carries to say how far its install got.
///
/// A folder with the right files is not necessarily a finished install: a download cut short, or a first
/// compile that failed, leaves the files in place. ``ModelManager`` writes the marker in two steps,
/// `downloaded` once the installer's download returned and `installed` once warm-up succeeded, and treats a
/// model as installed only when the `installed` marker names it and the installer agrees the files are there.
public enum InstallMarker {
    /// The marker's file name inside the model folder.
    public static let fileName = ".legato-installed"

    /// How far the install of the folder got.
    public enum Stage: String, Sendable, Codable, Hashable {
        /// Downloaded completely; warm-up has not succeeded yet.
        case downloaded
        /// Downloaded and warmed: ready to use.
        case installed
    }

    private struct Contents: Codable {
        var id: String
        var stage: Stage
        var date: Date
    }

    /// The stage recorded in `folder` for model `id`, or `nil` without a readable marker naming `id`.
    public static func stage(in folder: URL, id: String) -> Stage? {
        guard let data = try? Data(contentsOf: folder.appending(path: fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let contents = try? decoder.decode(Contents.self, from: data), contents.id == id else { return nil }
        return contents.stage
    }

    /// Records `stage` for model `id` in `folder`, creating the folder if needed.
    public static func write(in folder: URL, id: String, stage: Stage, date: Date = Date()) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Contents(id: id, stage: stage, date: date))
        try data.write(to: folder.appending(path: fileName), options: .atomic)
    }
}
