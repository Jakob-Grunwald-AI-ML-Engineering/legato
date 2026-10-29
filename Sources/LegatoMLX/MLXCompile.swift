import Foundation
import MLX
import Synchronization

/// Whether MLX fuses operations into compiled kernels (`MLX.compile`), and turning that off where a CPU
/// generation cannot run them.
///
/// MLXNN's activations are compiled functions (`silu` in every Qwen3 MLP is `compiledSilu`). On the CPU a fused
/// kernel is C++ built at run time by a JIT compiler; iOS has none, so its build of MLX throws at the first
/// fused CPU kernel ("[Compiled::eval_cpu] CPU compilation not supported on the platform"). MLX skips fusion
/// only when its own global default device cannot compile, and that stays the GPU: `Device.withDefaultDevice(.cpu)`
/// sets a task-local default that MLX's C++ never sees. Compile is a process-wide switch in MLX, so turning it
/// off for a CPU generation turns it off for GPU work in the same process too (slower, still correct).
public enum MLXCompile {
    private struct State { var enabled: Bool; var cpuAllowed: Bool }

    private static let state = Mutex(State(
        enabled: ProcessInfo.processInfo.environment["MLX_DISABLE_COMPILE"] == nil,
        cpuAllowed: platformCompilesOnCPU))

    /// Whether this platform's MLX can run compiled kernels on the CPU (the Mac has a JIT C++ compiler).
    public static var platformCompilesOnCPU: Bool {
        #if os(iOS) || os(visionOS)
            false
        #else
            true
        #endif
    }

    /// Whether compile is on for the process (MLX's own default, or `MLX_DISABLE_COMPILE` at launch).
    public static var isEnabled: Bool { state.withLock { $0.enabled } }

    /// "on" or "off", for logs.
    public static var label: String { isEnabled ? "on" : "off" }

    /// Whether CPU work may use compiled kernels. Never on iOS; the Mac turns it off to run as the phone does.
    public static var allowedOnCPU: Bool {
        get { state.withLock { $0.cpuAllowed } }
        set { state.withLock { $0.cpuAllowed = newValue && platformCompilesOnCPU } }
    }

    /// Before work on `device`: turns compile off for the process when that work may not use it. Once off, it
    /// stays off.
    public static func prepare(for device: ComputeDevice) {
        guard device == .cpu else { return }
        state.withLock { state in
            guard state.enabled, !state.cpuAllowed else { return }
            // MLX checks the mode at every call of a compiled function, so the functions MLXNN already built
            // run unfused from here on. Only the real MLX has the switch (Cmlx is its C core; the CI stub of
            // `MLX` has neither), and the state says on until it was really turned off.
            #if canImport(Cmlx)
                MLX.compile(enable: false)
                state.enabled = false
            #endif
        }
    }
}
