#if os(iOS)
    import ChatCore
    import MercuryKit
    import SwiftUI

    /// Mercury Push for the connected server: master switch, per-profile
    /// switches, per-kind preferences, and a test notification.
    struct NotificationSettingsView: View {
        @Environment(AppModel.self) private var model
        @Environment(\.dismiss) private var dismiss
        @State private var busy = false
        @State private var testResult: String?

        private var serverKey: String? { model.endpoint?.key }
        private var profileNames: [String] { model.profiles.map(\.name) }

        var body: some View {
            NavigationStack {
                Form {
                    if let rest = model.connection?.rest, let key = serverKey {
                        let choice = model.push.settings(for: key)
                        Section {
                            Toggle("Notifications", isOn: Binding(
                                get: { choice.enabled },
                                set: { on in run { on
                                    ? await model.push.enable(server: rest, profiles: profileNames)
                                    : await model.push.disable(server: rest, profiles: profileNames) } }))
                            .disabled(busy)
                            if let error = model.push.enableError {
                                Text(error).font(.callout).foregroundStyle(.orange)
                                if model.push.authorization == .denied {
                                    Button("Open Settings") { model.push.openSystemSettings() }
                                }
                            }
                            if let error = model.push.tokenError {
                                Text(error).font(.callout).foregroundStyle(.orange)
                            }
                        } header: {
                            Text(model.endpoint?.displayName ?? "")
                        } footer: {
                            Text("Notifications are delivered through the Mercury Push relay. They carry short generic text, never your conversations.")
                        }

                        if choice.enabled {
                            Section("Profiles") {
                                ForEach(profileNames, id: \.self) { name in
                                    VStack(alignment: .leading) {
                                        Toggle(name, isOn: Binding(
                                            get: { !choice.disabledProfiles.contains(name) },
                                            set: { on in run { await model.push.setProfile(
                                                name, enabled: on, server: rest, profiles: profileNames) } }))
                                        statusText(model.push.profileStatus[name])
                                    }
                                }
                            }
                            Section("Notify me about") {
                                preferenceToggle("Approvals", \.approval, choice, rest)
                                preferenceToggle("Responses", \.responseReady, choice, rest)
                                preferenceToggle("Failed turns", \.turnFailed, choice, rest)
                                preferenceToggle("Delegated tasks", \.taskDone, choice, rest)
                                preferenceToggle("Cron", \.cron, choice, rest)
                            }
                            Section {
                                Button("Send test notification") {
                                    run { testResult = await model.push.sendTest(server: rest) ?? "Sent." }
                                }
                                if let testResult { Text(testResult).font(.callout).foregroundStyle(.secondary) }
                            }
                        }
                        Section {
                            Link("Privacy Policy", destination: MercuryLinks.privacyPolicy)
                        }
                    } else {
                        Text("Connect to a server to set up notifications.")
                    }
                }
                .navigationTitle("Notifications")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task { await model.syncPush() }
            }
        }

        private func run(_ work: @escaping @MainActor () async -> Void) {
            busy = true
            Task {
                await work()
                busy = false
            }
        }

        @ViewBuilder private func statusText(_ status: ProfilePushStatus?) -> some View {
            switch status {
            case .paired?: Text("Paired").font(.caption).foregroundStyle(.secondary)
            case .pairing?: Text("Pairing…").font(.caption).foregroundStyle(.secondary)
            case .error(let message)?: Text(message).font(.caption).foregroundStyle(.red)
            case .off?, nil: EmptyView()
            }
        }

        private func preferenceToggle(
            _ title: String, _ keyPath: WritableKeyPath<PushPreferences, Bool>,
            _ choice: ServerPushSettings, _ rest: HermesRESTClient
        ) -> some View {
            Toggle(title, isOn: Binding(
                get: { choice.preferences[keyPath: keyPath] },
                set: { on in
                    var updated = choice.preferences
                    updated[keyPath: keyPath] = on
                    run { await model.push.setPreferences(updated, server: rest) }
                }))
        }
    }
#endif
