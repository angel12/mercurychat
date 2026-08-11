import ChatCore
import MercuryKit
import SwiftUI

/// The heart of the app: one session's streaming transcript + composer.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    let mode: ChatController.Mode
    /// Stable identity for the .task that creates the controller.
    let sessionKey: String

    @State private var controller: ChatController?
    /// One shared sheet slot — stacked SwiftUI sheets fault.
    @State private var activeSheet: ChatSheet?

    enum ChatSheet: Identifiable {
        case clarify(ClarifyRequest)
        case sudo(SudoRequest)
        case secret(SecretRequest)

        var id: String {
            switch self {
            case .clarify(let request): return "clarify-\(request.requestID)"
            case .sudo(let request): return "sudo-\(request.requestID)"
            case .secret(let request): return "secret-\(request.requestID)"
            }
        }
    }

    var body: some View {
        Group {
            if let controller {
                ChatContentView(controller: controller, activeSheet: $activeSheet)
            } else {
                ProgressView("Opening session…")
            }
        }
        .task(id: sessionKey) {
            let chat = model.openChat(profile: profileForMode)
            controller = chat
            await chat.begin(mode)
        }
        .onDisappear {
            if let controller { model.closeChat(controller) }
        }
        .sheet(item: $activeSheet) { sheet in
            if let controller {
                switch sheet {
                case .clarify(let request):
                    ClarifySheet(controller: controller, request: request)
                case .sudo(let request):
                    SudoSheet(controller: controller, request: request)
                case .secret(let request):
                    SecretSheet(controller: controller, request: request)
                }
            }
        }
    }

    private var profileForMode: String? {
        if case .resume(let session) = mode { return session.profile }
        return nil
    }
}

/// Rendered once the controller exists.
private struct ChatContentView: View {
    @Bindable var controller: ChatController
    @Binding var activeSheet: ChatView.ChatSheet?
    @State private var composerText = ""

    var body: some View {
        VStack(spacing: 0) {
            transcript
            promptCards
            ComposerView(controller: controller, text: $composerText)
        }
        .navigationTitle(controller.store.title ?? "Session")
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { headerChips }
        .onChange(of: controller.store.pendingClarify) { _, request in
            if let request { activeSheet = .clarify(request) } else if isClarify { activeSheet = nil }
        }
        .onChange(of: controller.store.pendingSudo) { _, request in
            if let request { activeSheet = .sudo(request) } else if isSudo { activeSheet = nil }
        }
        .onChange(of: controller.store.pendingSecret) { _, request in
            if let request { activeSheet = .secret(request) } else if isSecret { activeSheet = nil }
        }
    }

