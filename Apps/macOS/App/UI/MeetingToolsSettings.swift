import AppKit
import SwiftUI

/// The `legato` command line that ships inside the app, put where a shell and an agent can find it.
enum MeetingTools {
    enum Status: Equatable {
        /// This build carries no helper (a build made without it).
        case helperMissing
        case notLinked
        case linked
        /// A link by that name points somewhere else (an older copy of the app, or another tool).
        case linkedElsewhere(String)
        /// A real file is in the way; it is never replaced.
        case blocked
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    /// `Legato.app/Contents/Helpers/legato`.
    static var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/legato") }
    /// `~/.local/bin/legato`.
    static var link: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/legato") }

    static func status(helper: URL = helper, link: URL = link) -> Status {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: helper.path) else { return .helperMissing }
        if let target = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            let resolved = URL(fileURLWithPath: target, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
            return resolved.path == helper.standardizedFileURL.path ? .linked : .linkedElsewhere(resolved.path)
        }
        return (try? fm.attributesOfItem(atPath: link.path)) == nil ? .notLinked : .blocked
    }

    /// Links `link` to the helper, creating `~/.local/bin` first. A link that points elsewhere is replaced; a real file is not.
    static func install(helper: URL = helper, link: URL = link) throws {
        let fm = FileManager.default
        switch status(helper: helper, link: link) {
        case .helperMissing: throw Failure(errorDescription: "This build of Legato has no command line tool inside it.")
        case .blocked: throw Failure(errorDescription: "\(link.path) is already a file. Move it away and try again.")
        case .linked: return
        case .linkedElsewhere: try fm.removeItem(at: link)
        case .notLinked: break
        }
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: helper)
    }

    /// The `mcpServers` entry that starts the server from the helper's own path, which keeps working without the link.
    static func mcpConfig(helper: URL = helper) -> String {
        let escaped = helper.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
            {
              "mcpServers": {
                "legato": {
                  "command": "\(escaped)",
                  "args": ["mcp"]
                }
              }
            }
            """
    }
}

/// Settings section: agents and scripts reach your meetings through `legato`.
struct MeetingToolsSettings: View {
    @State private var status = MeetingTools.status()
    @State private var failure: String?
    @State private var copied = false

    var body: some View {
        SettingsCard { content }
            .onAppear { status = MeetingTools.status() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Agents and scripts", systemImage: "terminal").font(.headline)
            Text("The legato command line searches and reads your meetings, read-only: summaries, notes and transcripts stay on this Mac. Link it to use it in Terminal; give the MCP configuration to an agent that supports it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: status == .linked ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(status == .linked ? Color.green : Color.secondary)
                    .accessibilityLabel(status == .linked ? "Linked" : "Not linked")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command line tool").font(.body.weight(.medium))
                    Text(statusText).font(.caption).foregroundStyle(failure == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(status == .linked ? "Linked" : "Link to ~/.local/bin") { link() }
                    .controlSize(.small).disabled(status == .linked || status == .helperMissing || status == .blocked)
            }
            Divider()
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MCP server").font(.body.weight(.medium))
                    Text("Copies the configuration with this app’s own path to legato.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(copied ? "Copied" : "Copy MCP configuration") { copyConfig() }
                    .controlSize(.small).disabled(status == .helperMissing)
            }
        }
    }

    private var statusText: String {
        if let failure { return failure }
        switch status {
        case .helperMissing: return "This build has no command line tool."
        case .notLinked: return "Not linked. Links ~/.local/bin/legato to the copy inside Legato; add ~/.local/bin to your PATH if the shell does not find it."
        case .linked: return "Linked at ~/.local/bin/legato."
        case .linkedElsewhere(let path): return "~/.local/bin/legato points to \(path). Linking replaces it."
        case .blocked: return "~/.local/bin/legato is a file, not a link; Legato leaves it alone."
        }
    }

    private func link() {
        do {
            try MeetingTools.install()
            failure = nil
        } catch {
            failure = "Could not link: \(error.localizedDescription)"
        }
        status = MeetingTools.status()
    }

    private func copyConfig() {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(MeetingTools.mcpConfig(), forType: .string)
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
