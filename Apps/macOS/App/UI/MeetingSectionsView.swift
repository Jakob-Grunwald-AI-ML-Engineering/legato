import LegatoAppServices
import LegatoMeetings
import SwiftUI

/// Settings > Meetings > Summary sections: the built-ins (read only), your own (add, edit, delete), their order in
/// the summary, and which are ticked for new meetings. It is a Section, to sit inside the settings form.
struct MeetingSectionsView: View {
    let settings: MeetingSettings

    private struct Draft: Identifiable {
        var id: String?
        var heading: String
        var instruction: String
        var readOnly: Bool
        var key: String { id ?? "new" }
    }

    @State private var all: [SummarySection] = []
    @State private var ticked: Set<SectionID> = []
    @State private var draft: Draft?

    var body: some View {
        Section {
            ForEach(Array(all.enumerated()), id: \.element.id) { index, section in row(section, at: index) }
            Button { draft = Draft(id: nil, heading: "", instruction: "", readOnly: false) } label: {
                Label("Add section", systemImage: "plus")
            }
        } header: {
            Text("Summary sections")
        } footer: {
            Text("A summary holds the ticked sections, each under its heading, in this order. New meetings tick the ones checked here; each meeting can tick others above its summary. The built-in ones can be read, not changed.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
        .sheet(item: $draft) { draft in
            SectionEditor(
                draft: draft, onSave: { heading, instruction in save(draft, heading: heading, instruction: instruction) },
                onCancel: { self.draft = nil })
        }
    }

    private func row(_ section: SummarySection, at index: Int) -> some View {
        HStack {
            Toggle(isOn: Binding(get: { ticked.contains(section.id) }, set: { setDefault(section.id, $0) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Ticked for new meetings")
            VStack(alignment: .leading, spacing: 2) {
                Text(section.heading)
                if section.isBuiltIn { Text("Built in").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(index == 0).help("Move up")
            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(index == all.count - 1).help("Move down")
            if section.isBuiltIn {
                Button("View") { draft = Draft(id: section.id, heading: section.heading, instruction: section.instruction, readOnly: true) }
                    .buttonStyle(.borderless)
            } else {
                Button("Edit") { draft = Draft(id: section.id, heading: section.heading, instruction: section.instruction, readOnly: false) }
                    .buttonStyle(.borderless)
                Button(role: .destructive) { settings.deleteSection(id: section.id); reload() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete")
            }
        }
    }

    private func setDefault(_ id: SectionID, _ on: Bool) {
        var ids = Set(settings.defaultSectionIDs)
        if on { ids.insert(id) } else { ids.remove(id) }
        settings.defaultSectionIDs = Array(ids)
        reload()
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard all.indices.contains(target) else { return }
        settings.moveSections(fromOffsets: IndexSet(integer: index), toOffset: offset > 0 ? target + 1 : target)
        reload()
    }

    private func reload() {
        all = settings.allSections
        ticked = Set(settings.defaultSectionIDs)
    }

    private func save(_ draft: Draft, heading: String, instruction: String) {
        if let id = draft.id {
            settings.updateSection(SummarySection(id: id, heading: heading, instruction: instruction))
        } else {
            settings.addSection(heading: heading, instruction: instruction)
        }
        self.draft = nil
        reload()
    }

    private struct SectionEditor: View {
        let draft: Draft
        let onSave: (String, String) -> Void
        let onCancel: () -> Void
        @State private var heading = ""
        @State private var instruction = ""

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(draft.readOnly ? "Section" : draft.id == nil ? "New section" : "Edit section").font(.headline)
                TextField("Heading", text: $heading).disabled(draft.readOnly)
                TextEditor(text: $instruction)
                    .font(.body.monospaced())
                    .frame(minHeight: 160)
                    .disabled(draft.readOnly)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                Text("What to write under the heading. The language, the speakers' names and your meeting notes are added automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(draft.readOnly ? "Close" : "Cancel", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    if !draft.readOnly {
                        Button("Save") { onSave(heading.trimmingCharacters(in: .whitespacesAndNewlines), instruction) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(
                                heading.trimmingCharacters(in: .whitespaces).isEmpty
                                    || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(20)
            .frame(width: 480)
            .onAppear {
                heading = draft.heading
                instruction = draft.instruction
            }
        }
    }
}
