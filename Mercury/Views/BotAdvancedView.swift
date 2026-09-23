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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled((draft?.hasChanges != true) || saving)
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
                if let saveError {
                    Section {
                        HStack {
                            Text(saveError).font(.caption).foregroundStyle(.red)
                            Spacer()
                            Button("Reload") { Task { await load() } }
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
        }
    }

    @ViewBuilder
    private func modelSection(_ draft: Binding<BotProfileDraft>) -> some View {
        Section("Model") {
            if let inventory {
                let providers = inventory.providers.filter { $0.authenticated != false }
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
        Section("Toolsets") {
            if draft.wrappedValue.toolsets.isEmpty {
                Text("None installed.").foregroundStyle(.secondary)
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
        saveError = nil
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
        case .failure(let error):
            loadError = error.message
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
