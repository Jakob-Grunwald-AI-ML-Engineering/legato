import Foundation
import LegatoCore
import LegatoFieldEdit
import Testing
@testable import LegatoMac

/// An agent patch that lands in the writer's tentative text (`.streamLive`) is folded in; it never degrades the
/// writer or stops the streaming.
@MainActor
@Suite struct FieldWriterAbsorbTests {
    private func span(of text: String, in field: FakeTextTarget) -> Span {
        let range = (field.string as NSString).range(of: text)
        return Span(location: range.location, length: range.length)
    }

    @Test func aPatchInsideTentativeTextKeepsStreaming() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field, mode: .streamLive)
        writer.apply(.commit(delta: "Send the report."))
        writer.apply(.replaceVolatile(" and teh dog"))
        let target = span(of: "eh", in: field)
        field.externalEdit(UTF16Range(location: target.location, length: target.length), with: "he")
        writer.absorb(EditStep(span: target, text: "he", expect: "eh"))
        #expect(writer.degradeReason == nil)

        writer.apply(.replaceVolatile(" and the dog now"))
        writer.apply(.commit(delta: " and the dog now."))
        #expect(writer.degradeReason == nil)
        #expect(field.string == "Send the report. and the dog now.")
        #expect(writer.finish(finalText: nil) == .done)
    }

    @Test func aPatchAcrossTheEdgeOfTentativeTextKeepsStreaming() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field, mode: .streamLive)
        writer.apply(.commit(delta: "Send teh"))
        writer.apply(.replaceVolatile(" dog"))
        let target = span(of: "eh dog", in: field)
        field.externalEdit(UTF16Range(location: target.location, length: target.length), with: "he cat")
        writer.absorb(EditStep(span: target, text: "he cat", expect: "eh dog"))
        #expect(writer.degradeReason == nil)

        writer.apply(.replaceVolatile(" now"))
        #expect(writer.degradeReason == nil)
        #expect(field.string == "Send the cat now")
    }

    @Test func aPatchThatDoesNotMatchWhatTheWriterWroteStillDegrades() {
        let field = FakeTextTarget()
        let writer = FieldWriter(target: field, mode: .streamLive)
        writer.apply(.commit(delta: "Send teh"))
        writer.apply(.replaceVolatile(" dog"))
        writer.absorb(EditStep(span: Span(location: 9, length: 3), text: "cat", expect: "cow"))
        #expect(writer.degradeReason == .drift)
    }
}
