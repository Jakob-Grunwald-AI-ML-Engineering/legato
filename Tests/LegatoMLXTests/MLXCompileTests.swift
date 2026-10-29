import Testing
@testable import LegatoMLX

@Suite("MLX compile switch", .serialized)
struct MLXCompileTests {
    @Test func onlyTheMacCompilesOnTheCPU() {
        #if os(iOS) || os(visionOS)
            #expect(!MLXCompile.platformCompilesOnCPU)
            MLXCompile.allowedOnCPU = true
            #expect(!MLXCompile.allowedOnCPU)
        #else
            #expect(MLXCompile.platformCompilesOnCPU)
        #endif
    }

    @Test func gpuWorkNeverTurnsCompileOff() {
        let before = MLXCompile.isEnabled
        let allowed = MLXCompile.allowedOnCPU
        defer { MLXCompile.allowedOnCPU = allowed }
        MLXCompile.allowedOnCPU = false
        MLXCompile.prepare(for: .gpu)
        #expect(MLXCompile.isEnabled == before)
    }

    @Test func cpuWorkKeepsCompileWhereTheCPUMayCompile() {
        guard MLXCompile.platformCompilesOnCPU else { return }
        let before = MLXCompile.isEnabled
        MLXCompile.allowedOnCPU = true
        MLXCompile.prepare(for: .cpu)
        #expect(MLXCompile.isEnabled == before)
        #expect(MLXCompile.label == (before ? "on" : "off"))
    }
}
