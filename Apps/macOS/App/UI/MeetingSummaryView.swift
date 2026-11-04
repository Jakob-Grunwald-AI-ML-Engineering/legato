import LegatoMeetings
import SwiftUI

/// A summary as the document shows it: headings, bullets, checklists and paragraphs, with inline Markdown.
struct MeetingSummaryView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(SummaryMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in view(block) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(_ block: SummaryMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let title):
            inline(title).font(level <= 1 ? .title2.weight(.bold) : .headline).padding(.top, level <= 2 ? 10 : 4)
        case .bullet(let level, let item):
            row("•", item, level: level)
        case .todo(let checked, let level, let item):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                inline(item).strikethrough(checked)
            }
            .padding(.leading, CGFloat(level) * 18)
        case .numbered(let number, let level, let item):
            row("\(number).", item, level: level)
        case .paragraph(let line):
            inline(line)
        }
    }

    private func row(_ marker: String, _ text: String, level: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
            inline(text)
        }
        .padding(.leading, CGFloat(level) * 18)
    }

    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
}
