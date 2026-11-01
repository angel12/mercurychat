import ChatCore
import MercuryKit
import SwiftUI

/// Sidebar, laid out like Mercury Voice's browser in three pages:
///  1. profile picker (or the Bots roster, on the Bots tab)
///  2. recent sessions for the selected profile, plus "new session" and
///     "choose a workspace" actions
///  3. workspaces (projects.tree, or the flat-list fallback), each listing
///     its sessions
/// The pages push inside the sidebar column's own stack; a session row
/// selects the window's route, which the split view shows as the detail.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowNavigation.self) private var navigation
    @State private var path: [Page] = []
    @State private var renameTarget: SessionSummary?
    @State private var renameText = ""
    @State private var deleteTarget: SessionSummary?
    @State private var botSearch = ""
    @State private var showHiddenBots = false
    @State private var newBotShown = false
    @State private var notificationsShown = false

    enum Page: Hashable {
        case sessions
        case workspaces
    }

    var body: some View {
        NavigationStack(path: $path) {
            rootPage
                .navigationDestination(for: Page.self) { page in
                    switch page {
                    case .sessions: sessionsPage
                    case .workspaces: workspacesPage
                    }
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
        #if os(iOS)
            .sheet(isPresented: $notificationsShown) { NotificationSettingsView() }
        #endif
    }

    // MARK: Page 1 — profiles (or bots)

    private var rootPage: some View {
        @Bindable var navigation = navigation
        return List(selection: $navigation.route) {
            if model.botModeSupported == true {
                tabSection
            }

            if model.sidebarTab == .bots {
                botsSections
            } else {
                profilesSection
                errorSection
            }
        }
        .overlay {
            if model.sidebarTab == .bots && model.botsLoading && model.bots.isEmpty {
                ProgressView("Loading bots…")
            }
        }
        .navigationTitle(model.endpoint?.displayName ?? "Mercury Chat")
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
        .toolbar {
            newSessionToolbarItem
            #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        notificationsShown = true
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                }
            #endif
            ToolbarItem(placement: .cancellationAction) {
                Menu {
                    Link("Privacy Policy", destination: MercuryLinks.privacyPolicy)
                    Divider()
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

    @ViewBuilder
    private var profilesSection: some View {
        Section("Profile") {
            if model.profilesLoading && model.profiles.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading profiles (this can take a while)…")
                        .foregroundStyle(.secondary)
                }
            } else if model.profiles.isEmpty {
                // No profile list (older backend, or the read failed): the
                // sessions page still works, unscoped.
                pageButton(.sessions) {
                    Label("All sessions", systemImage: "bubble.left.and.bubble.right")
                }
            }
            ForEach(model.profiles) { profile in
                Button {
                    path.append(.sessions)
                    Task { await model.selectProfile(profile.name) }
                } label: {
                    profileRow(profile)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func profileRow(_ profile: ProfileInfo) -> some View {
        HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(profile.displayName).font(.body.weight(.medium))
                    if profile.isDefault {
                        Text("default")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                let subtitle = profileSubtitle(profile)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.selectedProfile == profile.name {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        // Whole row is the hit target, not just the text.
        .contentShape(Rectangle())
    }

    private func profileSubtitle(_ profile: ProfileInfo) -> String {
        var parts: [String] = []
        if let model = profile.model { parts.append(model) }
        if let provider = profile.provider { parts.append(provider) }
        if let skills = profile.skillCount { parts.append("\(skills) skills") }
        return parts.joined(separator: " · ")
    }

    // MARK: Page 1 (Bots tab) — roster

    @ViewBuilder
    private var botsSections: some View {
        Section {
            TextField("Search bots", text: $botSearch)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Button {
                newBotShown = true
            } label: {
                Label("New Bot", systemImage: "plus")
            }
        }
        .sheet(isPresented: $newBotShown) { NewBotSheet() }

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

    // MARK: Page 2 — sessions for the selected profile

    private var sessionsPage: some View {
        @Bindable var navigation = navigation
        return List(selection: $navigation.route) {
            Section {
                Button {
                    model.requestNewSession(in: navigation)
                } label: {
                    Label("New session", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                pageButton(.workspaces) {
                    Label("Choose a workspace", systemImage: "folder")
                }
            }
            errorSection
            Section("Recent sessions") {
                if model.browseLoading && model.recentSessions.isEmpty {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading sessions…").foregroundStyle(.secondary)
                    }
                } else if model.recentSessions.isEmpty {
                    Text("No sessions yet for this profile.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.recentSessions) { session in
                    sessionRow(session)
                }
            }
        }
        .navigationTitle(model.profileDisplayName(model.selectedProfile) ?? "Sessions")
        .refreshable { await model.refreshProjects() }
        .toolbar { newSessionToolbarItem }
    }

    // MARK: Page 3 — workspaces

    private var workspacesPage: some View {
        @Bindable var navigation = navigation
        return List(selection: $navigation.route) {
            errorSection
            if model.browseLoading && model.projectTree == nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading workspaces…").foregroundStyle(.secondary)
                }
            } else if (model.projectTree?.projects ?? []).isEmpty {
                Text("No workspaces yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.projectTree?.projects ?? []) { project in
                workspaceSection(project)
            }
        }
        .navigationTitle("Workspaces")
        .refreshable { await model.refreshProjects() }
        .toolbar { newSessionToolbarItem }
    }

    /// The Home bucket stays as its own group — it holds the sessions that
    /// belong to no workspace, which the recents page may have aged out.
    private func workspaceSection(_ project: ProjectInfo) -> some View {
        Section(project.isHomeBucket ? "Home" : project.name) {
            if let path = project.primaryPath {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if project.primaryPath != nil || project.isHomeBucket {
                Button {
                    model.requestNewSession(cwd: project.primaryPath, in: navigation)
                } label: {
                    Label(
                        project.isHomeBucket ? "New session (no workspace)" : "New session in workspace",
                        systemImage: "square.and.pencil"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
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

    // MARK: Shared pieces

    private var newSessionToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            // ⌘N lives on the menu command, which targets the focused
            // window (#112) — a shortcut here too would collide with it.
            Button {
                model.requestNewSession(in: navigation)
            } label: {
                Label("New Session", systemImage: "square.and.pencil")
            }
        }
    }

    /// A row that pushes `page`, drawn like a navigation link. A plain
    /// NavigationLink(value:) would compete with the list's route selection.
    private func pageButton<Content: View>(
        _ page: Page, @ViewBuilder label: () -> Content
    ) -> some View {
        Button {
            path.append(page)
        } label: {
            HStack {
                label()
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var errorSection: some View {
        if let error = model.browseError {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                Button("Retry") {
                    Task { await model.refreshProjects() }
                }
                .disabled(model.browseLoading)
            }
        }
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        NavigationLink(value: AppModel.Route.session(session)) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if session.pinned {
                        Image(systemName: "pin.fill").font(.caption2)
                    }
                    Text(session.title?.isEmpty == false ? session.title! : "Untitled session")
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let updated = session.updatedAt {
                        Text(updated, format: .relative(presentation: .named))
                    }
                    if let branch = session.gitBranch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                    }
                    if let count = session.messageCount {
                        Text("\(count) messages")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .contextMenu {
            // Canonical Bot Chats resolve by their exact title — renaming one
            // severs its bot's forever-chat (AppModel.renameSession refuses
            // too; hiding the item explains less but confuses least). The
            // gateway resurrects an archived one on the next lookup, so
            // Archive would quietly undo itself; hide that too.
            let canonical = BotChatPolicy.isCanonicalRow(rootTitle: nil, title: session.title)
            if !canonical {
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
            if !canonical {
                Button {
                    Task { await model.archiveSession(session) }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
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
