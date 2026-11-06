import MercuryKit
import SwiftUI

// CredentialSubmitOutcome is defined in Mercury/Voice/CredentialPrompt.swift.
// These sheets are controller-agnostic: Chat and the voice conversation each
// pass closures that deliver the answer and report what happened.

struct SudoSheet: View {
    let request: SudoRequest
    let submit: (String) async -> CredentialSubmitOutcome
    let decline: () async -> CredentialSubmitOutcome
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
                    Button("Decline") { respond(declining: true) }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { respond(declining: false) }
                        .disabled(isSubmitting || password.isEmpty)
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 400, minHeight: 220)
        #endif
    }

    private func respond(declining: Bool) {
        guard !isSubmitting else { return }
        isSubmitting = true
        submitError = nil
        let value = password
        Task {
            let outcome = declining ? await decline() : await submit(value)
            isSubmitting = false
            switch outcome {
            case .done, .stay:
                // The value has served its purpose the moment the RPC
                // settles — clear it BEFORE the dismiss animation, not
                // whenever SwiftUI releases the sheet's state (#19).
                password = ""
                if outcome == .done { dismiss() }
            case .failed(let message):
                // Kept for the retry the sheet is offering.
                submitError = message
            }
        }
    }
}

struct SecretSheet: View {
    let request: SecretRequest
    let submit: (String) async -> CredentialSubmitOutcome
    let decline: () async -> CredentialSubmitOutcome
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
                    Button("Skip") { respond(declining: true) }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { respond(declining: false) }
                        .disabled(isSubmitting || value.isEmpty)
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 400, minHeight: 220)
        #endif
    }

    private func respond(declining: Bool) {
        guard !isSubmitting else { return }
        isSubmitting = true
        submitError = nil
        let answer = value
        Task {
            let outcome = declining ? await decline() : await submit(answer)
            isSubmitting = false
            switch outcome {
            case .done, .stay:
                // Clear BEFORE the dismiss animation, not whenever SwiftUI
                // releases the sheet's state (#19).
                value = ""
                if outcome == .done { dismiss() }
            case .failed(let message):
                // Kept for the retry the sheet is offering.
                submitError = message
            }
        }
    }
}
