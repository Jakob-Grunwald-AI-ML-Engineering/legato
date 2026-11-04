import Testing
@testable import LegatoMeetings

@Suite struct SummaryMarkdownTests {
    typealias Block = SummaryMarkdown.Block

    @Test func headingsNeedASpaceAfterTheHashes() {
        #expect(SummaryMarkdown.blocks("# Title\n## Decisions\n###### Deep") == [
            .heading(level: 1, text: "Title"), .heading(level: 2, text: "Decisions"), .heading(level: 6, text: "Deep"),
        ])
    }

    @Test func aHashtagIsNotAHeading() {
        #expect(SummaryMarkdown.blocks("#launch went well\n####### seven") == [
            .paragraph("#launch went well"), .paragraph("####### seven"),
        ])
    }

    @Test func checkedAndOpenChecklistItems() {
        #expect(SummaryMarkdown.blocks("- [ ] send notes\n- [x] book room\n* [X] done too\n* [ ] star open") == [
            .todo(checked: false, level: 0, text: "send notes"), .todo(checked: true, level: 0, text: "book room"),
            .todo(checked: true, level: 0, text: "done too"), .todo(checked: false, level: 0, text: "star open"),
        ])
    }

    @Test func nestedBulletsKeepTheirLevel() {
        let text = "- top\n  - child\n    - grandchild\n\t- tabbed child\n- next"
        #expect(SummaryMarkdown.blocks(text) == [
            .bullet(level: 0, text: "top"), .bullet(level: 1, text: "child"), .bullet(level: 2, text: "grandchild"),
            .bullet(level: 1, text: "tabbed child"), .bullet(level: 0, text: "next"),
        ])
    }

    @Test func numberedListsKeepTheirNumbers() {
        #expect(SummaryMarkdown.blocks("1. first\n2) second\n  3. nested\n10. tenth") == [
            .numbered(number: 1, level: 0, text: "first"), .numbered(number: 2, level: 0, text: "second"),
            .numbered(number: 3, level: 1, text: "nested"), .numbered(number: 10, level: 0, text: "tenth"),
        ])
    }

    @Test func plainLinesAreParagraphsAndBlankLinesVanish() {
        #expect(SummaryMarkdown.blocks("Hello **bold**\n\n   \n-5 degrees\n**Bold** start") == [
            .paragraph("Hello **bold**"), .paragraph("-5 degrees"), .paragraph("**Bold** start"),
        ])
    }

    @Test func bulletMarkersAreDashStarAndDot() {
        #expect(SummaryMarkdown.blocks("* star\n• dot\n- dash") == [
            .bullet(level: 0, text: "star"), .bullet(level: 0, text: "dot"), .bullet(level: 0, text: "dash"),
        ])
    }
}
