import ChatCore
import MercuryKit
import PhotosUI
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

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
            // nil = disconnected before this body ran: keep the progress
            // placeholder; RootView swaps to the connect screen.
            guard let chat = model.openChat(profile: profileForMode) else { return }
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
                        if request.isBatch {
                            BatchClarifySheet(controller: controller, request: request)
                        } else {
                            ClarifySheet(controller: controller, request: request)
                        }
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
        ScrollViewReader { proxy in
            // List (UICollectionView-backed) instead of ScrollView+LazyVStack
            // ON PURPOSE: LazyVStack re-runs a whole-container item-phase pass
            // on every layout change, and with a long transcript the pass
            // costs more than a frame — merely SCROLLING across the lazy
            // container's estimated span livelocked a device for over a
            // minute (Time Profiler: 47% LazyLayout, 29% Text.sizeThatFits,
            // zero app frames). List virtualizes with per-row height caching
            // and never pays whole-container passes.
            let base = List {
                transcriptItems(proxy)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Group {
                if #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) {
                    base.onScrollGeometryChange(for: BottomGeometry.self) { geo in
                        BottomGeometry(
                            distance: geo.contentSize.height - geo.visibleRect.maxY,
                            contentHeight: geo.contentSize.height)
                    } action: { [scroll] old, new in
                        // Distinguish "content grew under me" from "the
                        // user scrolled": streaming appends re-measure rows
                        // and produce distance jumps with zero user input —
                        // those must never release the pin.
                        scroll.update(
                            bottomDistance: new.distance,
                            contentGrew: new.contentHeight != old.contentHeight)
                    }
                } else {
                    // Pre-18 has no scroll-geometry source for List (the old
                    // preference trick measured the LazyVStack's frame, which
                    // List doesn't expose). Degraded but functional: the drag
                    // gesture still unpins; with bottomDistance stuck at its
                    // last value the drag-end repin is approximate.
                    base
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
                .onChange(of: controller.store.userEchoCounter) {
                    // The user's own message always snaps the view back down.
                    // This is its own signal (not derived from items.count):
                    // checking `items.last` missed the echo whenever the
                    // reply's first event landed in the same update cycle,
                    // leaving the view parked while the answer streamed in
                    // below the fold.
                    scroll.setPinned(true)
                    scrollToBottom(proxy, animated: true)
                }
                .onChange(of: controller.store.items.count) {
                    guard scroll.isPinnedToBottom else { return }
                    scrollToBottom(proxy, animated: true)
                }
                .onChange(of: lastItemFingerprint) {
                    guard scroll.isPinnedToBottom else { return }
                    scrollToBottom(proxy, animated: false)
                }
                // Reading away from the bottom while a reply streams: freeze
                // the transcript (the controller buffers events) — mutating
                // the LazyVStack under a viewport parked over its estimated
                // span costs more than a frame per pass and hangs the device.
                .onChange(of: scroll.isPinnedToBottom) { _, pinned in
                    controller.setTranscriptHold(!pinned && controller.store.running)
                }
                .onChange(of: controller.store.running) { _, running in
                    controller.setTranscriptHold(running && !scroll.isPinnedToBottom)
                }
        }
    }

    @ViewBuilder
    private func transcriptItems(_ proxy: ScrollViewProxy) -> some View {
        Group {
            if let historyError = controller.historyError {
                VStack(spacing: 6) {
                    Text(historyError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        loadOlderPreservingViewport(proxy) {
                            await controller.retryHistory()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isLoading)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
            } else if controller.canLoadOlder {
                Button("Load earlier messages") {
                    loadOlderPreservingViewport(proxy) {
                        await controller.loadOlderMessages()
                    }
                }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity)
            }
            ForEach(controller.store.items) { item in
                TranscriptItemView(
                    item: item,
                    onRetryUser: { id in Task { await controller.retrySend(messageID: id) } }
                )
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
        // Suppress geometry-driven unpinning for the whole deferral window:
        // between pinning and the deferred scrollTo, the next scroll-geometry
        // callback still reports the OLD far-from-bottom distance, and that
        // reading used to unpin and abort the queued scroll — the send-snap
        // and hydration-snap never ran at all when the reader was >80pt up
        // (the "transcript freezes when I send while scrolled up" report).
        // A real user drag still wins instantly via the drag gesture.
        scroll.isAutoScrolling = true
        Task { @MainActor [scroll] in
            try? await Task.sleep(for: .milliseconds(16))
            scroll.scrollQueued = false
            guard scroll.isPinnedToBottom else {
                scroll.isAutoScrolling = false
                return
            }
            // Long animated hops overshoot LazyVStack's estimated layout and
            // strand the viewport in blank space — only animate near-bottom.
            if animated, scroll.bottomDistance < 600 {
                withAnimation {
                    proxy.scrollTo("bottom", anchor: .bottom)
                } completion: {
                    settleToBottom(proxy)
                }
            } else {
                proxy.scrollTo("bottom", anchor: .bottom)
                settleToBottom(proxy)
            }
        }
    }

    /// One `scrollTo` across a long un-laid-out LazyVStack lands SHORT of the
    /// bottom (the lazy layout only estimates the un-rendered span — verified
    /// on iOS 26.5, where a ~20k-pt jump strands hundreds of points up). Keep
    /// re-issuing instant hops until the geometry actually reads "at bottom",
    /// bounded so a pathological layout can't loop forever. Landing clears
    /// `isAutoScrolling` (via the repin branch of `update`), which ends the
    /// chain; a user drag cancels it the same way.
    private func settleToBottom(_ proxy: ScrollViewProxy) {
        guard !scroll.settleActive else { return }
        scroll.settleActive = true
        Task { @MainActor [scroll] in
            defer { scroll.settleActive = false }
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(32))
                guard scroll.isPinnedToBottom, scroll.isAutoScrolling,
                    scroll.bottomDistance >= TranscriptScrollState.repinDistance
                else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// Prepending older history shifts every offset in the LazyVStack and
    /// the viewport lands somewhere unrelated (#18). Capture the current top
    /// item, run the prepend, then pin that item back to the top —
    /// non-animated, since animated hops across a long LazyVStack strand the
    /// viewport in un-laid-out space.
    private func loadOlderPreservingViewport(
        _ proxy: ScrollViewProxy, _ load: @escaping () async -> Void
    ) {
        guard !controller.isLoading else { return }
        let anchorID = controller.store.items.first?.id
        let countBefore = controller.store.items.count
        Task {
            await load()
            guard let anchorID, controller.store.items.count > countBefore else { return }
            // Let the prepend commit its layout pass before re-anchoring.
            await Task.yield()
            proxy.scrollTo(anchorID, anchor: .top)
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
            proxy.scrollTo("bottom", anchor: .bottom)
            // A single instant hop across a long lazy span lands short —
            // keep hopping until the geometry confirms the bottom.
            settleToBottom(proxy)
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
        if let setup = controller.store.pendingMcpSetup {
            McpSetupCard(controller: controller, request: setup)
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
                if let usage = controller.store.sessionUsage, usage.totalTokens > 0 {
                    // The `session.usage` ticker refreshes this live during
                    // the turn; context fill beats a raw token count when the
                    // backend reports one.
                    Text(
                        usage.contextPercent.map { "\($0)% ctx" }
                            ?? "\(usage.totalTokens.formatted()) tok"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(usageDetail(usage))
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

    private func usageDetail(_ usage: TurnUsage) -> String {
        var parts = [
            "\(usage.calls) calls · \(usage.inputTokens.formatted()) in · \(usage.outputTokens.formatted()) out"
        ]
        if let used = usage.contextUsed, let max = usage.contextMax {
            parts.append("context \(used.formatted()) / \(max.formatted())")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Composer

private struct ComposerView: View {
    @Bindable var controller: ChatController
    @Binding var text: String
    @FocusState private var focused: Bool
    @State private var attachments: [PendingAttachment] = []
    @State private var attachmentError: String?
    @State private var showingFileImporter = false
    #if os(iOS) || os(visionOS)
        @State private var photoSelection: [PhotosPickerItem] = []
    #endif

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            if let attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !attachments.isEmpty {
                AttachmentTray(attachments: $attachments)
            }
            HStack(alignment: .bottom, spacing: 8) {
                attachMenu
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
                .disabled(!canSend)
            }
        }
        .padding(10)
        .background(.bar)
        #if os(macOS)
            .onPasteCommand(of: [.image]) { providers in
                loadProviders(providers)
            }
        #endif
        // One drop destination, not two: stacked `.dropDestination` modifiers
        // on the same view register a single delegate, so the second would
        // shadow the first. `onDrop` takes both content types at once —
        // Finder/Files deliver file URLs (filename preserved, read under
        // security scope), other apps deliver raw image Data.
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            loadProviders(providers)
            return !providers.isEmpty
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { addContents(of: url) }
        }
        #if os(iOS) || os(visionOS)
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                photoSelection = []
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            add(data: data, name: nil)
                        }
                    }
                }
            }
        #endif
    }

    @ViewBuilder private var attachMenu: some View {
        Menu {
            #if os(iOS) || os(visionOS)
                // PhotosPicker runs out of process — no usage description needed.
                PhotosPicker(
                    selection: $photoSelection, maxSelectionCount: 5,
                    matching: .images
                ) {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }
                Button {
                    for image in UIPasteboard.general.images ?? [] {
                        if let data = image.jpegData(compressionQuality: 0.9) {
                            add(data: data, name: nil)
                        }
                    }
                } label: {
                    Label("Paste Image", systemImage: "doc.on.clipboard")
                }
            #endif
            Button {
                showingFileImporter = true
            } label: {
                Label("Choose File…", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.title2)
        }
        .buttonStyle(.borderless)
        .help("Attach an image")
    }

    /// One cap for every input path (picker, paste, drop, file importer),
    /// matching PhotosPicker's maxSelectionCount.
    private static let maxAttachments = 5

    private func add(data: Data, name: String?) {
        guard attachments.count < Self.maxAttachments else {
            attachmentError = "Up to \(Self.maxAttachments) images per message."
            return
        }
        do {
            attachments.append(
                try ImageAttachmentPreparer.prepare(data: data, suggestedName: name))
            attachmentError = nil
        } catch {
            attachmentError = error.localizedDescription
        }
    }

    /// Reads a picked/dropped file URL under its security scope — sandboxed
    /// builds only get read access for the duration of that scope.
    private func addContents(of url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            attachmentError = "Couldn't read \(url.lastPathComponent)."
            return
        }
        add(data: data, name: url.lastPathComponent)
    }

    /// Shared by drop and (on macOS) ⌘V: prefer the file URL representation
    /// so the filename survives, and fall back to raw image bytes.
    private func loadProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in addContents(of: url) }
                }
            } else {
                _ = provider.loadDataRepresentation(for: .image) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in add(data: data, name: nil) }
                }
            }
        }
    }

    private func send() {
        let message = text
        let outgoing = attachments
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !outgoing.isEmpty
        else { return }
        text = ""
        attachments = []
        attachmentError = nil
        Task {
            // The keyboard can commit pending marked/autocorrect text OVER a
            // synchronous clear, resurrecting the sent message in the field
            // (#4). Re-clear once that commit has settled — but only when
            // the field still holds exactly what was sent, so a fast next
            // message is never wiped.
            await Task.yield()
            if text == message { text = "" }
            await controller.submit(message, attachments: outgoing)
        }
    }
}

