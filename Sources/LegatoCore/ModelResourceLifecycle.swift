/// Resource preparation independent of microphone capture and per-run decoder state.
public protocol ModelResourceLifecycle: Sendable {
    /// Loads already installed resources without inference, downloads, or resetting an active run.
    func prewarmResources() async throws
    /// Relinquishes the owner's warm references. Native/run-owned references remain valid; this does
    /// not promise that an operating-system-managed model has left memory.
    func releaseWarmResources() async
}
