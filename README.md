# Mercury

A native SwiftUI client for [Hermes Agent](https://github.com/NousResearch/hermes-agent) on iOS 17+, macOS 14+, and visionOS 2+. Mercury speaks the same protocol as the official Hermes Desktop app: the `hermes serve` backend's JSON-RPC 2.0 WebSocket gateway at `/api/ws` plus its `/api/*` REST surface.

Built against desktop contract **6** (`DESKTOP_BACKEND_CONTRACT` in `tui_gateway/server.py`).

## Architecture

```
Mercury.xcodeproj              — two targets: the multiplatform app (iPhone/iPad/Mac/Vision)
                                 and MercuryTests, a headless macOS unit-test bundle
MercuryTests/                  — app-layer tests (AppModel glue); Xcode target only, not part
                                 of `swift test` — run with:
                                 xcodebuild test -scheme MercuryTests -destination 'platform=macOS'
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
  Tests/MercuryKitTests/       — protocol-layer tests, incl. real-socket coverage against
                                 hand-rolled loopback HTTP/WebSocket servers (TestServers.swift)
  Tests/ChatCoreTests/         — transcript reducer + hydration tests
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

Live checks below were run against `hermes serve` 0.20.0 in token mode on 2026-08-11 unless noted. The client has since adopted the `hermes serve` 0.20.5 surface (desktop contract 6); those changes are covered by the automated suites and have not been re-verified live.

### Milestone 1 — MercuryKit port
- [x] `swift test` green (141 tests — 95 MercuryKitTests + 46 ChatCoreTests: endpoint parsing, credentials/cookie extraction, payload wrappers, PKCE vectors + live loopback-listener round trips, real-socket networking against loopback HTTP/WebSocket test servers, transcript reducer + hydration).
- [x] App-layer suite (`MercuryTests` Xcode target, AppModel glue) green — not run by `swift test`; run it with `xcodebuild test -scheme MercuryTests -destination 'platform=macOS'`.

### Milestone 2 — connect + browse
- [x] Token-mode connect (pasted dashboard URL auto-lifts `?token=`), auto-reconnect on relaunch from Keychain.
- [x] Both HTTP probe (`/api/profiles/active`) and WS dial succeed before a connection saves.
- [x] Sessions/profiles/projects listed (camelCase `projects.tree` shape); `-32601` fallback code path in place (not exercisable against this backend).
- [x] iOS simulator + macOS verified interactively; visionOS renders the connect flow.

### Milestone 3 — chat v1
- [x] Create → prompt → stream → tool row (collapse to summary+duration) → complete; end-of-turn on `session.info.running == false`; session auto-title.
- [x] Approval card: allow-once and deny both exercised; four-choice derivation.
- [x] Resume with REST hydration; tool rows and reply ordering preserved.
- [ ] Clarify/sudo/secret sheets built and unit-tested; not yet triggered live.

### Milestones 4–6 — polish + resilience
- [x] macOS split view, sidebar selection → resume, rename/pin/delete context menus, workspace `+` buttons, keyboard shortcuts.
- [x] Kill backend mid-turn → banner + backoff → restart → auto re-resume by stored id with context intact (verified with a follow-up turn).
- [x] Revoked token → terminal auth-expired (no retry storm), connect screen with "paste a fresh dashboard URL" message.
- [x] 4403 Host/Origin guard mapped to a terminal, explanatory disconnect.
- [x] Contract-drift notice (v5 server vs v6 build) as a transient, hit-transparent toast.
- [x] PKCE against a real OAuth provider — native `native_pkce` sign-in exercised end to end (loopback listener → code exchange → authenticated WS dial) on 2026-08-20.
- [ ] iOS 10-minute background → foreground poke-reconnect (wired via scenePhase; not soak-tested).
