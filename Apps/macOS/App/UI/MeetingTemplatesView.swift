import LegatoAppServices
import LegatoMeetings
import SwiftUI

/// Settings > Meetings > Summary templates: the built-ins (read only), your own (add, edit, delete) and which
/// one new meetings use. It is a Section, to sit inside the settings form.
struct MeetingTemplatesView: View {
    let settings: MeetingSettings

    private struct Draft: Identifiable {
        var id: String?
        var name: String
        var prompt: String
        var readOnly: Bool
        var key: String { id ?? "new" }
    }

    @State private var custom: [SummaryTemplate] = []
    @State private var defaultID = SummaryTemplate.summaryID
    @State private var draft: Draft?

    var body: some View {
        Section {
            ForEach(SummaryTemplate.builtIns + custom) { template in row(template) }
            Button { draft = Draft(id: nil, name: "", prompt: "", readOnly: false) } label: {
                Label("Add template", systemImage: "plus")
            }
        } header: {
            Text("Summary templates")
        } footer: {
            Text("A template is the instruction the summary follows. New meetings use the default; each meeting can pick another in its toolbar. The built-in ones can be read, not changed.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
        .sheet(item: $draft) { draft in
            TemplateEditor(draft: draft, onSave: { name, prompt in save(draft, name: name, prompt: prompt) }, onCancel: { self.draft = nil })
        }
    }

    private func row(_ template: SummaryTemplate) -> some View {
        HStack {
            Button { settings.defaultTemplateID = template.id; reload() } label: {
                Image(systemName: defaultID == template.id ? "largecircle.fill.circle" : "circle")
            }
            .buttonStyle(.borderless)
            .help("Use for new meetings")
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                if template.isBuiltIn { Text("Built in").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if template.isBuiltIn {
                Button("View") { draft = Draft(id: template.id, name: template.name, prompt: template.prompt, readOnly: true) }
                    .buttonStyle(.borderless)
            } else {
                Button("Edit") { draft = Draft(id: template.id, name: template.name, prompt: template.prompt, readOnly: false) }
                    .buttonStyle(.borderless)
                Button(role: .destructive) { settings.deleteTemplate(id: template.id); reload() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func reload() {
        custom = settings.customTemplates
        defaultID = settings.defaultTemplateID
    }

    private func save(_ draft: Draft, name: String, prompt: String) {
        if let id = draft.id {
            settings.updateTemplate(SummaryTemplate(id: id, name: name, prompt: prompt))
        } else {
            settings.addTemplate(name: name, prompt: prompt)
        }
        self.draft = nil
        reload()
    }

    private struct TemplateEditor: View {
        let draft: Draft
        let onSave: (String, String) -> Void
        let onCancel: () -> Void
        @State private var name = ""
        @State private var prompt = ""

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(draft.readOnly ? "Template" : draft.id == nil ? "New template" : "Edit template").font(.headline)
                TextField("Name", text: $name).disabled(draft.readOnly)
                TextEditor(text: $prompt)
                    .font(.body.monospaced())
                    .frame(minHeight: 220)
                    .disabled(draft.readOnly)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                Text("The language and your meeting notes are added automatically.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(draft.readOnly ? "Close" : "Cancel", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    if !draft.readOnly {
                        Button("Save") { onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), prompt) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(20)
            .frame(width: 480)
            .onAppear {
                name = draft.name
                prompt = draft.prompt
            }
        }
    }
}
