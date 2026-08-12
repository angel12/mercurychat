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
                Group {
                    switch sheet {
                    case .clarify(let request):
                        ClarifySheet(controller: controller, request: request)
                    case .sudo(let request):
                        SudoSheet(controller: controller, request: request)
                    case .secret(let request):
                        SecretSheet(controller: controller, request: request)
                    }
                }
                // A swipe-dismiss would hide the prompt while the agent
                // stays blocked (the pending request outlives the sheet and
                // nothing re-presents it) — answering, even with "Skip", is
                // the only way out.
                .interactiveDismissDisabled()
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
    @State private var renameShown = false
    @State private var renameText = ""
    /// Scroll-pinning bookkeeping. Every field is read and written only inside
    /// gesture/preference/onChange callbacks, never in `body` — so it lives in
    /// a plain class on purpose. As `@State` value fields, the per-frame
    /// writes (bottom distance changes on every scrolled point) invalidated
    /// the whole transcript body 120×/s, which showed up as app-wide lag.
    @State private var scroll = TranscriptScrollState()

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
        .alert("Rename Session", isPresented: $renameShown) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                Task { await controller.rename(renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
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
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                // Modern OSes report scroll offsets via onScrollGeometryChange.
                // The pre-iOS-18 fallback reads a preference off a GeometryReader
                // in the content's background — that pattern stopped emitting on
                // pure scroll-position changes in newer SwiftUI (verified on
                // iOS 26: zero preference events during a 400pt drag), so it is
                // ONLY the fallback, never the primary path.
                let base = ScrollView {
                    transcriptItems
                        .padding(.vertical, 12)
                        .background(
                            GeometryReader { content in
                                Color.clear.preference(
                                    key: BottomDistanceKey.self,
                                    value: content.frame(in: .named("transcript")).maxY
                                        - viewport.size.height)
                            }
                        )
                }
                .coordinateSpace(name: "transcript")

                Group {
                    if #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) {
                        base.onScrollGeometryChange(for: CGFloat.self) { geo in
                            geo.contentSize.height - geo.visibleRect.maxY
                        } action: { [scroll] _, distance in
                            scroll.update(bottomDistance: distance)
                        }
                    } else {
                        base.onPreferenceChange(BottomDistanceKey.self) { [scroll] distance in
                            scroll.update(bottomDistance: distance)
                        }
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { [scroll] _ in
                            // Unpin the instant a drag starts. Waiting for the
                            // geometry callback loses the race against a queued
                            // auto-scroll, which snaps back to the bottom and
                            // re-pins before the "scrolled away" reading lands.
                            scroll.isDragging = true
                            scroll.isAutoScrolling = false
                            scroll.setPinned(false)
                        }
                        .onEnded { [scroll] _ in
                            scroll.isDragging = false
                            if scroll.bottomDistance < TranscriptScrollState.repinDistance {
                                scroll.setPinned(true)
                            }
                        }
                )
                .overlay(alignment: .bottom) {
                    if !scroll.isPinnedToBottom {
                        jumpToLatestButton(proxy)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: scroll.isPinnedToBottom)
                .onChange(of: controller.store.items.count) {
                    // The user's own message always snaps the view back down;
                    // otherwise respect a reader who scrolled away.
                    if case .user = controller.store.items.last { scroll.setPinned(true) }
                    guard scroll.isPinnedToBottom else { return }
                    scrollToBottom(proxy, animated: true)
                }
                .onChange(of: lastItemFingerprint) {
                    guard scroll.isPinnedToBottom else { return }
                    scrollToBottom(proxy, animated: false)
                }
            }
        }
    }

    private var transcriptItems: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if let historyError = controller.historyError {
                VStack(spacing: 6) {
                    Text(historyError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await controller.retryHistory() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isLoading)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
            } else if controller.canLoadOlder {
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
    }

    /// Defer the actual scroll by one display frame so all onChange firings
    /// within that frame collapse into a single scrollTo. Streaming lands
    /// several deltas per frame across separate runloop turns, so a plain
    /// next-turn Task hop is NOT enough — it can execute between two deltas
    /// of the same frame and scroll twice.
    ///
    /// Note this does NOT silence the "onChange(of: Int) action tried to
    /// update multiple times per frame" / "<OnScrollGeometryChange Modifier>
    /// tried to update…" console lines: those fire (once per process) purely
    /// because the OBSERVED VALUES change more than once per frame — verified
    /// empirically with completely empty action bodies. They are framework
    /// diagnostics inherent to streaming + scrolling, not app bugs.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !scroll.scrollQueued else { return }
        scroll.scrollQueued = true
        Task { @MainActor [scroll] in
            try? await Task.sleep(for: .milliseconds(16))
            scroll.scrollQueued = false
            guard scroll.isPinnedToBottom else { return }
            // Long animated hops overshoot LazyVStack's estimated layout and
            // strand the viewport in blank space — only animate near-bottom.
            if animated, scroll.bottomDistance < 600 {
                scroll.isAutoScrolling = true
                withAnimation {
                    proxy.scrollTo("bottom", anchor: .bottom)
                } completion: {
                    scroll.isAutoScrolling = false
                }
            } else {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func jumpToLatestButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            // Suppress the stale "far from bottom" geometry reading that can
            // arrive while the lazy layout settles after the jump; update()
            // clears the flag once a near-bottom reading lands.
            scroll.isAutoScrolling = true
            scroll.setPinned(true)
            // Deliberately NOT animated: an animated scrollTo across a long
            // LazyVStack overshoots the lazy layout estimate and strands the
            // viewport in un-laid-out blank space (reproduced on iOS 26).
            // An instant jump resolves the target layout synchronously.
            proxy.scrollTo("bottom", anchor: .bottom)
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .padding(10)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
        .accessibilityLabel("Jump to latest")
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
                        .help(usageDetail)
                }
                Menu {
                    Button("Rename Session…") {
                        renameText = controller.store.title ?? ""
                        renameShown = true
                    }
                    if let profile = controller.store.profileName {
                        Text("Profile: \(profile)")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var usageDetail: String {
        let usage = controller.store.totalUsage
        return "\(usage.calls) calls · \(usage.inputTokens.formatted()) in · \(usage.outputTokens.formatted()) out"
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
    @State private var isSubmitting = false

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
                        guard !isSubmitting else { return }
                        isSubmitting = true
                        Task {
                            await controller.respondApproval(request, choice: choice)
                            isSubmitting = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSubmitting)
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
    @State private var submitError: String?
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(request.question).font(.body)
                }
                SubmitErrorSection(error: submitError)
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
            .disabled(isSubmitting)
            .navigationTitle("Question")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { respond("") }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Answer") {
                        respond(
                            request.multiSelect && !selected.isEmpty
                                ? selected.sorted().joined(separator: ", ")
                                : freeText)
                    }
                    .disabled(isSubmitting || (freeText.isEmpty && selected.isEmpty))
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private func respond(_ answer: String) {
        guard !isSubmitting else { return }
        isSubmitting = true
        submitError = nil
        Task {
            let outcome = await controller.respondClarify(
                requestID: request.requestID, answer: answer)
            isSubmitting = false
            switch outcome {
            case .delivered, .expired:
                // Expired closes too: the request is gone server-side and
                // the controller posted a visible expiry notice. A newer
                // clarify may have replaced this one mid-RPC — the sheet is
                // now presenting it, so dismiss only when nothing is pending.
                if controller.store.pendingClarify == nil { dismiss() }
            case .failed:
                submitError = controller.errorMessage
                    ?? "The answer didn't reach the server — try again."
            }
        }
    }
}

private struct SudoSheet: View {
    let controller: ChatController
    let request: SudoRequest
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var submitError: String?
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("The agent needs your administrator password to continue.")
                } footer: {
                    Text("Sent directly to the agent's sudo prompt; never stored.")
                }
                SubmitErrorSection(error: submitError)
                SecureField("Password", text: $password)
            }
            .disabled(isSubmitting)
            .navigationTitle("Sudo Password")
            // The password must not outlive the sheet, whatever dismissed it
            // (delivery, expiry event, turn end, swipe on a future OS).
            .onDisappear { password = "" }
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Decline") { respond("") }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { respond(password) }
                        .disabled(isSubmitting || password.isEmpty)
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 400, minHeight: 220)
        #endif
    }

    private func respond(_ value: String) {
        guard !isSubmitting else { return }
        isSubmitting = true
        submitError = nil
        Task {
            let outcome = await controller.respondSudo(
                requestID: request.requestID, password: value)
            isSubmitting = false
            switch outcome {
            case .delivered, .expired:
                // The value has served its purpose the moment the RPC
                // settles — clear it BEFORE the dismiss animation, not
                // whenever SwiftUI releases the sheet's state (#19).
                password = ""
                if controller.store.pendingSudo == nil { dismiss() }
            case .failed:
                // Kept for the retry the sheet is offering.
                submitError = controller.errorMessage
                    ?? "The password didn't reach the server — try again."
            }
        }
    }
}

