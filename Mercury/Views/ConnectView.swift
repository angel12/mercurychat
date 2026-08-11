import MercuryKit
import SwiftUI

/// First-run / connect screen: server field (accepts host, host:port, full
/// URL, or a pasted dashboard URL with ?token=), token secure field, recent
/// servers, and a swap to username/password when the server is gated.
struct ConnectView: View {
    @Environment(AppModel.self) private var model

    @State private var serverInput = ""
    @State private var tokenInput = ""
    @State private var username = ""
    @State private var password = ""
    @State private var connecting = false
    @State private var showHelp = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                if let pending = model.pendingPasswordLogin {
                    passwordForm(pending)
                } else {
                    serverForm
                }

                if let error = model.connectError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }

                if !model.savedServers.isEmpty, model.pendingPasswordLogin == nil {
                    recentServers
                }
            }
            .padding()
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showHelp) { ConnectHelpView() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Mercury")
                .font(.largeTitle.bold())
            Text("Connect to a Hermes Agent server")
                .foregroundStyle(.secondary)
        }
        .padding(.top, 32)
    }

    private var serverForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("127.0.0.1:9119 or paste the dashboard URL", text: $serverInput)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                .onChange(of: serverInput) { _, newValue in
                    // Pasting a dashboard URL auto-fills the token field.
                    if let parsed = try? ServerEndpoint.parse(newValue),
                        let embedded = parsed.embeddedToken
                    {
                        tokenInput = embedded
                    }
                }
                .onSubmit(connect)

            SecureField("Session token (from the dashboard URL)", text: $tokenInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connect)

            Text("Gated servers with a username & password skip this — just Connect.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("How do I connect?") { showHelp = true }
                    .buttonStyle(.borderless)
                Spacer()
                Button(action: connect) {
                    if connecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(serverInput.isEmpty || connecting)
            }
        }
    }

    private func passwordForm(_ pending: AppModel.PendingPasswordLogin) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This server uses \(pending.providerDisplayName) authentication.")
                .font(.callout)

            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if !os(macOS)
                    .textInputAutocapitalization(.never)
                #endif
                .onAppear {
                    if username.isEmpty { username = pending.prefillUsername }
                }

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(signIn)

            HStack {
                Button("Back") { model.cancelPasswordLogin() }
                    .buttonStyle(.borderless)
                Spacer()
                Button(action: signIn) {
                    if connecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Sign In")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(username.isEmpty || password.isEmpty || connecting)
            }
        }
    }

    private var recentServers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent servers")
                .font(.headline)
            ForEach(model.savedServers) { server in
                HStack {
                    Button {
                        Task {
                            connecting = true
                            defer { connecting = false }
                            if let parsed = try? ServerEndpoint.parse(server.urlString) {
                                await model.connect(
                                    endpoint: parsed.endpoint,
                                    credentials: model.savedCredentials(for: parsed.endpoint))
                            }
                        }
                    } label: {
                        Label(server.urlString, systemImage: "server.rack")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        model.forgetServer(server)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Forget this server and delete its stored credentials")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func connect() {
        guard !serverInput.isEmpty, !connecting else { return }
        Task {
            connecting = true
            defer { connecting = false }
            await model.connect(input: serverInput, token: tokenInput)
        }
    }

    private func signIn() {
        guard !username.isEmpty, !password.isEmpty, !connecting else { return }
        Task {
            connecting = true
            defer { connecting = false }
            await model.signIn(username: username, password: password)
            password = ""
        }
    }
}

/// Connection recipes, mirroring the shapes that actually work.
struct ConnectHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                recipe(
                    "Same Mac",
                    "Run `hermes serve` on this Mac, then paste the dashboard URL it prints (it contains ?token=…). The token changes on every backend restart.")
                recipe(
                    "iPhone/iPad → Mac over Tailscale",
                    "Run `tailscale serve` on the Mac to proxy the Hermes port — it forwards from loopback on the host, so token mode keeps working. Then connect to the Mac's tailnet name.")
                recipe(
                    "SSH tunnel",
                    "From a machine that can reach the Mac: `ssh -L 9119:127.0.0.1:9119 you@mac`, then connect to localhost:9119 with the token.")
                recipe(
                    "Why can't I reach a remote server directly?",
                    "A backend bound to 127.0.0.1 refuses non-local peers. Either use a tunnel that presents a loopback peer, or run the backend with a non-loopback bind — that enables gated mode, and Mercury signs in with a username & password when the server has one configured.")
            }
            .navigationTitle("How do I connect?")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 440, minHeight: 380)
        #endif
    }

    private func recipe(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(.init(body)).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
