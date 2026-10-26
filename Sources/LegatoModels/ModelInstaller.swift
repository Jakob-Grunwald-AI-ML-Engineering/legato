import Foundation

/// Downloads and prepares one model into the Legato storage root.
///
/// One installer instance is bound to one catalog model. Families plug in here (FluidAudio for speech,
/// MLX for language models); ``ModelManager`` owns state, cancellation, sharing and deletion, so an
/// installer only does the work and declares where it put it.
public protocol ModelInstaller: Sendable {
    /// The folder under `root` this installer owns. The manager deletes it and measures its size.
    func installFolder(root: URL) -> URL

    /// Whether the model is fully on disk. Cheap; never downloads.
    func isInstalled(root: URL) async -> Bool

    /// Downloads the model, reporting the fraction done in `0...1`. Must honor task cancellation by
    /// throwing; the manager then removes whatever was left in ``installFolder(root:)``.
    func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws

    /// Runs the one-time compile that makes the first session fast. May be a no-op.
    func warm(root: URL) async throws
}
