import LegatoMeetings
import SwiftUI

/// Title, client, project and tags of one meeting, editable while it records and afterwards. Client, project and tags
/// suggest the values the other meetings already use; a change is saved when a field is left or submitted.
struct MeetingMetadataEditor: View {
    let meeting: Meeting
    /// Every meeting, for the suggestions.
    let known: [Meeting]
    let save: (MeetingMetadata) -> Void

    @State private var title = ""
    @State private var client = ""
    @State private var project = ""
    @State private var tags: [String] = []
    @State private var newTag = ""
    @FocusState private var focus: Field?
    fileprivate enum Field { case title, client, project, tag }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.largeTitle.weight(.bold))
                .focused($focus, equals: .title)
                .onSubmit(commit)
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                SuggestingField(label: "Client", symbol: "building.2", text: $client, suggestions: clients,
                                focus: $focus, field: .client, commit: commit)
                SuggestingField(label: "Project", symbol: "folder", text: $project, suggestions: projects,
                                focus: $focus, field: .project, commit: commit)
            }
            tagRow
        }
        .onChange(of: focus) { old, _ in if old != nil { commit() } }
        .onChange(of: meeting, initial: true) { _, _ in if focus == nil { load() } }
    }

    private var tagRow: some View {
        FlowLayout(spacing: 6) {
            Image(systemName: "number").foregroundStyle(.secondary)
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text(tag)
                    Button { tags.removeAll { $0 == tag }; commit() } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove tag \(tag)")
                }
                .font(.callout)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.tint.opacity(0.15), in: Capsule())
            }
            TextField("Add tag", text: $newTag)
                .textFieldStyle(.plain)
                .frame(width: 90)
                .focused($focus, equals: .tag)
                .onSubmit { addTag(); focus = .tag }
                .textInputSuggestions {
                    ForEach(tagSuggestions, id: \.self) { Text($0).textInputCompletion($0) }
                }
        }
    }

    private func addTag() {
        addTagWithoutCommit()
        commit()
    }

    private func load() {
        title = meeting.title
        client = meeting.client ?? ""
        project = meeting.project ?? ""
        tags = meeting.tags
    }

    private func commit() {
        if !newTag.trimmingCharacters(in: .whitespaces).isEmpty { addTagWithoutCommit() }
        let metadata = MeetingMetadata(title: title, client: client, project: project, tags: tags)
            .normalized(fallbackTitle: meeting.title)
        guard metadata != meeting.metadata else { return }
        save(metadata)
    }

    private func addTagWithoutCommit() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        newTag = ""
        if !tag.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { tags.append(tag) }
    }

    private var clients: [String] { distinct(known.compactMap(\.client)) }
    private var projects: [String] {
        let trimmed = client.trimmingCharacters(in: .whitespaces)
        let pool = trimmed.isEmpty ? known : known.filter { $0.client?.caseInsensitiveCompare(trimmed) == .orderedSame }
        return distinct(pool.compactMap(\.project))
    }
    private var tagSuggestions: [String] {
        let typed = newTag.trimmingCharacters(in: .whitespaces)
        return distinct(known.flatMap(\.tags)).filter { tag in
            !tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
                && (typed.isEmpty || tag.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
    }

    private func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// A one-line field with an icon, typed suggestions and a menu of the values in use.
private struct SuggestingField: View {
    let label: String
    let symbol: String
    @Binding var text: String
    let suggestions: [String]
    var focus: FocusState<MeetingMetadataEditor.Field?>.Binding
    let field: MeetingMetadataEditor.Field
    let commit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            TextField(label, text: $text)
                .textFieldStyle(.plain)
                .frame(minWidth: 110, maxWidth: 200)
                .focused(focus, equals: field)
                .onSubmit(commit)
                .textInputSuggestions {
                    ForEach(matching, id: \.self) { Text($0).textInputCompletion($0) }
                }
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { value in Button(value) { text = value; commit() } }
                } label: { Image(systemName: "chevron.down").font(.caption2) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("\(label) in use")
            }
        }
    }

    private var matching: [String] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        return suggestions.filter { typed.isEmpty || $0.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// Lays its views out left to right and wraps them into rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placement = arrange(in: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, placement.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(in width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }
}
