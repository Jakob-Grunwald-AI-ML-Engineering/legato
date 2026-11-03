import Testing
@testable import LegatoAudio

@Suite struct PreferredInputRouteTests {
    private let ports: [InputPortInfo] = [
        .init(id: "pods", kind: .bluetooth), .init(id: "mic", kind: .builtIn), .init(id: "usb", kind: .other),
    ]

    @Test func idlePrefersTheBuiltInMicEvenWithAirPodsConnected() {
        #expect(PreferredInputRoute.choose(.builtIn, among: ports)?.id == "mic")
    }
    @Test func aTakePrefersTheBluetoothMic() {
        #expect(PreferredInputRoute.choose(.bluetooth, among: ports)?.id == "pods")
    }
    @Test func withoutAMatchingPortTheSystemChoiceStands() {
        #expect(PreferredInputRoute.choose(.bluetooth, among: ports.filter { $0.kind != .bluetooth }) == nil)
        #expect(PreferredInputRoute.choose(.builtIn, among: []) == nil)
    }
}
