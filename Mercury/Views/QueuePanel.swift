import ChatCore
import MercuryKit
import SwiftUI

/// The chat's shared queue on a session authority (hermes v0.23 gateway
/// listener), above the composer: every prompt waiting for the running turn,
/// whichever app or bot queued it. Row actions are the ones the owner offers
/// for that row (`QueuedPrompt.controls`), as Desktop's queue panel does
/// (`apps/desktop/src/app/chat/composer/queue-panel.tsx`): Steer now, Edit
/// and Remove. Shown only while something waits.
struct QueuePanel: View {
    @Bindable var controller: ChatController
    @State private var editing: QueuedPrompt?

    private var rows: [QueuedPrompt] {
        controller.store.queue.filter { $0.status == .queued || $0.status == .unknown }
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(rows.count == 1 ? "1 queued" : "\(rows.count) queued", systemImage: "tray.full")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(rows) { row in
                    QueueRow(
                        row: row,
                        isMine: controller.store.echoID(forAdmission: row.admissionID) != nil,
                        canSteer: row.controls.contains(.steer) && controller.store.running,
                        steer: { Task { await controller.steerQueued(row) } },
                        edit: { editing = row },
                        remove: { Task { await controller.removeQueued(row) } })
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            .sheet(item: $editing) { row in
                QueueEditSheet(controller: controller, row: row)
            }
        }
    }
}

private struct QueueRow: View {
    let row: QueuedPrompt
    let isMine: Bool
    let canSteer: Bool
    let steer: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.text.isEmpty ? "(attachment)" : row.text)
                    .font(.callout)
                    .lineLimit(2)
                if row.status == .unknown {
                    Text("Lost when the server restarted")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !isMine {
                    Text("Queued by another app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.status == .queued {
                if canSteer {
                    Button(action: steer) {
                        Image(systemName: "arrow.uturn.right.circle")
                    }
                    .help("Send now, into the running turn")
                    .accessibilityLabel("Steer now")
                }
                if row.controls.contains(.replace) {
                    Button(action: edit) {
                        Image(systemName: "pencil.circle")
                    }
                    .help("Edit")
                    .accessibilityLabel("Edit queued prompt")
                }
            }
            Button(role: .destructive, action: remove) {
                Image(systemName: "xmark.circle")
            }
            .help("Remove from the queue")
            .accessibilityLabel("Remove from the queue")
        }
        .font(.title3)
        .buttonStyle(.borderless)
        .frame(minHeight: 44)
    }
}

/// Edit a queued prompt in place. The owner may already have started it;
/// then the edit is refused and the text stays here so nothing typed is lost.
private struct QueueEditSheet: View {
    @Bindable var controller: ChatController
    let row: QueuedPrompt
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var error: String?
    @State private var saving = false

    init(controller: ChatController, row: QueuedPrompt) {
        self.controller = controller
        self.row = row
        _text = State(initialValue: row.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Prompt", text: $text, axis: .vertical)
                        .lineLimit(3...12)
                } footer: {
                    Text("Saving puts the edited prompt at the back of the queue.")
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(saving)
            .navigationTitle("Edit Queued Prompt")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            error = await controller.editQueued(row, text: text)
                            saving = false
                            if error == nil { dismiss() }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 260)
        #endif
    }
}
