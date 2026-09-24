import ChatCore
import ImageIO
import MercuryKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Routines

/// A bot's recurring routines: the cron jobs in its profile's store
/// (`[bot:<name>] …` namespace stripped for display). List / pause / resume /
/// delete — creation still happens agent-side ("set up a morning digest") or
/// on the desktop; the gateway exposes no run-now action.
struct RoutinesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profile: String
    let title: String

    @State private var jobs: [CronJob] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var deleteTarget: CronJob?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
                ForEach(jobs) { job in
                    jobRow(job)
                }
                if jobs.isEmpty && !loading && errorMessage == nil {
                    ContentUnavailableView(
                        "No routines",
                        systemImage: "clock.badge.questionmark",
                        description: Text(
                            "Ask \(title) to set one up — “every morning, summarize my inbox”."
                        ))
                }
            }
            .overlay { if loading && jobs.isEmpty { ProgressView() } }
            .navigationTitle("\(title)'s Routines")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // cron.changed fires on every store mutation (including our own
            // toggles) and on job fires — refetch keeps next-run/status live.
            .task(id: model.cronEpoch) { await load() }
            .refreshable { await load() }
            .confirmationDialog(
                "Delete “\(deleteTarget?.displayName ?? "this routine")”? It stops running permanently.",
                isPresented: deleteDialogShown,
                titleVisibility: .visible
            ) {
                Button("Delete Routine", role: .destructive) {
                    if let target = deleteTarget {
                        Task { await remove(target) }
                    }
                    deleteTarget = nil
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            }
        }
    }

    private func jobRow(_ job: CronJob) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(job.displayName).lineLimit(1)
                Spacer()
                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { job.enabled },
                        set: { enabled in Task { await setEnabled(job, enabled) } })
                )
                .labelsHidden()
            }
            if let schedule = job.schedule, !schedule.isEmpty {
                Text(schedule)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if let next = job.nextRunAt, job.enabled {
                    Text("next \(next, format: .relative(presentation: .named))")
                } else if !job.enabled {
                    Text("paused")
                }
                if let status = job.lastStatus, !status.isEmpty {
                    Text("· last: \(status)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let error = job.lastFireError, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleteTarget = job
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func load() async {
        guard let connection = model.connection else { return }
        loading = true
        defer { loading = false }
        do {
            let list = try await connection.listCronJobs(profile: profile)
            // An unscoped answer (older gateway) contains every profile's
            // jobs — fall back to the namespace filter.
            jobs = list.scopedToProfile
                ? list.jobs : list.jobs.filter { $0.belongsToBot(named: profile) }
            errorMessage = nil
        } catch {
            errorMessage = (error as? HermesError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func setEnabled(_ job: CronJob, _ enabled: Bool) async {
        guard let connection = model.connection else { return }
        do {
            try await connection.setCronJobEnabled(
                jobID: job.jobID, enabled: enabled, profile: profile)
            await load()
        } catch {
            errorMessage = (error as? HermesError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func remove(_ job: CronJob) async {
        guard let connection = model.connection else { return }
        do {
            try await connection.removeCronJob(jobID: job.jobID, profile: profile)
            await load()
        } catch {
            errorMessage = (error as? HermesError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private var deleteDialogShown: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } })
    }
}

// MARK: - New bot

/// The New Bot quick path (#27 Phase 3): Name, and optionally Title and
/// Description. The bot is created the way hermes desktop creates one
/// (`AppModel.createBot`), then its Bot Chat opens and it introduces itself.
struct NewBotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var title = ""
    @State private var descriptionText = ""
    @State private var cloneFrom: String? = "default"
    @State private var creating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                    TextField("Title (optional)", text: $title)
                    TextField("Description (optional)", text: $descriptionText, axis: .vertical)
                        .lineLimit(1...3)
                } footer: {
                    Text(idHint)
                }
                Section {
                    Picker("Clone from", selection: $cloneFrom) {
                        Text("Fresh profile").tag(String?.none)
                        ForEach(cloneSourceNames, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Bot")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(creating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(creating || slug.isEmpty)
                }
            }
            .interactiveDismissDisabled(creating)
        }
        #if os(macOS)
            .frame(minWidth: 400, minHeight: 320)
        #endif
    }

    private var slug: String { BotCreation.identity(name: name, title: title).slug }

    /// "default" first, then the other roster names in order, without
    /// duplicates. "default" is offered even when the roster doesn't list it.
    private var cloneSourceNames: [String] {
        var names = ["default"]
        for bot in model.bots where !names.contains(bot.name) {
            names.append(bot.name)
        }
        return names
    }

    /// Shows the profile id the name becomes, so a surprising slug (an
    /// accented or non-Latin name) is visible before anything is created.
    private var idHint: String {
        guard name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return slug.isEmpty
                ? "Use letters or numbers in the name: it becomes the bot's profile id."
                : "Profile id: \(slug)"
        }
        if let cloneFrom {
            return "The name becomes the bot's profile id. It clones \(cloneFrom)'s settings and shares your default profile's sign-ins."
        }
        return "The name becomes the bot's profile id. It starts from a fresh profile and shares your default profile's sign-ins."
    }

    private func create() async {
        creating = true
        errorMessage = nil
        let failure = await model.createBot(
            name: name, title: title, description: descriptionText, cloneFrom: cloneFrom)
        creating = false
        if let failure {
            errorMessage = failure
        } else {
            dismiss()
        }
    }
}

// MARK: - Edit bot

/// Edit a bot's look: display title, description, hidden flag, and avatar.
/// Everything lands in backend-synced state (`ui_meta['hermes-bots']` via
/// read-modify-write + CAS, avatar via `profiles.set_asset`), so the change
/// appears on every desktop connected to this gateway.
struct EditBotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bot: BotSummary

    @State private var title: String
    @State private var descriptionText: String
    @State private var hidden: Bool
    @State private var pickedAvatar: PhotosPickerItem?
    /// The avatar change, with each picker load owned by its pick (#107).
    @State private var avatar = AvatarSelection()
    @State private var saving = false
    @State private var errorMessage: String?

    init(bot: BotSummary) {
        self.bot = bot
        _title = State(initialValue: bot.metaTitle ?? "")
        _descriptionText = State(initialValue: bot.metaDescription ?? "")
        _hidden = State(initialValue: bot.hidden)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField(bot.name, text: $title)
                    TextField("Description", text: $descriptionText, axis: .vertical)
                        .lineLimit(1...3)
                }
                Section {
                    Toggle("Hidden from roster", isOn: $hidden)
                } footer: {
                    Text(
                        "Display-only: @mentions still resolve and routines keep running. Synced to every device."
                    )
                }
                Section("Avatar") {
                    HStack(spacing: 12) {
                        BotAvatarView(bot: bot, imageData: previewAvatarData)
                            .frame(width: 44, height: 44)
                        PhotosPicker(
                            "Choose Photo…", selection: $pickedAvatar, matching: .images)
                        if !avatar.canSave {
                            ProgressView().controlSize(.small)
                        }
                        if previewAvatarData != nil {
                            Button("Remove", role: .destructive) {
                                // Retires any load still running for the pick.
                                avatar.remove()
                                pickedAvatar = nil
                            }
                        }
                    }
                }
                Section {
                    NavigationLink("Advanced") { BotAdvancedView(bot: bot) }
                } footer: {
                    Text("Soul, model, skills, toolsets and MCP servers.")
                }
                if let message = errorMessage
                    ?? (avatar.loadFailed ? "Couldn't read that image." : nil)
                {
                    Section {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit \(bot.title)")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        // Saving mid-load would drop the chosen photo (#107).
                        .disabled(saving || !avatar.canSave)
                }
            }
            // Keyed on the selection so SwiftUI cancels the previous load when
            // the pick changes or is removed; the token drops a load that
            // finishes anyway after a newer pick or Remove (#107).
            .task(id: pickedAvatar) {
                guard let item = pickedAvatar else {
                    avatar.cancelPending()
                    return
                }
                let token = avatar.pick()
                let data = try? await item.loadTransferable(type: Data.self)
                guard !Task.isCancelled else { return }
                avatar.loadFinished(token, jpeg: data.flatMap(BotAvatarEncoder.avatarJPEG(from:)))
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private var previewAvatarData: Data? {
        switch avatar.change {
        case .some(let replacement): return replacement
        case nil: return model.botAvatars[bot.name]
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if case .some(let jpeg) = avatar.change {
            if let failure = await model.saveBotAvatar(bot, jpegData: jpeg) {
                errorMessage = failure
                return
            }
        }
        if let failure = await model.saveBotLook(
            bot,
            title: title.trimmingCharacters(in: .whitespaces),
            description: descriptionText.trimmingCharacters(in: .whitespaces),
            hidden: hidden)
        {
            errorMessage = failure
            return
        }
        dismiss()
    }
}

/// Downscale a picked image into the avatar wire format: ≤512px JPEG, far
/// under the gateway's 2MB `set_asset` cap.
enum BotAvatarEncoder {
    static let maxPixelSize = 512

    static func avatarJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard
            let scaled = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary)
        else { return nil }
        let encoded = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                encoded, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, scaled,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }
}
