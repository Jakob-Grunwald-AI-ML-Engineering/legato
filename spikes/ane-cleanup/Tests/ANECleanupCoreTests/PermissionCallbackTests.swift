import Foundation

@main struct PermissionCallbackTests {
    @MainActor static func main() async {
        let granted = await PermissionBridge.request { completion in
            SpikePermissionRequester.requestAuthorization { @Sendable granted in completion(granted) }
        }
        guard granted else { fatalError("FAIL: background permission result was lost") }
        print("PASS: Objective-C background permission completion safely resumes a MainActor caller under Swift 6")
    }
}