/// Horizontal strip of staged attachments with per-item remove.
private struct AttachmentTray: View {
    @Binding var attachments: [PendingAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        AttachmentThumbnail(data: attachment.thumbnail ?? attachment.data)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.quaternary))
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.borderless)
                        .padding(2)
                        .accessibilityLabel("Remove \(attachment.filename)")
                    }
                }
            }
        }
        .frame(height: 68)
    }
}

/// Renders encoded image bytes; falls back to an icon when undecodable.
struct AttachmentThumbnail: View {
    let data: Data

    var body: some View {
        #if os(macOS)
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else { fallback }
        #else
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { fallback }
        #endif
    }

    private var fallback: some View {
        Image(systemName: "photo")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary)
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

// MARK: - MCP setup card

/// The agent's `setup_mcp` tool blocks (up to 10 minutes) on this consent
/// card. Mercury can't run the install/OAuth flows in-app yet, so the card
/// explains the request and offers Decline — which unblocks the agent
/// immediately and tells it to continue without the server — plus a pointer
/// to the terminal flow for users who actually want it installed.
private struct McpSetupCard: View {
    let controller: ChatController
    let request: McpSetupRequest
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "puzzlepiece.extension")
                .font(.headline)
            if !request.reason.isEmpty {
                Text(request.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(
                "Mercury can't run MCP setup flows yet. To add it, run `hermes mcp \(terminalVerb) \(request.server)` in a terminal — or decline and the agent will continue without it."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            Button("Decline", role: .destructive) {
                guard !isSubmitting else { return }
                isSubmitting = true
                Task {
                    _ = await controller.declineMcpSetup(request)
                    isSubmitting = false
                }
            }
            .buttonStyle(.bordered)
            .disabled(isSubmitting)
        }
        .padding(12)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.blue.opacity(0.35)))
    }

    private var title: String {
        switch request.action {
        case "enable": return "Agent asks to enable MCP server “\(request.server)”"
        case "authorize": return "Agent asks to authorize MCP server “\(request.server)”"
        default: return "Agent asks to install MCP server “\(request.server)”"
        }
    }

    private var terminalVerb: String {
        request.action == "authorize" ? "login" : request.action
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

/// Batch clarify (v0.20.5+): one `clarify.request` carrying several
/// questions. Answers lock per question via `clarify.respond {request_id,
/// question_id, answer}`; the batch resolves when the last one locks, so
/// this sheet collects everything and submits sequentially on confirm.
/// "Skip All" cancels the batch with one no-question_id respond.
private struct BatchClarifySheet: View {
    let controller: ChatController
    let request: ClarifyRequest
    @Environment(\.dismiss) private var dismiss
    @State private var freeText: [String: String] = [:]
    @State private var selected: [String: Set<String>] = [:]
    @State private var submitError: String?
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                SubmitErrorSection(error: submitError)
                ForEach(request.questions) { question in
                    Section(question.question) {
                        ForEach(question.choices, id: \.self) { choice in
                            Button {
                                toggle(choice, for: question)
                            } label: {
                                HStack {
                                    Text(choice).foregroundStyle(.primary)
                                    Spacer()
                                    if selected[question.qid, default: []].contains(choice) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                        TextField(
                            question.choices.isEmpty
                                ? "Your answer" : "Or answer in your own words",
                            text: bindingForFreeText(question.qid), axis: .vertical
                        )
                        .lineLimit(1...3)
                    }
                }
            }
            .disabled(isSubmitting)
            .navigationTitle("Questions (\(request.questions.count))")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip All") { skipAll() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Answer") { submitAll() }
                        .disabled(isSubmitting)
                }
            }
            .onAppear {
                // A reconnect re-presents the card with any answers the
                // server already locked — prefill so they stay editable.
                for (qid, answer) in request.lockedAnswers where !answer.isEmpty {
                    if freeText[qid] == nil { freeText[qid] = answer }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 460, minHeight: 380)
        #endif
    }

    private func bindingForFreeText(_ qid: String) -> Binding<String> {
        Binding(
            get: { freeText[qid] ?? "" },
            set: { freeText[qid] = $0 })
    }

    private func toggle(_ choice: String, for question: ClarifyRequest.Question) {
        var picks = selected[question.qid, default: []]
        if question.multiSelect {
            if !picks.insert(choice).inserted { picks.remove(choice) }
        } else {
            picks = picks.contains(choice) ? [] : [choice]
        }
        selected[question.qid] = picks
    }

    private func composedAnswer(_ question: ClarifyRequest.Question) -> String {
        let picks = selected[question.qid, default: []]
        if !picks.isEmpty { return picks.sorted().joined(separator: ", ") }
        return freeText[question.qid] ?? ""
    }

    /// Lock every question in order; the last lock resolves the batch.
    /// An unanswered question locks as "" (= skip, same as single clarify).
    private func submitAll() {
        guard !isSubmitting else { return }
        isSubmitting = true
        submitError = nil
        Task {
            for question in request.questions {
                let outcome = await controller.respondClarifyQuestion(
                    requestID: request.requestID,
                    questionID: question.qid,
                    answer: composedAnswer(question))
                switch outcome {
                case .progress:
                    continue
                case .completed, .expired:
                    isSubmitting = false
                    if controller.store.pendingClarify == nil { dismiss() }
                    return
                case .failed:
                    isSubmitting = false
                    submitError = controller.errorMessage
                        ?? "The answer didn't reach the server — try again."
                    return
                }
            }
            // Every question locked but the server still reports remaining
            // qids (shouldn't happen — qid mismatch would 4002 as .failed).
            isSubmitting = false
            if controller.store.pendingClarify == nil { dismiss() }
        }
    }

    private func skipAll() {
        guard !isSubmitting else { return }
        isSubmitting = true
        submitError = nil
        Task {
            let outcome = await controller.respondClarify(
                requestID: request.requestID, answer: "")
            isSubmitting = false
            switch outcome {
            case .delivered, .expired:
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
    /// "At the bottom" must clear the transcript content's 12pt bottom
    /// padding: the scroll anchor sits INSIDE the padded LazyVStack, so a
    /// perfect `scrollTo("bottom", anchor: .bottom)` landing reads ~12pt of
    /// remaining distance, never 0.
    @ObservationIgnored static let repinDistance: CGFloat = 16

    private(set) var isPinnedToBottom = true
    /// True while a deferred scroll is queued so extra requests coalesce.
    @ObservationIgnored var scrollQueued = false
    /// True while a settle chain (post-scrollTo landing correction) runs so
    /// concurrent requests don't stack duplicate chains.
    @ObservationIgnored var settleActive = false
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

    func update(bottomDistance distance: CGFloat, contentGrew: Bool = false) {
        if contentGrew { lastContentGrowth = CACurrentMediaTime() }
        bottomDistance = distance
        if distance > Self.unpinDistance {
            // Only a reading the USER caused may release the pin: while a
            // programmatic scroll is in flight (isAutoScrolling) the geometry
            // reports mid-seek positions, and while content is growing the
            // lazy layout re-estimates produce far readings out of thin air.
            // The growth flag alone is not enough — appends re-layout in
            // multiple passes, and a second pass reports a jumped distance
            // with the contentHeight UNCHANGED (verified: tool-row appends
            // unpinned the follow mid-stream) — so any reading within a short
            // cool-down of a growth is still treated as content-driven. A
            // real drag unpins synchronously via the gesture, never here.
            guard !isAutoScrolling, !contentGrew,
                CACurrentMediaTime() - lastContentGrowth > 0.15
            else { return }
            setPinned(false)
        } else if distance < Self.repinDistance, !isDragging {
            isAutoScrolling = false
            setPinned(true)
        }
    }

    @ObservationIgnored private var lastContentGrowth: CFTimeInterval = 0
}

/// Scroll reading pairing the bottom distance with the content height, so
/// the action can tell user scrolls (height unchanged) apart from content
/// growth (height changed) — only the former may release the pin.
private struct BottomGeometry: Equatable {
    var distance: CGFloat
    var contentHeight: CGFloat
}


