import Foundation
import LegatoModels
import Testing
@testable import LegatoFluidAudio

private func url(_ name: String) -> URL { URL(fileURLWithPath: "/models/\(name)") }

@Suite("FluidAudio model caches")
struct FluidAudioModelCacheTests {
    @Test func theNemotronAndEouCachesKeepOneFolderEach() async {
        #expect(await NemotronModelCache.shared.capacity == 1)
        #expect(await EouModelCache.shared.capacity == 1)
    }

    @Test func releasingAFolderReachesBothSharedCaches() async {
        // Nothing is loaded here; the call must simply be safe to make for any folder.
        await FluidAudioModels.release(folder: url("nemotron-multilingual/latin/560ms"))
        await releaseCachedNemotronModels()
    }
}
