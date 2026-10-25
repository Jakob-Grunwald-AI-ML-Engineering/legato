import Foundation

public enum DictationError: Error, Sendable, Equatable {
    /// The speech model for the requested locale is not installed; call `installAssets` from the foreground.
    case assetsNotInstalled
    /// `start()` while a run is already preparing, listening or finishing.
    case alreadyRunning
    /// `stop()` with no run in progress.
    case notRunning
    /// The run was cancelled (e.g. `stop()` while preparing).
    case cancelled
}
