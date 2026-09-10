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
    /// Set when this chat is a bot's canonical Bot Chat: pins the profile
    /// (create mode would otherwise fall back to the sidebar's selected
    /// profile), captions the chat with the bot's name, and arms the
    /// never-fork composer policy.
    var botContext: BotChatContext?

    struct BotChatContext {
        var profile: String
        var displayTitle: String
    }

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
                ChatContentView(
                    controller: controller, activeSheet: $activeSheet,
                    titleOverride: botContext?.displayTitle)
            } else {
                ProgressView("Opening session…")
            }
        }
        .task(id: sessionKey) {
            // nil = disconnected before this body ran: keep the progress
            // placeholder; RootView swaps to the connect screen.
            guard let chat = model.openChat(profile: profileForMode) else { return }
            chat.isCanonicalBotChat = botContext != nil
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
        if let botContext { return botContext.profile }
        if case .resume(let session) = mode { return session.profile }
        return nil
    }
}

/// Rendered once the controller exists.
private struct ChatContentView: View {
    @Bindable var controller: ChatController
    @Binding var activeSheet: ChatView.ChatSheet?
    /// A canonical Bot Chat is captioned with its bot's name (desktop
    /// parity) instead of the stored session title.
    var titleOverride: String?
    @State private var composerText = ""
    @State private var renameShown = false
    @State private var renameText = ""
    /// Scroll-pinning bookkeeping. Every field is read and written only inside
    /// gesture/preference/onChange callbacks, never in `body` — so it lives in
    /// a plain class on purpose. As `@State` value fields, the per-frame
    /// writes (bottom distance changes on every scrolled point) invalidated
    /// the whole transcript body 120×/s, which showed up as app-wide lag.
    @State private var scroll = TranscriptScrollState()
    /// Staged attachments live one level ABOVE the composer so the whole chat
    /// surface — transcript included — can be a drop target (#3). The composer
    /// still owns every other interaction with them.
    @State private var attachments = ComposerAttachments()
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            transcript
            promptCards
            ComposerView(
                controller: controller, text: $composerText, attachments: attachments)
        }
        .overlay { dropTarget }
        .animation(.easeInOut(duration: 0.12), value: isDropTargeted)
        // The drop destination sits on the WHOLE chat surface, not just the
        // composer strip: dropping a file anywhere in the window attaches it.
        // Finder/Files deliver file URLs of ANY type (filename preserved, read
        // under security scope, classified by kind), other apps deliver raw
        // image Data — `onDrop` takes both content types at once. One
        // destination, not two: stacked `.dropDestination` modifiers on the
        // same view register a single delegate, so the second would shadow
        // the first.
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            attachments.loadProviders(providers)
            return !providers.isEmpty
        }
        .navigationTitle(titleOverride ?? controller.store.title ?? "Session")
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

    /// Hover affordance for an in-flight image drag.
    ///
    /// It earns its keep twice. Besides saying where to let go, it is
    /// HIT-TESTABLE and covers the message field, so once a drag has entered
    /// any non-field pixel of the window the field editor never sees the drop
    /// — without it, AppKit's built-in NSTextField file-URL handling wins
    /// inside the field's bounds and inserts the file PATH as plain text.
    ///
    /// RESIDUAL (macOS, accepted): a drag that enters the window *directly*
    /// over the message field drops into the field editor before this overlay
    /// can appear, and still inserts the path as text. AppKit's dragging
    /// destination on the field editor is not reachable from SwiftUI; closing
    /// that hole needs an NSViewRepresentable text view.
    @ViewBuilder
    private var dropTarget: some View {
        if isDropTargeted {
            ZStack {
                Rectangle()
                    .fill(.background.opacity(0.7))
                Label("Drop files to attach", systemImage: "doc.badge.plus")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        .tint, style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                    )
                    .padding(8)
            )
            .transition(.opacity)
            .accessibilityLabel("Drop files to attach")
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

// ComposerAttachments lives in Mercury/ComposerAttachments.swift and
// ImagePasteboardReader in Mercury/ImagePasteboardReader.swift (both kept out
// of ChatView.swift so MercuryTests can compile them without SwiftUI).

private struct ComposerView: View {
    @Bindable var controller: ChatController
    @Binding var text: String
    /// Owned by `ChatContentView` so window-wide drops can reach it (#3).
    @Bindable var attachments: ComposerAttachments
    @FocusState private var focused: Bool
    @State private var showingFileImporter = false
    #if os(iOS) || os(visionOS)
        @State private var photoSelection: [PhotosPickerItem] = []
        @State private var showingPhotoPicker = false
    #endif

    /// Preparation is asynchronous (#2), so Send has to WAIT for it: sending
    /// mid-preparation submitted the caption alone and left the image in the
    /// tray for the next message. The button showing disabled for the
    /// fraction of a second an encode takes is the intended behaviour.
    private var canSend: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.items.isEmpty) && !attachments.isBusyPreparing
    }

    var body: some View {
        VStack(spacing: 6) {
            if let attachmentError = attachments.error {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !attachments.items.isEmpty {
                AttachmentTray(attachments: $attachments.items)
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
                    // ⌘V is a MENU key equivalent (#4): AppKit offers it to
                    // Edit ▸ Paste in `NSApp.sendEvent` before the key event
                    // ever reaches the responder chain, so `.onKeyPress` is
                    // too late. A Finder ⌘C carries the filename as
                    // `public.utf8-plain-text`, which makes the field editor
                    // a valid `paste:` target — the menu fires, the filename
                    // is inserted, and the reader never runs. (A screenshot
                    // carries no text, the menu item validates disabled, and
                    // `.onKeyPress` used to see the event — which is why only
                    // the FILE case broke.) `performKeyEquivalent` on a view
                    // in the key window's hierarchy runs BEFORE the menu, so
                    // the catcher gets first refusal; it declines whenever
                    // the pasteboard held nothing attachable and the normal
                    // text paste proceeds untouched.
                    .background(
                        PasteKeyCatcher(isActive: focused) { attachments.pasteAttachments() })
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
            // Secondary path only: this fires for Edit ▸ Paste when focus is
            // NOT in the message field (e.g. on the send button). The common
            // case — focus in the field — is handled by `PasteKeyCatcher`
            // above, which consumes the key equivalent before the menu.
            .onPasteCommand(of: [.fileURL, .image]) { providers in
                // Any file, not just images — `loadProviders` classifies by
                // kind. Deliberately not `[.item]`: that would swallow plain
                // text pastes that belong in the message field.
                attachments.loadProviders(providers)
            }
        #endif
        // Drops are handled window-wide by ChatContentView, not here — the
        // composer is a thin strip and dropping onto the transcript is what
        // people actually do.
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            // One importer result = one batch: clear the previous error line
            // once here, never per successful item, and reserve the whole
            // batch before the first read starts.
            attachments.beginBatch()
            let granted = attachments.reserveSlots(urls.count)
            guard granted > 0 else { return }
            // Sequential await: reads and encodes run off the MainActor but
            // the tray still fills in the order the user picked.
            Task {
                for url in urls.prefix(granted) {
                    await attachments.addReserved(contentsOf: url)
                }
            }
        }
        #if os(iOS) || os(visionOS)
            // Presented from the composer, not from inside the attach menu —
            // PhotosPicker runs out of process, so no usage description needed.
            .photosPicker(
                isPresented: $showingPhotoPicker, selection: $photoSelection,
                // Only as many as the tray can still hold — in-flight
                // preparations included — so the picker can't hand back items
                // that `add` will silently reject. Never 0: that means
                // "unlimited" to PhotosPicker; the menu item is disabled at
                // cap instead.
                maxSelectionCount: max(1, attachments.availableSlots),
                matching: .images
            )
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                photoSelection = []
                attachments.beginBatch()
                // Reserved BEFORE the first `loadTransferable`: fetching an
                // iCloud photo takes seconds, and leaving that window
                // unaccounted for re-opens the send race — the caption would
                // go out alone and the photo land in the next message.
                let granted = attachments.reserveSlots(items.count)
                guard granted > 0 else { return }
                Task {
                    for item in items.prefix(granted) {
                        // The reservation is this item's until `addReserved`
                        // takes ownership of it; every other way out of the
                        // iteration — nil transferable, a throw, cancellation
                        // — releases it here.
                        var handedOff = false
                        defer { if !handedOff { attachments.endPreparation() } }
                        // A picked item can still fail to load (an iCloud
                        // photo that never downloaded, a corrupt asset) —
                        // silence there looks like the picker did nothing.
                        do {
                            guard let data = try await item.loadTransferable(type: Data.self)
                            else {
                                attachments.error = "Couldn't load photo."
                                continue
                            }
                            handedOff = true
                            await attachments.addReserved(data: data, name: nil)
                        } catch {
                            attachments.error = "Couldn't load photo."
                        }
                    }
                }
            }
        #endif
    }

    @ViewBuilder private var attachMenu: some View {
        Menu {
            #if os(iOS) || os(visionOS)
                // A `PhotosPicker` placed inside a `Menu` never presents: its
                // presentation anchor dies with the menu dismissal. Flip a flag
                // and let the composer's `.photosPicker` modifier present it.
                Button {
                    showingPhotoPicker = true
                } label: {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }
                // The picker needs a selection budget of at least 1; at cap —
                // in-flight preparations counted — there is none, so don't
                // offer it. (The other paths funnel through `add`'s cap check
                // and surface its error line.)
                .disabled(attachments.availableSlots <= 0)
                Button {
                    let images = (UIPasteboard.general.images ?? []).compactMap {
                        $0.jpegData(compressionQuality: 0.9)
                    }
                    guard !images.isEmpty else { return }
                    attachments.beginBatch()
                    let granted = attachments.reserveSlots(images.count)
                    guard granted > 0 else { return }
                    Task {
                        for data in images.prefix(granted) {
                            await attachments.addReserved(data: data, name: nil)
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
        .help("Attach files")
    }

    private func send() {
        let message = text
        let outgoing = attachments.items
        // Same gate as `canSend` — ⌘⏎ and ⏎ reach `send()` directly.
        guard !attachments.isBusyPreparing,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !outgoing.isEmpty
        else { return }
        text = ""
        attachments.clear()
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

#if os(macOS)
    /// Gives the composer first refusal on ⌘V, ahead of Edit ▸ Paste.
    ///
    /// `NSWindow` offers a key equivalent to its content view hierarchy
    /// before the main menu sees it, so an otherwise invisible view in the
    /// composer's background is the only place a SwiftUI `TextField` can beat
    /// its own field editor to the paste. Scoped to the window (unlike an
    /// `NSEvent` local monitor, which is app-wide) and gated on focus, so a
    /// ⌘V anywhere else in Mercury is untouched. Out of the IME marked-text
    /// path the old `onKeyPress` comment worried about: only a
    /// command-modified key equivalent ever reaches it.
    private struct PasteKeyCatcher: NSViewRepresentable {
        /// Only while the message field holds focus — otherwise the paste
        /// belongs to whatever else is first responder, and Edit ▸ Paste
        /// still reaches the composer's `.onPasteCommand`.
        var isActive: Bool
        /// True when the paste was consumed as an attachment.
        var handlePaste: @MainActor () -> Bool

        final class View: NSView {
            var isActive = false
            var handlePaste: (@MainActor () -> Bool)?

            override func performKeyEquivalent(with event: NSEvent) -> Bool {
                guard isActive,
                    event.modifierFlags.contains(.command),
                    !event.modifierFlags.contains(.option),
                    !event.modifierFlags.contains(.control),
                    event.charactersIgnoringModifiers == "v"
                else { return false }
                return handlePaste?() ?? false
            }
        }

        func makeNSView(context: Context) -> View {
            let view = View()
            view.isActive = isActive
            view.handlePaste = handlePaste
            return view
        }

        func updateNSView(_ view: View, context: Context) {
            view.isActive = isActive
            view.handlePaste = handlePaste
        }
    }
#endif

/// Horizontal strip of staged attachments with per-item remove.
private struct AttachmentTray: View {
    @Binding var attachments: [PendingAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if attachment.kind == .image {
                                AttachmentThumbnail(data: attachment.thumbnail ?? attachment.data)
                            } else {
                                // PDFs and plain files stage without thumbnail
                                // bytes — a kind icon over the name instead.
                                VStack(spacing: 4) {
                                    Image(
                                        systemName: attachment.kind == .pdf
                                            ? "doc.richtext" : "doc"
                                    )
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    Text(attachment.filename)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .padding(.horizontal, 4)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.quaternary)
                            }
                        }
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


