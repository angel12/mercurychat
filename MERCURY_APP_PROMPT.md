# Mercury — a native Swift client for Hermes Agents

You are building **Mercury**, a native SwiftUI chat client for [Hermes Agent](https://github.com/NousResearch/hermes-agent) targeting **iOS 17+ (iPhone + iPad), macOS 14+, and visionOS 2+** from a single multiplatform Xcode project. Mercury connects to Hermes Agents running on local or remote systems using **exactly the same connection path as the official Hermes Desktop app** (Electron): the `hermes serve` backend's JSON-RPC 2.0 WebSocket gateway at `/api/ws` plus its `/api/*` REST surface. It should feel like Hermes Desktop — streaming chat, live tool activity, approvals, session/project browsing — rendered natively on each Apple platform.

**Do not** build against the OpenAI-compatible `api_server` adapter or the ACP stdio adapter. The desktop path is `/api/ws`.

---

## 0. Reference material (consult these, in this order)

1. **`http://10.0.1.72:3000/spencer/hermes-voice`** (self-hosted Gitea; also on disk at `/Users/spencermcguire/Coding/Claude_Hermes_Voice_Swift`) — **HermesVoice**, a working Swift 6 voice client built against this exact protocol. Its `Packages/HermesVoiceCore/Sources/HermesKit/` module (12 files: `ServerEndpoint`, `HermesAuthenticator`, `ServerCredentials`, `KeychainTokenStore`, `GatewayClient`, `HermesConnection`, `RESTClient`, `HermesError`, `JSONValue`, `GatewayEvent`, `Models`, `SessionAPI`) is UI-free, platform-free (Foundation + Security + os only), actor-based under Swift 6 strict concurrency, and covered by unit tests. **Lift it nearly verbatim as Mercury's protocol layer** — add `.visionOS(.v2)` to the package platforms, rename as you see fit, and extend it per §3 below. Its `HERMES_VOICE_APP_PROMPT.md` and README also document the protocol and its sharp edges.
2. **`https://github.com/NousResearch/hermes-agent`** — a git clone lives at `/Users/spencermcguire/Coding/Mercury/hermes-agent` (v0.20.0, cloned 2026-08-11; run `git pull` there before starting work so you build against the current backend). This is the backend and the Electron desktop app. Key files:
   - `apps/shared/src/json-rpc-gateway.ts` — the canonical ~430-line WS client state machine.
   - `apps/desktop/src/app/session/hooks/use-message-stream/gateway-event.ts` — the definitive event→UI reducer (1237 lines); mirror its handling.
   - `apps/desktop/src/types/hermes.ts` — TS wire types.
   - `apps/desktop/electron/connection-config.ts`, `apps/shared/src/websocket-url.ts` — connection descriptors and WS URL/auth rules.
   - `tui_gateway/server.py`, `tui_gateway/ws.py`, `tui_gateway/methods_*.py` — the server side of every RPC and event.
   - `hermes_cli/dashboard_auth/routes.py` — auth endpoints (password login, native PKCE, ws-ticket).
   - `scripts/iso-certify.py:212-260` — a 50-line working Python WS client (connect → `gateway.ready` → `session.create` → `prompt.submit` → `message.complete`).
   - `apps/desktop/README.md`, `apps/desktop/AGENTS.md`, `docs/session-lifecycle.md`, `docs/streaming-tts.md`, `docs/profile-routing.md`.

The facts in §1–§2 below were verified against those sources. Treat them as the contract; when in doubt, the backend source wins.

---

## 1. The connection contract (verified facts)

### 1.1 Server and transports

- The agent backend is **`hermes serve`** — a FastAPI/uvicorn process (`hermes_cli/web_server.py`). Default bind `127.0.0.1:9119`; `--port 0` = OS-assigned, announced on stdout as `HERMES_BACKEND_READY port=N` (legacy: `HERMES_DASHBOARD_READY port=N`).
- One server, the surfaces Mercury uses:
  - **`/api/ws`** — JSON-RPC 2.0 over WebSocket text frames. The chat transport.
  - **`/api/*`** — REST (JSON). Status, auth, session lists, transcript hydration, profiles, audio.
  - **`/api/audio/speak-stream`** — WebSocket streaming TTS (only if/when voice is added; §7).
- The server is plain HTTP; `https`/`wss` appear only behind a TLS-terminating proxy. Derive `ws`/`wss` from the base URL scheme. Path prefixes must be preserved (`https://host/hermes` → `wss://host/hermes/api/ws`).
- Contract version: `session.create`/`session.info` results carry `info.desktop_contract` (currently **6**; check `DESKTOP_BACKEND_CONTRACT` in `tui_gateway/server.py` for the value at build time). Surface a non-blocking warning when it differs from the version Mercury was built against.

### 1.2 Authentication — two mutually exclusive modes, chosen by the server's bind address

`GET /api/status` (public, unauthenticated) returns `auth_required`, `auth_providers` (e.g. `["basic"]`, `["nous"]`), and `auth_flows` (`["cookie"]` and/or `["cookie","native_pkce"]`). Branch on it.

**Mode A — loopback bind (token mode, `auth_required: false`):**
- WS: `?token=<session token>` query param.
- REST: header `X-Hermes-Session-Token: <token>`.
- The token is `HERMES_DASHBOARD_SESSION_TOKEN` env if set, else random per boot — **it dies with the server process**. The user pastes it (or a full dashboard URL containing `?token=`).
- The server also enforces that the *peer IP* is loopback, so token mode from another device requires a tunnel that presents a loopback peer (SSH tunnel, `tailscale serve`).

**Mode B — non-loopback bind (gated, `auth_required: true`):** `?token=` is unconditionally rejected. Sign in first:
- **Username/password** (provider with `supports_password: true`): `POST {base}/auth/password-login` with `{"provider","username","password"}`. Tokens arrive as **`Set-Cookie` headers, not the body** — parse cookies named `hermes_session_at` / `hermes_session_rt`, trying `__Host-`, `__Secure-`, then bare prefixes. Access token ~15 min; refresh token 24 h rotating. Rate limit: 10 attempts/60 s per IP (429).
- **Native OAuth (RFC 8252 PKCE)** — the proper native-app flow, requires `native_pkce` in `auth_flows`:
  1. Open the system browser at `GET {base}/auth/native/authorize?provider=<p>&code_challenge=<S256>&code_challenge_method=S256&redirect_uri=http://127.0.0.1:<port>/cb&state=<csrf>` (S256 mandatory; redirect URI must be loopback — catch it on a local listener, or use `ASWebAuthenticationSession` if the server accepts its scheme; verify against `routes.py`).
  2. `POST {base}/auth/native/token` `{"code","code_verifier"}` → `{"access_token","refresh_token","token_type":"Bearer","expires_at","provider","user_id"}` — no cookies involved.
- Either way, REST then carries `Authorization: Bearer <access_token>`; rotate via `POST {base}/auth/native/refresh` `{"refresh_token","provider"}`; a 401 on refresh means the session is dead — re-prompt sign-in, don't redial.
- **WebSocket auth when gated**: mint a ticket **immediately before every dial** — `POST {base}/api/auth/ws-ticket` → `{"ticket","ttl_seconds":30}` (single-use, 30 s TTL), then dial `wss://…/api/ws?ticket=<ticket>`. Never reuse a WS URL in gated mode.
- Optional identity: `GET /api/auth/me`.

**Request guards (both modes):** the `Host` header must match the bound host — dial the server by exactly the host it bound to. If URLSession sends an `Origin`, it must be `http(s)://<same host:port>`; omitting Origin is fine (non-web origins pass). Violations close with **4403**; bad/expired credentials close with **4401** (treat as re-auth, not retry).

**Credential hygiene:** use a **cookie-free URLSession** for all auth’d traffic (`httpShouldSetCookies = false`, cookie policy `.never`) so a login `Set-Cookie` can never silently shadow the Bearer header. Store credentials only in the Keychain (`kSecClassGenericPassword`, account = the endpoint key `scheme://host:port`, `AfterFirstUnlock`). Non-secret prefs go to UserDefaults/`@AppStorage`.

### 1.3 JSON-RPC framing over `/api/ws`

- Text frames, JSON-RPC 2.0. Client requests use monotonically increasing ids (Desktop uses integers): `{"jsonrpc":"2.0","id":1,"method":"session.create","params":{…}}` → `{"jsonrpc":"2.0","id":1,"result":{…}}` or `{"…","error":{"code":4009,"message":"session busy"}}`.
- Server events are id-less frames: `{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"a1b2c3d4","payload":{…}}}`. Dispatch rule: `id` present → resolve a pending call; else `method == "event"` && `params.type` present → event; else ignore.
- **The server speaks first**: after accept it sends a `gateway.ready` event (payload includes `change_events: true`, meaning `sessions.changed`/`pet.changed`/etc. broadcasts exist so polling can be a slow backstop). No client hello. Await `gateway.ready` before declaring the connection ready.
- Tolerate huge frames (set `maximumMessageSize` ≥ 64 MiB) and **no read timeout** — the server disables WS pings on loopback binds and a busy turn can be silent for minutes. Quiet ≠ dead.
- Reconnect is the client's job: full-jitter exponential backoff (`random(0…min(15, 0.3·2^attempt))` seconds), poked immediately on scene-activation / network-path change. One `GatewayClient` per dial; a supervisor actor owns the generation loop (copy `HermesConnection` from HermesVoice).

### 1.4 The two-ID session model (never conflate them)

- `session_id` — **runtime** id (8 hex chars, in-memory, recycled on backend restart). Used for `prompt.submit`, `session.interrupt`, and to filter streaming events.
- `stored_session_id` (aka `session_key`) — **durable** id (the state.db row). Used for `session.resume`, navigation, and REST transcript hydration.
- `session.resume` returns a **new** runtime id and names the durable id `resumed`/`session_key` — re-anchor your stored id from those (compression-continuation chains are followed to a live tip). After every reconnect, re-resume by stored id; cross-profile resume requires passing the row's owning `profile`.

### 1.5 Core RPC surface (what Mercury v1 needs)

| Method | Params / notes |
|---|---|
| `session.create` | `{cols: 96, source: "desktop", cwd?, profile?, model?, provider?, title?}` → `{session_id, stored_session_id, info:{…, desktop_contract, lazy}}`. Cheap — no DB row until first prompt. |
| `session.resume` | `{session_id: <stored>, cols, source, omit_messages: true, profile?}`, timeout 120 s → new runtime id + `resumed`/`session_key`, `running`, `inflight` (turn that was streaming when the socket dropped — render it), `queued`, `auto_continue`. Hydrate the transcript via REST in parallel (that's why `omit_messages: true`). |
| `prompt.submit` | `{session_id, text, queued?, interrupted?}` → returns `{"status":"streaming"}` immediately; **completion arrives only via events**. Use a very long timeout (1800 s). Submitting while busy queues/interrupts rather than erroring. |
| `session.interrupt` | `{session_id}` → `{"status":"interrupted"}`. |
| `session.steer` / `session.redirect` | `{session_id, text}` — non-destructive mid-turn nudge / redirection. Nice-to-have. |
| `session.close` | verify `result.closed == true`; may come back unconfirmed. |
| `session.title`, `session.delete`, `session.branch` | sidebar actions. |
| `approval.respond` | `{session_id, choice}` where choice ∈ `once/session/always/deny`. |
| `clarify.respond` | `{request_id, answer}` — keyed by request_id, **not** session. Same pattern for `sudo.respond`/`secret.respond` (`text` field). Late answers return `{"status":"expired"}`, not an error. |
| `projects.tree`, `projects.project_sessions` | workspace browser. Older backends lack these — on `rpcError(-32601)` degrade to grouping the flat session list by `gitRepoRoot ?? cwd` (HermesVoice has this logic). |
| `model.options` | populate a model picker (stretch). |

REST endpoints v1 uses: `GET /api/health`, `GET /api/status`, `GET /api/profiles` (slow — 60 s timeout, load independently), `GET /api/profiles/active` (cheap authed probe before opening the socket), `GET /api/sessions?limit=&offset=&order=recent` (limit cap 100), `GET /api/profiles/sessions?profile=`, and **`GET /api/sessions/{id}/messages?limit=&offset=&profile=`** for transcript hydration (≤500/page; note the gateway resume path calls the row id `row_id` while REST calls it `id` — read both).

### 1.6 The turn event stream (what the chat view renders)

Ordered per turn (deltas are batch-coalesced server-side ~33 ms; a non-streaming frame always flushes ahead, so arrival order is trustworthy — **process events serially**):

```
message.start                 {} — open an assistant bubble
reasoning.delta / thinking.delta   {text} — collapsible "thinking" section
message.delta                 {text, rendered} — append
tool.generating               {name} — transient "preparing…" hint; do NOT create a row yet
tool.start                    {tool_id, name, context, args_text} — create a tool row
tool.progress                 {tool_id, …}
tool.complete                 {tool_id, name, args, result, summary, duration_s, inline_diff?, result_text?, todos?} — collapse row to its summary
message.interim               {text, already_streamed} — seals the current bubble; more may follow
message.complete              {text, rendered, status, usage:{calls,input,output,total}} — terminal; status:"error" carries {error, partial, recoverable} — if partial, keep streamed text and show the error separately
session.info                  {…, running: false} — the REAL end-of-turn signal (message.complete can be followed by chained turns)
```

Blocking prompts (the agent thread is frozen until answered — always surface immediately, even from a background scene):
- `approval.request` `{request_id, command, choices?, allow_permanent, smart_denied}` — derive choices when absent: `smart_denied` → `[once, deny]`; `!allow_permanent` → `[once, session, deny]`; else all four.
- `clarify.request` `{request_id, question, choices?, multi_select?}` and its `clarify.expire`.
- `sudo.request` / `secret.request` (secure text field; **never** log or persist the value) and their `.expire` events.

Also handle: `session.title`, `session.info` (ignore `lazy: true` placeholders), `status.update`, `notification.show`/`notification.clear`, `error`, `sessions.changed` (refresh sidebar), `subagent.*` (render as nested/indented activity — v1 can flatten to labeled tool rows). The event set is **open**: unknown types must be silently tolerated.

Wire model: use a dynamic `JSONValue` enum (lift HermesVoice's) and failable typed wrappers, not strict `Decodable` structs — payload shapes vary by backend version, and the Python backend is loose with types (`true`/`1`/`"true"`).

### 1.7 Error/close codes worth mapping to UX

RPC: `4006` session_id required · `4007` session not found · `4009` session busy · `-32601` unknown method (feature-detect and degrade). WS close: `4401` credentials rejected (re-auth) · `4403` Host/Origin/peer guard (misconfiguration — explain, don't retry-loop).

---

## 2. Connection modes Mercury supports

Mirroring Desktop's resolution model, per saved connection:

1. **Remote gateway (manual URL)** — the primary path. User enters `http://host:9119` (or pastes a dashboard URL with `?token=`), Mercury probes `/api/status`, runs the matching auth (§1.2), and **requires both a successful authed HTTP probe (`GET /api/profiles/active`) and a successful WS dial before saving** — an HTTP-only probe is the documented false-positive trap.
2. **Local loopback** — same flow with `localhost:<port>` + token. On iOS this reaches a Mac via Tailscale/SSH tunnel; document the recipes in a "How do I connect?" sheet (copy HermesVoice's `ConnectHelpView` content: same-Mac token, Tailscale `tailscale serve`, SSH tunnel, gated basic-auth).
3. **macOS only, stretch (Milestone 7)** — *managed local backend*: spawn `hermes serve --host 127.0.0.1 --port 0` with env `HERMES_DASHBOARD_SESSION_TOKEN=<32B base64url you mint>`, `HERMES_HOME`, `HERMES_DESKTOP=1`; scan stdout for `^HERMES_(BACKEND|DASHBOARD)_READY port=(\d+)` (allow 90 s cold start); connect in token mode; terminate the child on quit. Note: a sandboxed Mac App Store build can't do this — it requires the app to run un-sandboxed or with an exception; keep it behind a build flag and don't let it block v1.

Saved connections: a list keyed by endpoint (`scheme://host:port`), most-recent auto-connects on launch, per-row forget (also deletes the Keychain item). Persist the shape, not the secrets: secrets live in Keychain only. No Bonjour/discovery in v1.

Remote liveness: on scene-activation and network-path change, don't just trust the socket — poke the reconnect supervisor immediately (HermesVoice's `pokeReconnect`) and revalidate the endpoint if the dial fails fast.

---

## 3. Architecture

Three layers, SPM package + app target:

1. **`MercuryKit`** (SPM, platform-free) — the protocol layer, lifted from HermesVoice's HermesKit and extended:
   - Keep: `ServerEndpoint`, `HermesAuthenticator`, `ServerCredentials`, `KeychainTokenStore`, `GatewayClient`, `HermesConnection`, `RESTClient`, `HermesError`, `JSONValue`, `GatewayEvent`, `Models`, `SessionAPI` — including their concurrency fixes (per-dial auth query minting, connect-generation guards, backoff-timer scoping, serial event pump, cookie-free sessions, 64 MiB frames, no read timeout).
   - Add: transcript hydration (`GET /api/sessions/{id}/messages` — HermesVoice never needed it), the fuller event set of §1.6 (`reasoning.delta`, `tool.generating`, `tool.progress`, `subagent.*`, `sudo/secret.request`, `notification.clear`, `sessions.changed`), `session.steer`/`redirect`/`delete`/`branch`/`title` RPCs, native-PKCE OAuth in `HermesAuthenticator` (HermesVoice only shipped basic auth), and `usage` from `message.complete`.
   - Bring HermesVoice's HermesKit unit tests along and extend them; keep the package testable without a live server.
2. **`ChatCore`** (SPM, platform-free) — a `@MainActor @Observable` transcript store per session: reduces the event stream into an ordered list of items (user message / assistant bubble with markdown + collapsible reasoning / tool row / subagent group / system notice), merges REST hydration with live events without duplication (hydrate first, then apply events; dedupe on row id where present), tracks `running`/busy from `session.info`, exposes pending approval/clarify state. Unit-test the reducer with recorded event fixtures.
3. **App target(s)** — SwiftUI, one multiplatform app. `@Observable` app model owning connections and open sessions; `NavigationSplitView` (sidebar: connections → profiles/projects → sessions; detail: chat). Swift 6 strict concurrency throughout.

## 4. Product spec — "feels like Hermes Desktop"

**Connect flow:** first-run screen with server field ("127.0.0.1:9119 or paste the dashboard URL"), token secure-field that auto-fills from a pasted `?token=` URL, caption noting gated servers skip the token, "How do I connect?" help sheet, recent-servers list. Gated servers swap to username/password (or PKCE browser button when that's the only provider).

**Sidebar:** saved connections at top; per connection: profiles → projects (from `projects.tree`, with graceful flat-list fallback) → sessions (title, relative time, message count, pinned). New-session button (choose profile + optional workspace cwd). Pull-to-refresh + `sessions.changed`-driven refresh. Connection-state banner (reconnecting…/disconnected) rather than modal errors.

**Chat view (the heart):**
- User/assistant bubbles; assistant text renders **Markdown** (streaming-safe — re-render the growing string; AttributedString/`Text` markdown or a small MD view, keep dependencies minimal), with code blocks (monospace, copy button) and a collapsible "Thinking…" section fed by `reasoning.delta`/`thinking.delta`.
- Tool activity rows: spinner + name + context while running (`tool.start`), collapsing to `summary` + duration on `tool.complete`; expandable to show `args_text`/`result_text`/`inline_diff` (render diffs with +/- coloring). `tool.generating` shows only a transient shimmer.
- Composer: multiline, send button, **Stop** button while `running` (→ `session.interrupt`), queued-send affordance (submit-while-busy is legal and queues).
- Approval requests as a prominent inline card *and* alert-priority presentation: command text (already credential-redacted server-side), the derived choice buttons. Clarify as a sheet with choices/multi-select/free text. Sudo/secret as secure-field sheets.
- Header: session title (editable → `session.title`), model/profile chips from `session.info`, usage tally from `message.complete`, working indicator driven by `running`.
- Scrollback: hydrated transcript pages in as the user scrolls up.
- One shared `.sheet`/presentation coordinator — stacked sheets fault with "Invalid Configuration" (learned the hard way in HermesVoice).

**Platform tailoring:**
- **iPhone:** compact `NavigationStack` drill-in (connections → sessions → chat).
- **iPad/macOS:** `NavigationSplitView`, keyboard shortcuts (⌘N new session, ⌘Enter send, ⌘. interrupt), macOS `Settings` scene, resizable inspector for tool detail. Mac is a real Mac target (not Catalyst-by-default; use the SwiftUI multiplatform target).
- **visionOS:** the same split-view app in a window; volumetric/ornament flourishes only if free. Verify no `UIScreen`/AppKit leakage in shared code; keep platform shims behind `#if os(...)`.
- Theme: system light/dark; respect Dynamic Type.

**Settings:** per-connection (forget, re-auth), appearance, default profile, contract-version notice, diagnostics view (connection phase, last close reason, os.Logger export pointer).

## 5. Project setup

- Xcode project `Mercury.xcodeproj`, one app target with `SUPPORTED_PLATFORMS = iphoneos iphonesimulator macosx xros xrsimulator`, `TARGETED_DEVICE_FAMILY = 1,2,7`; deployment iOS 17 / macOS 14 / visionOS 2. `SWIFT_VERSION = 6.0`, strict concurrency on.
- Local package `Packages/MercuryCore` (`MercuryKit` + `ChatCore` products, tools 6.0, platforms `[.iOS(.v17), .macOS(.v14), .visionOS(.v2)]`).
- Info.plist: `NSAppTransportSecurity → NSAllowsLocalNetworking` (plain-HTTP LAN servers), `NSLocalNetworkUsageDescription`. Entitlements: app sandbox + `com.apple.security.network.client` (macOS).
- No third-party dependencies unless truly needed; prefer none.

## 6. Milestones (each independently demoable)

1. **MercuryKit port** — lift HermesKit, add visionOS platform, extend per §3, all existing + new unit tests green via `swift test`.
2. **Connect + browse** — connect flow (token + gated basic-auth), saved servers, Keychain, sidebar with profiles/projects/sessions on all three platforms.
3. **Chat v1** — create/resume session, streaming markdown, tool rows, interrupt, approvals/clarify, reconnect-and-resume, transcript hydration.
4. **Desktop polish** — iPad/macOS split view, keyboard shortcuts, session management (rename/delete/new-in-workspace), usage display, thinking sections, diff rendering.
5. **visionOS pass + PKCE OAuth** — visionOS UX verification; native OAuth for gated servers that offer `native_pkce`.
6. **Resilience hardening** — inflight/auto_continue recovery on resume, `-32601` degradation paths, background→foreground reconnect, contract-version notice, error-code UX mapping.
7. *(Stretch)* macOS managed local backend (spawn `hermes serve`); voice (§7).

## 7. Voice (explicitly out of v1 scope — design for it)

HermesVoice's `VoiceEngine` (state machine, VAD, barge-in, `/api/audio/transcribe`, `/api/audio/speak-stream` streaming PCM) is a working implementation that can be grafted on later. For now: keep MercuryKit's transport generic enough that `speakStreamURL` and `transcribe` (already in the lifted RESTClient) stay available, and don't preclude a mic button in the composer. Do not flip the backend's voice mode (`voice.*` RPCs) — Desktop's voice is client-owned and Mercury's should be too.

## 8. Verification

Verify against a live backend, not just unit tests:
- Local: `hermes serve` on the Mac (token mode) — full happy path: connect → browse → create → prompt → stream → tool call → approval → interrupt → close.
- Remote/gated: a non-loopback bind with basic auth — password login, cookie parsing, ticket-per-dial, 401→refresh→retry, refresh-death → re-prompt.
- Chaos: kill the backend mid-turn (expect reconnect backoff, then resume-by-stored-id with `inflight` rendered); revoke the token (expect 4401 → re-auth UX, no retry storm); background the iOS app 10 min mid-session (expect clean poke-reconnect on return).
- Run the iOS simulator, a macOS build, and the visionOS simulator before calling any milestone done.

## 9. Non-goals (v1)

Voice conversation UI · wake word · Hermes Cloud portal login (`mode: cloud`) · SSH-managed remotes · multi-window per-profile socket pooling (one socket per connection is fine; profile scoping via the `profile` param) · watchOS/widgets/Live Activities · editing agent config/skills · file/image attach (`file.attach` etc.) · pet/insights/billing surfaces.

## 10. Sharp edges (every one of these has bitten before)

1. `prompt.submit` returns `{"status":"streaming"}` immediately — completion is events only; `session.info.running == false` is the true end-of-turn, not `message.complete`.
2. Runtime ids are recycled on backend restart — resume by **stored** id, always; re-anchor the stored id from `resumed`/`session_key` after every resume.
3. Mint WS auth (ticket) **per dial**; tickets are single-use with 30 s TTL. Token-mode URLs are reusable; gated ones never are.
4. Dial by exactly the bound host (Host-header guard → 4403). Omit or match the Origin header.
5. Login tokens arrive as cookies with three possible name prefixes; parse headers manually and keep cookie storage disabled everywhere else.
6. No read timeout on the chat socket; quiet-for-minutes is healthy mid-turn. Set `maximumMessageSize` to 64 MiB.
7. Coalesce nothing client-side out of order — process events on a serial pump or deltas garble.
8. `tool.generating` is not `tool.start` — no row until `tool.start` (with `tool_id`).
9. `message.complete` with `status:"error"`, `partial:true` → keep streamed text, show error alongside.
10. `GET /api/profiles` is slow (walks skill trees) — 60 s timeout, load it independently so it never blocks the sessions list.
11. Approval has **no** request_id (session-keyed); clarify/sudo/secret **are** request_id-keyed. Late responds return `{"status":"expired"}` — handle gracefully.
12. Suspending connect flows need a generation guard so a second connect attempt can't orphan a live socket; scope backoff timers to their own wait.
13. Empty transcript strings from the backend mean "nothing", not an error.
14. `-32601` on `projects.*` → older backend; degrade to flat session grouping, remember the capability.
15. One shared sheet coordinator; stacked SwiftUI sheets crash.

## 11. Working style

Work milestone by milestone; keep the project building and tests green at every commit. Commit at each milestone boundary with a descriptive message. When the backend contract and this document disagree, read the backend source (paths in §0) and follow it — then note the discrepancy in the README. Maintain a README with: architecture map, connection recipes, deviations-from-desktop list, and a manual verification checklist per milestone (HermesVoice's README is the model).