    private var isClarify: Bool {
        if case .clarify = activeSheet { return true }
        return false
    }
    private var isSudo: Bool {
        if case .sudo = activeSheet { return true }
        return false
    }
    private var isSecret: Bool {
        if case .secret = activeSheet { return true }
        return false
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if controller.canLoadOlder {
                        Button("Load earlier messages") {
                            Task { await controller.loadOlderMessages() }
                        }
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity)
                    }
                    ForEach(controller.store.items) { item in
                        TranscriptItemView(item: item)
                            .id(item.id)
                    }
                    if let generating = controller.store.generatingToolName {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Preparing \(generating)…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }
                    if let error = controller.errorMessage {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }
                    // Scroll anchor.
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 12)
            }
            .onChange(of: controller.store.items.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: lastItemFingerprint) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// Cheap change signal for streaming updates to the final item.
    private var lastItemFingerprint: Int {
        switch controller.store.items.last {
        case .assistant(let message):
            return message.text.count &+ message.reasoning.count
        case .tool(let tool):
            return (tool.summary?.count ?? 0) &+ (tool.isRunning ? 1 : 0)
        default:
            return 0
        }
    }

    @ViewBuilder
    private var promptCards: some View {
        if let approval = controller.store.pendingApproval {
            ApprovalCard(controller: controller, request: approval)
                .padding(.horizontal)
                .padding(.bottom, 4)
        }
    }

    @ToolbarContentBuilder
    private var headerChips: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
                if controller.store.running {
                    ProgressView().controlSize(.small)
                }
                if let model = controller.store.model {
                    Text(model)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                if controller.store.totalUsage.totalTokens > 0 {
                    Text("\(controller.store.totalUsage.totalTokens.formatted()) tok")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Composer

private struct ComposerView: View {
    @Bindable var controller: ChatController
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                controller.store.running ? "Queue a message…" : "Message",
                text: $text, axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...6)
            .focused($focused)
            .onSubmit(send)
            #if os(macOS)
                .onKeyPress(.return, phases: .down) { press in
                    // ⌘⏎ / plain ⏎ sends; ⇧⏎ inserts a newline.
                    if press.modifiers.contains(.shift) { return .ignored }
                    send()
                    return .handled
                }
            #endif

            if controller.store.running {
                Button {
                    Task { await controller.interrupt() }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop the current turn (⌘.)")
            }

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
        .background(.bar)
    }

    private func send() {
        let message = text
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = ""
        Task { await controller.submit(message) }
    }
}

// MARK: - Approval card

private struct ApprovalCard: View {
    let controller: ChatController
    let request: ApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Approval needed", systemImage: "exclamationmark.shield")
                .font(.headline)
            if let command = request.command {
                Text(command)
                    .font(.callout.monospaced())
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                ForEach(request.choices, id: \.self) { choice in
                    Button(choiceLabel(choice), role: choice == "deny" ? .destructive : nil) {
                        Task { await controller.respondApproval(choice: choice) }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.yellow.opacity(0.5)))
    }

    private func choiceLabel(_ choice: String) -> String {
        switch choice {
        case "once": return "Allow Once"
        case "session": return "Allow This Session"
        case "always": return "Always Allow"
        case "deny": return "Deny"
        default: return choice.capitalized
        }
    }
}

// MARK: - Clarify / sudo / secret sheets

private struct ClarifySheet: View {
    let controller: ChatController
    let request: ClarifyRequest
    @Environment(\.dismiss) private var dismiss
    @State private var freeText = ""
    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(request.question).font(.body)
                }
                if !request.choices.isEmpty {
                    Section {
                        ForEach(request.choices, id: \.self) { choice in
                            Button {
                                if request.multiSelect {
                                    if !selected.insert(choice).inserted {
                                        selected.remove(choice)
                                    }
                                } else {
                                    respond(choice)
                                }
                            } label: {
                                HStack {
                                    Text(choice).foregroundStyle(.primary)
                                    Spacer()
                                    if selected.contains(choice) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    TextField("Or answer in your own words", text: $freeText, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle("Question")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { respond("") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Answer") {
                        respond(
                            request.multiSelect && !selected.isEmpty
                                ? selected.sorted().joined(separator: ", ")
                                : freeText)
                    }
                    .disabled(freeText.isEmpty && selected.isEmpty)
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private func respond(_ answer: String) {
        Task { await controller.respondClarify(requestID: request.requestID, answer: answer) }
        dismiss()
    }
}

private struct SudoSheet: View {
    let controller: ChatController
    let request: SudoRequest
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("The agent needs your administrator password to continue.")
                } footer: {
                    Text("Sent directly to the agent's sudo prompt; never stored.")
                }
                SecureField("Password", text: $password)
            }
            .navigationTitle("Sudo Password")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Decline") { respond("") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { respond(password) }
                        .disabled(password.isEmpty)
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 400, minHeight: 220)
        #endif
    }

    private func respond(_ value: String) {
        Task { await controller.respondSudo(requestID: request.requestID, password: value) }
        dismiss()
    }
}

private struct SecretSheet: View {
    let controller: ChatController
    let request: SecretRequest
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(request.prompt.isEmpty ? "A skill needs a credential." : request.prompt)
                } footer: {
                    if let envVar = request.envVar {
                        Text("Stored on the server as \(envVar); never kept on this device.")
                    }
                }
                SecureField("Value", text: $value)
            }
            .navigationTitle("Credential")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { respond("") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { respond(value) }
                        .disabled(value.isEmpty)
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 400, minHeight: 220)
        #endif
    }

    private func respond(_ answer: String) {
        Task { await controller.respondSecret(requestID: request.requestID, value: answer) }
        dismiss()
    }
}
