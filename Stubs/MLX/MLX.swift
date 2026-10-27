// CI-ONLY STUB of the `MLX` module. Never shipped; used only when Package.swift runs with
// LEGATO_STUB_DEPS=1 so CI can compile and test the package without building MLX (mlx-swift).
// It declares ONLY the symbols Legato's own code and tests use, with matching signatures and no behaviour.
// When the real dependency is bumped, or Legato calls a new API from it, update this stub to match.

public struct Device: Sendable {
    public static let cpu = Device()
    public static let gpu = Device()

    public static func withDefaultDevice<R>(_ device: Device, _ body: () throws -> R) rethrows -> R {
        fatalError("stub: Device.withDefaultDevice")
    }
    public static func withDefaultDevice<R>(_ device: Device, _ body: () async throws -> R) async rethrows -> R {
        fatalError("stub: Device.withDefaultDevice (async)")
    }
}

public func withError<R>(_ body: () async throws -> R) async throws -> R {
    fatalError("stub: withError")
}

public func withErrorHandler<R>(_ handler: @escaping @Sendable (String) -> Void, _ body: () throws -> R) rethrows -> R {
    fatalError("stub: withErrorHandler")
}
