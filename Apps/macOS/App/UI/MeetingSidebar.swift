import LegatoMeetings
import SwiftUI

/// What the sidebar narrows the list to. Client and project are the folders today; this type and `MeetingSidebar`
/// are the only places that know it, so free-form folders would replace them and leave the window as it is.
enum MeetingSidebarItem: Hashable {
    case all
    /// `nil`: meetings without a client.
    case client(String?)
    case project(client: String?, project: String)
    case tag(String)

    func includes(_ meeting: Meeting) -> Bool {
        switch self {
        case .all: true
        case .client(let client): Self.same(client, meeting.client)
        case .project(let client, let project): Self.same(client, meeting.client) && Self.same(project, meeting.project)
        case .tag(let tag): meeting.tags.contains { Self.same(tag, $0) }
        }
    }

    private static func same(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case (let a?, let b?): a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        default: false
        }
    }
}

/// One row of the sidebar tree.
private struct SidebarNode: Identifiable {
    var item: MeetingSidebarItem
    var title: String
    var symbol: String
    var count: Int
    var children: [SidebarNode]?
    var id: MeetingSidebarItem { item }
}

/// The sidebar: All Meetings, the folders (Client, then Project inside it) and the tags.
struct MeetingSidebar: View {
    let meetings: [Meeting]
    @Binding var selection: MeetingSidebarItem

    var body: some View {
        List(selection: $selection) {
            row(SidebarNode(item: .all, title: "All Meetings", symbol: "tray.full", count: meetings.count))
            if !folders.isEmpty {
                Section("Clients") { OutlineGroup(folders, children: \.children) { row($0) } }
            }
            if !tags.isEmpty {
                Section("Tags") { ForEach(tags) { row($0) } }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ node: SidebarNode) -> some View {
        Label(node.title, systemImage: node.symbol)
            .badge(node.count)
            .tag(node.item)
    }

    private var folders: [SidebarNode] {
        MeetingListLogic.groupByClient(meetings).map { group in
            let projects = group.projects.compactMap { project -> SidebarNode? in
                guard let name = project.project else { return nil }
                return SidebarNode(item: .project(client: group.client, project: name), title: name, symbol: "folder",
                                   count: project.meetings.count)
            }
            return SidebarNode(item: .client(group.client), title: group.client ?? "No client",
                               symbol: group.client == nil ? "tray" : "building.2",
                               count: group.projects.reduce(0) { $0 + $1.meetings.count }, children: projects.isEmpty ? nil : projects)
        }
    }

    private var tags: [SidebarNode] {
        var counts: [String: (name: String, count: Int)] = [:]
        for tag in meetings.flatMap(\.tags) {
            let key = tag.lowercased()
            counts[key] = (counts[key]?.name ?? tag, (counts[key]?.count ?? 0) + 1)
        }
        return counts.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { SidebarNode(item: .tag($0.name), title: $0.name, symbol: "number", count: $0.count) }
    }
}
