import Foundation
import Testing
@testable import LegatoKeyboardCore

@Test func guardedInsertCannotFollowKeyboardToAnotherDocument() {
    let now = Date()
    var state = HostState(runID: "insert", phase: .idle, target: .keyboard, committed: "Message", volatile: "", seq: 1, beatAt: now, leaseUntil: nil, acceptsRemoteStart: false, insertAt: now)
    state.insertDocumentID = "field-one"
    #expect(HostApplyDecision.decide(host: state, cursor: nil, visible: true, documentID: "field-one", now: now) == .apply)
    #expect(HostApplyDecision.decide(host: state, cursor: nil, visible: true, documentID: "field-two", now: now) == .skip(.changedDocument))
}
