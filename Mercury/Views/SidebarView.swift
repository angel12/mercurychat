import MercuryKit
import SwiftUI

/// Sidebar: profile picker → projects (from projects.tree, or the flat-list
/// fallback) → sessions, plus recents and a new-session button.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.route) {
            if !model.profiles.isEmpty || model.profilesLoading {
                profileSection
            }

            if let tree = model.projectTree {
                ForEach(tree.projects) { project in
                    projectSection(project, scoped: tree.scopedSessionIDs)
                }
            }

            recentsSection

            if let error = model.browseError {
                Section {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.browseLoading && model.recentSessions.isEmpty {
                ProgressView("Loading sessions…")
            }
        }
        .refreshable { await model.refreshProjects() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.requestNewSession()
                } label: {
                    Label("New Session", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n")
            }
            ToolbarItem(placement: .cancellationAction) {
                Menu {
                    Button("Disconnect", role: .destructive) { model.disconnect() }
                } label: {
                    Label("Server", systemImage: "server.rack")
                }
            }
        }
    }

    private var profileSection: some View {
        Section("Profile") {
            if model.profilesLoading && model.profiles.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading profiles…").foregroundStyle(.secondary)
                }
            } else {
                Picker(
                    "Profile",
                    selection: Binding(
                        get: { model.selectedProfile ?? "" },
                        set: { name in Task { await model.selectProfile(name) } })
                ) {
                    ForEach(model.profiles) { profile in
                        Text(profile.name).tag(profile.name)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private func projectSection(_ project: ProjectInfo, scoped: Set<String>) -> some View {
        Section(project.isHomeBucket ? "Home" : project.name) {
            ForEach(project.previewSessions) { session in
                sessionRow(session)
            }
            if project.previewSessions.isEmpty, let count = project.sessionCount, count > 0 {
                Text("\(count) sessions")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        let scoped = model.projectTree?.scopedSessionIDs ?? []
        let rows = model.recentSessions.filter { !scoped.contains($0.storedID) }
        // When every session is already shown inside a project group, skip
        // the section instead of showing a misleading empty state.
        if !rows.isEmpty {
            Section("Recent") {
                ForEach(rows) { session in
                    sessionRow(session)
                }
            }
        } else if model.recentSessions.isEmpty && !model.browseLoading {
            Section("Recent") {
                Text("No sessions yet")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        NavigationLink(value: AppModel.Route.session(session)) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if session.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(session.title?.isEmpty == false ? session.title! : "Untitled")
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let updated = session.updatedAt {
                        Text(updated, format: .relative(presentation: .named))
                    }
                    if let count = session.messageCount {
                        Text("· \(count) messages")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}
