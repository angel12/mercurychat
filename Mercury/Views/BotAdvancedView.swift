import ChatCore
import MercuryKit
import SwiftUI

/// The advanced bot editor: soul, model pin, skills, toolsets and MCP
/// servers. Pushed from `EditBotSheet`'s Form onto its `NavigationStack`, so
/// this view supplies no navigation chrome of its own beyond a title.
struct BotAdvancedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bot: BotSummary

    @State private var draft: BotProfileDraft?
    @State private var inventory: ModelInventory?
    @State private var loading = true
    @State private var loadError: String?
    @State private var saving = false
    @State private var saveError: String?
    @State private var confirmMessage: String?
    @State private var confirmShown = false

    /// The provider/model picker's working selection. Set from the loaded
    /// pin (or the inventory's current default when unpinned) so the
    /// pickers open pre-aligned with what's actually in effect; `draft.model`
    /// itself is only touched once the user picks both (unpinning isn't
    /// offered — see `BotProfileDraft.model`).
    @State private var selectedProviderSlug: String?
    @State private var selectedModelName: String?

    var body: some View {
        content
            .navigationTitle("Advanced")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(macOS)
                    // A sheet's pushed view has no system back button on
                    // macOS, and the only other toolbar button (Save) stays
                    // disabled until something changes — without this the
                    // screen would otherwise be a dead end.
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back") { dismiss() }
                    }
                #endif
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled((draft?.hasChanges != true) || saving || loading)
                }
            }
            .task { await load() }
            .alert(
                "Confirm Model", isPresented: $confirmShown, presenting: confirmMessage
            ) { _ in
                Button("Use This Model") { Task { await confirmModel() } }
                Button("Cancel", role: .cancel) { Task { await load() } }
            } message: { message in
                Text(message)
            }
    }

    @ViewBuilder
    private var content: some View {
        if loading && draft == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, draft == nil {
            VStack(spacing: 12) {
                Text(loadError).foregroundStyle(.secondary)
                Button("Retry") { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let draftBinding = Binding($draft) {
            Form {
                soulSection(draftBinding)
                modelSection(draftBinding)
                skillsSection(draftBinding)
                toolsetsSection(draftBinding)
                mcpSection(draftBinding)
                if saveError != nil || loading {
                    Section {
                        HStack {
                            if let saveError {
                                Text(saveError).font(.caption).foregroundStyle(.red)
                            }
                            Spacer()
                            if loading {
                                ProgressView().controlSize(.small)
                            }
                            Button("Reload") { Task { await load() } }
                                .disabled(loading)
                        }
                    }
                }
            }
        }
    }

    // MARK: Sections

    private func soulSection(_ draft: Binding<BotProfileDraft>) -> some View {
        Section("Soul") {
            TextEditor(text: draft.soul)
                .font(.body.monospaced())
                .frame(minHeight: 200)
                .autocorrectionDisabled()
                #if !os(macOS)
                    .textInputAutocapitalization(.never)
                #endif
        }
    }

    @ViewBuilder
    private func modelSection(_ draft: Binding<BotProfileDraft>) -> some View {
        Section("Model") {
            if let inventory {
                let providers = inventory.providers.filter { $0.authenticated != false }
                if let pin = draft.wrappedValue.model, !pinIsVisible(pin, in: providers) {
                    LabeledContent("Current", value: "\(pin.provider) / \(pin.model)")
                }
                Picker("Provider", selection: providerSelection(providers)) {
                    ForEach(providers) { provider in
                        Text(provider.name).tag(Optional(provider.slug))
                    }
                }
                if let provider = providers.first(where: { $0.slug == selectedProviderSlug }) {
                    if let warning = provider.warning, !warning.isEmpty {
                        Text(warning).font(.caption).foregroundStyle(.secondary)
                    }
                    let available = provider.models.filter {
                        !provider.unavailableModels.contains($0)
                    }
                    Picker("Model", selection: modelSelection(available)) {
                        ForEach(available, id: \.self) { modelName in
                            Text(modelName).tag(Optional(modelName))
                        }
                    }
                }
                if draft.wrappedValue.model == nil {
                    Text("Inherits the default model (\(inventory.currentModel)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let pin = draft.wrappedValue.model {
                LabeledContent("Model", value: "\(pin.provider) / \(pin.model)")
            } else {
                Text("Inherits the default model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Whether `pin` shows up as a selectable row in the pickers built from
    /// `providers` — false when its provider isn't in the (authenticated)
    /// list, or its model isn't among that provider's visible models (not
    /// listed, or in `unavailableModels`). A pin that fails this is shown as
    /// read-only text instead, since picking any row would silently change it.
    private func pinIsVisible(
        _ pin: ProfileDescription.ModelPin, in providers: [ModelInventory.Provider]
    ) -> Bool {
        guard let provider = providers.first(where: { $0.slug == pin.provider }) else {
            return false
        }
        return provider.models.contains(pin.model)
            && !provider.unavailableModels.contains(pin.model)
    }

    private func providerSelection(_ providers: [ModelInventory.Provider]) -> Binding<String?> {
        Binding(
            get: { selectedProviderSlug },
            set: { newSlug in
                selectedProviderSlug = newSlug
                if let provider = providers.first(where: { $0.slug == newSlug }) {
                    let available = provider.models.filter {
                        !provider.unavailableModels.contains($0)
                    }
                    if let current = selectedModelName, !available.contains(current) {
                        selectedModelName = available.first
                    }
                }
                applySelectedModel()
            })
    }

    private func modelSelection(_ available: [String]) -> Binding<String?> {
        Binding(
            get: { selectedModelName },
            set: { newModel in
                selectedModelName = newModel
                applySelectedModel()
            })
    }

    /// Sets `draft.model` once both a provider and a model are chosen.
    private func applySelectedModel() {
        guard let provider = selectedProviderSlug, let modelName = selectedModelName,
            !provider.isEmpty, !modelName.isEmpty
        else { return }
        draft?.model = ProfileDescription.ModelPin(provider: provider, model: modelName)
    }

    @ViewBuilder
    private func skillsSection(_ draft: Binding<BotProfileDraft>) -> some View {
        Section("Skills") {
            if draft.wrappedValue.skills.isEmpty {
                Text("None installed.").foregroundStyle(.secondary)
            } else {
                ForEach(draft.skills) { $skill in
                    Toggle(skill.name, isOn: $skill.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func toolsetsSection(_ draft: Binding<BotProfileDraft>) -> some View {
        Section {
            if draft.wrappedValue.toolsets.isEmpty {
                Text("None installed.").foregroundStyle(.secondary)
            } else if !draft.wrappedValue.toolsetsEditable {
                Text("The server didn't report this bot's toolsets, so they can't be edited here. Change them with `hermes -p \(bot.name) tools`.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(draft.toolsets) { $toolset in
                    Toggle(isOn: $toolset.enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(toolset.label.isEmpty ? toolset.name : toolset.label)
                            if !toolset.description.isEmpty {
                                Text(toolset.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Toolsets")
        }
    }

    @ViewBuilder
    private func mcpSection(_ draft: Binding<BotProfileDraft>) -> some View {
        Section("MCP Servers") {
            if draft.wrappedValue.mcpServers.isEmpty {
                Text("None configured.").foregroundStyle(.secondary)
            } else {
                ForEach(draft.mcpServers) { $server in
                    Toggle(isOn: $server.enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                            Text(server.transport)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func load() async {
        loading = true
        // Only clear a stale save failure when there's no draft yet — once a
        // draft exists, a failed Reload reports into this same slot below,
        // and clearing it early would blank the row for the whole request.
        if draft == nil {
            saveError = nil
        }
        async let profileResult = model.loadBotProfile(bot.name)
        async let inventoryResult = model.botModelInventory(bot.name)
        let (result, inv) = await (profileResult, inventoryResult)
        switch result {
        case .success(let profile):
            let newDraft = BotProfileDraft(profile)
            draft = newDraft
            inventory = inv
            if let inv {
                selectedProviderSlug = newDraft.model?.provider ?? inv.currentProvider
                selectedModelName = newDraft.model?.model ?? inv.currentModel
            } else {
                selectedProviderSlug = nil
                selectedModelName = nil
            }
            loadError = nil
            saveError = nil
        case .failure(let error):
            // With no draft on screen yet, the full-screen error view (keyed
            // off `loadError`) is what's visible — that's where this belongs.
            // Once a draft exists, that view never renders again, so a
            // failed Reload has to surface here instead, in the row the user
            // can actually see.
            if draft != nil {
                saveError = error.message
            } else {
                loadError = error.message
            }
        }
        loading = false
    }

    private func save() async {
        guard let draft else { return }
        saving = true
        saveError = nil
        let result = await model.saveBotProfile(bot.name, draft: draft)
        saving = false
        switch result {
        case .saved:
            dismiss()
        case .failed(let message):
            saveError = message
        case .needsModelConfirmation(let message):
            confirmMessage = message
            confirmShown = true
        }
    }

    private func confirmModel() async {
        guard let pin = draft?.model else { return }
        saving = true
        let error = await model.confirmBotModel(bot.name, pin: pin)
        saving = false
        if let error {
            saveError = error
        } else {
            dismiss()
        }
    }
}
