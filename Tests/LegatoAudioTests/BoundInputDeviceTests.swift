#if os(macOS)
import Synchronization
import Testing
@testable import LegatoAudio

@Suite struct BoundInputDeviceTests {
    private final class Rig: Sendable {
        let created = Mutex<[BoundInputDevice.Plan]>([])
        let destroyed = Mutex<[UInt32]>([])
        let outputHasInput: Bool
        let validAggregate: Bool
        init(outputHasInput: Bool = false, validAggregate: Bool = true) {
            self.outputHasInput = outputHasInput
            self.validAggregate = validAggregate
        }
        var hardware: BoundInputDevice.Hardware {
            .init(describe: { id in
                switch id {
                case 92: .init(id: id, uid: "macbook-mic", inputs: 1, outputs: 0)
                case 116: .init(id: id, uid: "airpods-output", inputs: self.outputHasInput ? 1 : 0, outputs: 2)
                case 200: .init(id: id, uid: "usb-duplex", inputs: 1, outputs: 2)
                case 999: .init(id: id, uid: "aggregate", inputs: 1, outputs: 2)
                default: throw BoundInputDevice.Failure.unavailable
                }
            }, defaultOutput: { 116 }, create: { plan in
                self.created.withLock { $0.append(plan) }; return self.validAggregate ? 999 : 0
            }, destroy: { id in self.destroyed.withLock { $0.append(id) } })
        }
    }

    @Test func inputOnlyMicGetsAFullDuplexDeviceWithoutTheAirPodsMic() throws {
        let rig = Rig()
        let owner = try BoundInputDevice(input: 92, hardware: rig.hardware)
        #expect(owner.device == 999)
        let plan = try #require(rig.created.withLock { $0.first })
        #expect(plan.input.id == 92)
        #expect(plan.output.id == 116)
        #expect(plan.output.inputs == 0)
        owner.destroy()
        owner.destroy()
        #expect(rig.destroyed.withLock { $0 } == [999])
    }

    @Test func anOutputWithAnotherMicIsRejectedBeforeCreation() {
        let rig = Rig(outputHasInput: true)
        #expect(throws: BoundInputDevice.Failure.self) { _ = try BoundInputDevice(input: 92, hardware: rig.hardware) }
        #expect(rig.created.withLock { $0.isEmpty })
    }

    @Test func aDuplexSelectedDeviceIsNeverDestroyed() throws {
        let rig = Rig()
        let owner = try BoundInputDevice(input: 200, hardware: rig.hardware)
        #expect(owner.device == 200)
        owner.destroy()
        #expect(rig.created.withLock { $0.isEmpty })
        #expect(rig.destroyed.withLock { $0.isEmpty })
    }

    @Test func anUnknownCreatedDeviceIsRejected() {
        let rig = Rig(validAggregate: false)
        #expect(throws: BoundInputDevice.Failure.self) { _ = try BoundInputDevice(input: 92, hardware: rig.hardware) }
        #expect(rig.destroyed.withLock { $0.isEmpty })
    }

    @Test func ownershipEndsWithTheEngineLease() throws {
        let rig = Rig()
        do {
            let owner = try BoundInputDevice(input: 92, hardware: rig.hardware)
            #expect(owner.device == 999)
            #expect(rig.destroyed.withLock { $0.isEmpty })
        }
        #expect(rig.destroyed.withLock { $0 } == [999])
    }
}
#endif