private struct SecretSheet: View {
    let controller: ChatController
    let request: SecretRequest
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var submitError: String?
    @State private var isSubmitting = false

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
                SubmitErrorSection(error: submitError)
                SecureField("Value", text: $value)
            }
            .disabled(isSubmitting)
            .navigationTitle("Credential")
            // The credential must not outlive the sheet, whatever dismissed
            // it (delivery, expiry event, turn end).
            .onDisappear { value = "" }
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { respond("") }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { respond(value) }
                        .disabled(isSubmitting || value.isEmpty)
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 400, minHeight: 220)
        #endif
    }

    private func respond(_ answer: String) {
        guard !isSubmitting else { return }
        isSubmitting = true
        submitError = nil
        Task {
            let outcome = await controller.respondSecret(
                requestID: request.requestID, value: answer)
            isSubmitting = false
            switch outcome {
            case .delivered, .expired:
                // Clear BEFORE the dismiss animation, not whenever SwiftUI
                // releases the sheet's state (#19).
                value = ""
                if controller.store.pendingSecret == nil { dismiss() }
            case .failed:
                // Kept for the retry the sheet is offering.
                submitError = controller.errorMessage
                    ?? "The credential didn't reach the server — try again."
            }
        }
    }
}

/// Inline failure row for the blocking-prompt sheets: the sheet stays up so
/// the answer can be retried.
private struct SubmitErrorSection: View {
    let error: String?

