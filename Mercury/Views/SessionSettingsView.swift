import ChatCore
import MercuryKit
import SwiftUI

/// Per-chat settings, as Desktop's model, reasoning and approval menus offer
/// them (hermes v0.23): the model and reasoning effort apply to this chat
/// only, YOLO to this chat only, and the approval mode to the whole profile.
struct SessionSettingsView: View {
    @Bindable var controller: ChatController
    @Environment(\.dismiss) private var dismiss

    @State private var approvalMode: ApprovalMode?
    @State private var error: String?
    @State private var busy = false

    private var store: TranscriptStore { controller.store }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ModelPickerView(controller: controller)
                    } label: {
                        LabeledContent("Model") {
                            Text(store.model ?? "Default")
                                .lineLimit(1)
                        }
                    }
                    Picker("Reasoning", selection: reasoningBinding) {
                        Text("Default").tag(String?.none)
                        ForEach(ReasoningLevels.all, id: \.self) { level in
                            Text(level.capitalized).tag(String?.some(level))
                        }
                    }
                } header: {
                    Text("This chat")
                } footer: {
                    Text("Changes apply to this chat only. During a turn they take effect on the next one.")
                }

                Section {
                    Toggle("Auto-approve commands (YOLO)", isOn: yoloBinding)
                    Picker("Approval mode", selection: approvalBinding) {
                        Text("Ask every time").tag(ApprovalMode?.some(.manual))
                        Text("Smart").tag(ApprovalMode?.some(.smart))
                        Text("Never ask").tag(ApprovalMode?.some(.off))
                        if approvalMode == nil {
                            Text("Unknown").tag(ApprovalMode?.none)
                        }
                    }
                } header: {
                    Text("Approvals")
                } footer: {
                    Text(
                        "YOLO skips approvals in this chat only. Approval mode is the profile's default for every chat\(store.profileName.map { " in \($0)" } ?? "")."
                    )
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(busy)
            .navigationTitle("Session Settings")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                approvalMode = await controller.loadApprovalMode()
                    ?? store.approvalMode.flatMap(ApprovalMode.init(rawValue:))
            }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 380)
        #endif
    }

    private var reasoningBinding: Binding<String?> {
        Binding(
            get: { store.reasoningEffort.flatMap { ReasoningLevels.all.contains($0) ? $0 : nil } },
            set: { level in
                guard let level else { return }
                run { await controller.setReasoning(level) }
            })
    }

    private var yoloBinding: Binding<Bool> {
        Binding(
            get: { store.yolo ?? false },
            set: { enabled in run { await controller.setYolo(enabled) } })
    }

    private var approvalBinding: Binding<ApprovalMode?> {
        Binding(
            get: { approvalMode },
            set: { mode in
                guard let mode else { return }
                let previous = approvalMode
                approvalMode = mode
                run {
                    let failure = await controller.setApprovalMode(mode)
                    if failure != nil { approvalMode = previous }
                    return failure
                }
            })
    }

    /// One write at a time; the server's `session.info` repaints the values.
    private func run(_ write: @escaping @MainActor () async -> String?) {
        busy = true
        error = nil
        Task {
            error = await write()
            busy = false
        }
    }
}

/// Providers and their models, from `model.options`.
private struct ModelPickerView: View {
    @Bindable var controller: ChatController
    @Environment(\.dismiss) private var dismiss

    @State private var options: ModelOptions?
    @State private var loadError: String?
    @State private var switchError: String?
    @State private var confirming: (model: String, provider: String, message: String)?
    @State private var showAll: Set<String> = []
    @State private var switching = false

    var body: some View {
        List {
            if let switchError {
                Text(switchError).foregroundStyle(.red)
            }
            if let options {
                ForEach(options.providers) { provider in
                    Section {
                        ForEach(visibleModels(provider), id: \.self) { model in
                            Button {
                                pick(model, provider: provider.slug)
                            } label: {
                                HStack {
                                    Text(model)
                                        .foregroundStyle(provider.authenticated ? .primary : .secondary)
                                    Spacer()
                                    if isCurrent(model, provider: provider) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .disabled(!provider.authenticated || switching)
                        }
                        if hiddenCount(provider) > 0 {
                            Button("Show all \(provider.models.count) models") {
                                showAll.insert(provider.slug)
                            }
                        }
                    } header: {
                        Text(provider.name)
                    } footer: {
                        if !provider.authenticated {
                            Text("Not signed in on the server.")
                        } else if let warning = provider.warning {
                            Text(warning)
                        }
                    }
                }
            } else if let loadError {
                Text(loadError).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Model")
        .task {
            do {
                options = try await controller.loadModelOptions()
            } catch {
                loadError = (error as? HermesError)?.errorDescription ?? error.localizedDescription
            }
        }
        .alert(
            "Switch to a more expensive model?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { pending in
            Button("Switch") { pick(pending.model, provider: pending.provider, confirmed: true) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
    }

    private func isCurrent(_ model: String, provider: ModelOptions.Provider) -> Bool {
        let current = controller.store.model ?? options?.currentModel
        let currentProvider = controller.store.provider ?? options?.currentProvider
        return model == current && (currentProvider == nil || currentProvider == provider.slug)
    }

    /// The provider's featured short list first, like Desktop; every model
    /// once the user asks, and always the current one.
    private func visibleModels(_ provider: ModelOptions.Provider) -> [String] {
        guard !showAll.contains(provider.slug), !provider.featuredModels.isEmpty else {
            return provider.models
        }
        var models = provider.featuredModels
        if let current = controller.store.model, provider.models.contains(current),
            !models.contains(current)
        {
            models.insert(current, at: 0)
        }
        return models
    }

    private func hiddenCount(_ provider: ModelOptions.Provider) -> Int {
        provider.models.count - visibleModels(provider).count
    }

    private func pick(_ model: String, provider: String, confirmed: Bool = false) {
        switching = true
        switchError = nil
        Task {
            switch await controller.switchModel(model, provider: provider, confirmed: confirmed) {
            case .switched:
                switching = false
                dismiss()
            case .needsConfirmation(let message):
                switching = false
                confirming = (model, provider, message)
            case .failed(let message):
                switching = false
                switchError = message
            }
        }
    }
}
