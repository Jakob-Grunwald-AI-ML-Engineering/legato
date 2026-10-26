import Foundation
import Testing
@testable import LegatoKeyboardCore

/// Stands in for UIKit's text document proxy: an ObjC object whose `documentIdentifier` is nil while no
/// field is bound. (Reading that through the imported non-optional `UUID` traps in the bridge; the
/// trap itself can't be asserted in a test, so the contract tested is that the reader returns nil.)
private final class FakeProxy: NSObject {
    @objc var documentIdentifier: NSUUID?
}

@Suite struct NilSafeObjCTests {
    @Test func aNilPropertyReadsAsNil() {
        let proxy = FakeProxy()
        #expect(NilSafeObjC.uuid("documentIdentifier", of: proxy) == nil)
    }

    @Test func aSetPropertyReadsAsItsValue() {
        let proxy = FakeProxy()
        let id = UUID()
        proxy.documentIdentifier = id as NSUUID
        #expect(NilSafeObjC.uuid("documentIdentifier", of: proxy) == id)
    }

    @Test func anObjectWithoutThePropertyReadsAsNil() {
        #expect(NilSafeObjC.uuid("documentIdentifier", of: NSObject()) == nil)
    }
}
