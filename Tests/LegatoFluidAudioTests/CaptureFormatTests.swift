import Foundation
import LegatoCore
import Testing
@testable import LegatoFluidAudio

struct CaptureFormatTests {
    @Test(arguments: [true, false]) func installedStreamingCaptureDoesNotCreateNativeModels(nemotron: Bool) async throws {
        let id = nemotron ? FluidAudioModels.nemotronID(.latin, chunkMs: 1120) : FluidAudioModels.eouID(.ms160)
        let models = makeManager(id: id, installer: FakeInstaller(installed: true))
        let engine: any DictationEngine = nemotron
            ? NemotronEngine(variant: .latin, chunkMs: 1120, models: models)
            : ParakeetEouEngine(chunk: .ms160, models: models)
        // Stub native loaders fatalError: this also detects accidental heavyweight preparation.
        let format = try await engine.captureFormat(locale: nil)
        #expect(format == AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
    }

    @Test(arguments: [true, false]) func missingStreamingCaptureAssetsAreRefused(nemotron: Bool) async {
        let id = nemotron ? FluidAudioModels.nemotronID(.latin, chunkMs: 1120) : FluidAudioModels.eouID(.ms160)
        let models = makeManager(id: id, installer: FakeInstaller())
        let engine: any DictationEngine = nemotron
            ? NemotronEngine(variant: .latin, chunkMs: 1120, models: models)
            : ParakeetEouEngine(chunk: .ms160, models: models)
        await #expect(throws: DictationError.assetsNotInstalled) { try await engine.captureFormat(locale: nil) }
    }
}
