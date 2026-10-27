import Foundation

/// Preserves the exact unsafe setup pattern against an Objective-C/TCC-style background callback.
@main struct PermissionCallbackRepro {
    @MainActor static func main() async {
        let granted: Bool = await withCheckedContinuation { continuation in
            SpikePermissionRequester.requestAuthorization { granted in
                continuation.resume(returning: granted)
            }
        }
        guard granted else { fatalError("FAIL: background permission result was lost") }
        print("permission callback completed")
    }
}
