import MercuryKit
import SwiftUI

/// Sidebar: profile picker → projects (from projects.tree, or the flat-list
/// fallback) → sessions, plus recents and a new-session button.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renameTarget: SessionSummary?
    @State private var renameText = ""
    @State private var deleteTarget: SessionSummary?
    @State private var botSearch = ""
    @State private var showHiddenBots = false

    var body: some View {
        @Bindable var model = model
        List(selection: $model.route) {
            if model.botModeSupported == true {
                tabSection
            }

            if model.sidebarTab == .bots {
                botsSections
            } else {
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
        }
        .listStyle(.sidebar)
        .overlay {
            if model.sidebarTab == .bots {
                if model.botsLoading && model.bots.isEmpty {
                    ProgressView("Loading bots…")
                }
            } else if model.browseLoading && model.recentSessions.isEmpty {
                ProgressView("Loading sessions…")
            }
        }
        .task(id: model.sidebarTab) {
            if model.sidebarTab == .bots { await model.loadBots() }
        }
        .refreshable {
            if model.sidebarTab == .bots {
                await model.loadBots(force: true)
            } else {
                await model.refreshProjects()
            }
        }
        .alert("Rename Session", isPresented: renameAlertShown) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let target = renameTarget {
                    Task { await model.renameSession(target, to: renameText) }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            "Delete \"\(deleteTarget?.title ?? "this session")\"? This removes its transcript from the server.",
            isPresented: deleteDialogShown,
            titleVisibility: .visible
        ) {
            Button("Delete Session", role: .destructive) {
                if let target = deleteTarget {
                    Task { await model.deleteSession(target) }
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        }
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

    private var tabSection: some View {
        @Bindable var model = model
        return Section {
            Picker("Sidebar", selection: $model.sidebarTab) {
                Text("Sessions").tag(AppModel.SidebarTab.sessions)
                Text("Bots").tag(AppModel.SidebarTab.bots)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: Bots roster

    @ViewBuilder
    private var botsSections: some View {
        Section {
            TextField("Search bots", text: $botSearch)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
        }

        let rows = visibleBots
        Section {
            ForEach(rows) { bot in
                BotRow(bot: bot)
            }
            if rows.isEmpty && !model.botsLoading {
                Text(botSearch.isEmpty ? "No bots yet" : "No bots match")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        } footer: {
            let hiddenCount = model.bots.filter(\.hidden).count
            if hiddenCount > 0 {
                Button {
                    showHiddenBots.toggle()
                } label: {
                    Label(
                        showHiddenBots
                            ? "Hide hidden bots"
                            : "Show \(hiddenCount) hidden bot\(hiddenCount == 1 ? "" : "s")",
                        systemImage: showHiddenBots ? "eye.slash" : "eye")
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }

        if let error = model.botsError {
            Section {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// Roster order matches the desktop: pinned first, then newest activity,
    /// then name. Hidden bots are display-only hidden — the eye toggle
    /// reveals them dimmed-in-place semantics are Phase 2; here they simply
    /// join the list.
    private var visibleBots: [BotSummary] {
        let query = botSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return model.bots
            .filter { showHiddenBots || !$0.hidden }
            .filter {
                query.isEmpty || $0.title.lowercased().contains(query)
                    || $0.name.lowercased().contains(query)
            }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                let dateA = a.lastActivity ?? .distantPast
                let dateB = b.lastActivity ?? .distantPast
                if dateA != dateB { return dateA > dateB }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
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
        Section {
            ForEach(project.previewSessions) { session in
                sessionRow(session)
            }
            if project.previewSessions.isEmpty, let count = project.sessionCount, count > 0 {
                Text("\(count) sessions")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        } header: {
            HStack {
                Text(project.isHomeBucket ? "Home" : project.name)
                Spacer()
                if project.primaryPath != nil || project.isHomeBucket {
                    Button {
                        model.requestNewSession(cwd: project.primaryPath)
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(
                        project.isHomeBucket
                            ? "New session (no workspace)"
                            : "New session in \(project.name)")
                }
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
        .contextMenu {
            // Canonical Bot Chats resolve by their exact title — renaming one
            // severs its bot's forever-chat (AppModel.renameSession refuses
            // too; hiding the item explains less but confuses least).
            if session.title != BotChatPolicy.canonicalTitle {
                Button {
                    renameText = session.title ?? ""
                    renameTarget = session
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
            }
            Button {
                Task { await model.togglePin(session) }
            } label: {
                Label(
                    session.pinned ? "Unpin" : "Pin",
                    systemImage: session.pinned ? "pin.slash" : "pin")
            }
            Divider()
            Button(role: .destructive) {
                deleteTarget = session
            } label: {
                Label("Delete…", systemImage: "trash")
            }
        }
    }

    private var renameAlertShown: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })
    }

    private var deleteDialogShown: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } })
    }
}