    var body: some View {
        if let error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
    }
}

/// Whether the transcript follows streaming output: scrolling away from the
/// bottom releases the pin, scrolling back (or sending a message, or tapping
/// the jump-to-latest button) restores it.
///
/// Only `isPinnedToBottom` is observable — the body reads it for the
/// jump-to-latest button, and its writes are equality-guarded so the view
/// invalidates only on real pin/unpin transitions. Everything else is
/// `@ObservationIgnored` on purpose: those fields are written on every
/// scrolled point / touch move, and observable per-frame writes would
/// invalidate the whole transcript body 120×/s (measured as app-wide lag).
@MainActor @Observable
private final class TranscriptScrollState {
    /// Hysteresis band for the pin: drifting past `unpinDistance` releases it,
    /// but only returning to (nearly) the exact bottom re-engages it. A single
    /// threshold re-pins anyone the auto-scroll just yanked down, which made
    /// the pin impossible to escape mid-stream.
    @ObservationIgnored static let unpinDistance: CGFloat = 80
    @ObservationIgnored static let repinDistance: CGFloat = 8

    private(set) var isPinnedToBottom = true
    /// True while a deferred scroll is queued so extra requests coalesce.
    @ObservationIgnored var scrollQueued = false
    /// Latest scroll-geometry reading, kept so gesture callbacks (which
    /// can't see geometry) can decide whether the drag ended at the bottom.
    @ObservationIgnored var bottomDistance: CGFloat = 0
    @ObservationIgnored var isDragging = false
    /// True while an animated programmatic scroll is in flight. Geometry
    /// reports "far from bottom" mid-animation, which must not unpin —
    /// cleared by the animation's completion or by the user grabbing the view.
    @ObservationIgnored var isAutoScrolling = false

    func setPinned(_ pinned: Bool) {
        guard pinned != isPinnedToBottom else { return }
        isPinnedToBottom = pinned
    }

    func update(bottomDistance distance: CGFloat) {
        bottomDistance = distance
        if distance > Self.unpinDistance {
            guard !isAutoScrolling else { return }
            setPinned(false)
        } else if distance < Self.repinDistance, !isDragging {
            isAutoScrolling = false
            setPinned(true)
        }
    }
}

/// How far the transcript content's bottom edge sits below the visible
/// viewport's bottom edge — ~0 when scrolled fully down, growing as the
/// reader scrolls up into history.
private struct BottomDistanceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

