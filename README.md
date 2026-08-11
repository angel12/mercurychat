# Mercury

A native SwiftUI client for [Hermes Agent](https://github.com/NousResearch/hermes-agent) on iOS 17+, macOS 14+, and visionOS 2+. Mercury speaks the same protocol as the official Hermes Desktop app: the `hermes serve` backend's JSON-RPC 2.0 WebSocket gateway at `/api/ws` plus its `/api/*` REST surface.

Built against desktop contract **6** (`DESKTOP_BACKEND_CONTRACT` in `tui_gateway/server.py`).

## Architecture

```
Mercury.xcodeproj              — one multiplatform app target (iPhone/iPad/Mac/Vision)
Packages/MercuryCore/
  Sources/MercuryKit/          — protocol layer (Foundation + Security + os + CryptoKit only)
    ServerEndpoint             — URL parsing/building; ?token= extraction from pasted dashboard URLs
    ServerCredentials          — token-mode vs password-mode credentials; keychain-codable
    KeychainTokenStore         — per-endpoint credential storage (kSecClassGenericPassword)
    HermesAuthenticator        — REST headers, per-dial WS auth (ticket minting), 401→refresh,
                                 password login (Set-Cookie parsing), native PKCE (RFC 8252)
    GatewayClient              — one JSON-RPC 2.0 socket generation: dial → gateway.ready → use → discard
    HermesConnection           — supervisor: reconnect w/ full-jitter backoff, stable event stream
    RESTClient                 — /api/* surface incl. transcript hydration (GET /api/sessions/{id}/messages)
    SessionAPI                 — typed RPC wrappers (create/resume/prompt/interrupt/steer/redirect/
                                 title/delete/branch/approval/clarify/sudo/secret/model.options)
    GatewayEvent, JSONValue,   — dynamic wire model; typed failable payload wrappers
    Models, HermesError
  Sources/ChatCore/            — platform-free transcript reducer
    TranscriptStore            — @MainActor @Observable; events + hydration → ordered items
    TranscriptItem             — user / assistant (markdown+reasoning) / tool row / notice
```

The protocol layer is lifted nearly verbatim from HermesVoice's `HermesKit` (a working Swift 6 client of the same protocol) and extended with transcript hydration, the fuller desktop event set, session-management RPCs, and native-PKCE OAuth.

## Two-ID session model

`session_id` is the **runtime** id (8 hex chars, recycled on backend restart) used for `prompt.submit`/`session.interrupt` and event filtering. `stored_session_id` (aka `session_key`) is the **durable** DB id used for `session.resume` and REST hydration. After every reconnect, re-resume by stored id; re-anchor the stored id from the resume result's `resumed`/`session_key`.

## Deviations from the desktop app / spec notes

- `sudo.respond` takes a `password` field and `secret.respond` takes a `value` field (not `text`) — verified against `tui_gateway/methods_prompt.py`. Late responds return `{"status":"expired"}`.
- Subagent activity (`subagent.start/tool/complete` on the parent session) is flattened to labeled tool rows in v1, not rendered as a nested spawn tree.
- One socket per connection; profile scoping via the `profile` param (no per-profile socket pooling).
- Voice (`/api/audio/*`) is out of v1 scope; the transport keeps `speakStreamURL`/`transcribe` available for a later graft.

## Connection recipes

- **Same Mac (token mode):** run `hermes serve`, paste the dashboard URL (the `?token=` is lifted automatically). The token dies with the server process.
- **Tailscale:** `tailscale serve` on the Mac presents a loopback peer, so token mode works across devices.
- **SSH tunnel:** `ssh -L 9119:127.0.0.1:9119 user@mac` then connect to `localhost:9119` with the token.
- **Gated server (non-loopback bind):** username/password or PKCE sign-in; WS dials mint a single-use 30 s ticket per attempt.

## Manual verification checklist

### Milestone 1 — MercuryKit port
- [x] `swift test` green (53 tests: endpoint parsing, credentials/cookie extraction, payload wrappers, PKCE vectors, transcript reducer + hydration).

### Milestone 2 — connect + browse
- [ ] Token-mode connect against local `hermes serve` (paste URL, auto-lifted token).
- [ ] Both HTTP probe (`/api/profiles/active`) and WS dial must succeed before a connection saves.
- [ ] Sessions/profiles/projects listed; `-32601` on `projects.*` degrades to flat grouping.
- [ ] Runs on iOS simulator, macOS, visionOS simulator.

### Milestone 3 — chat v1
- [ ] Create → prompt → stream → tool row → complete, end-of-turn on `session.info.running == false`.
- [ ] Interrupt mid-turn; approval + clarify cards; transcript hydration on resume.
- [ ] Kill backend mid-turn → backoff reconnect → resume by stored id renders `inflight`.
