# Security Policy

Mercury Chat is a native client for [Hermes Agent](https://github.com/NousResearch/hermes-agent).
It holds credentials for servers you control and implements password and
native-PKCE sign-in, so it has a security surface worth reporting against.
This document says how to report an issue and what falls inside scope.

## Reporting a vulnerability

Report privately through [GitHub Security Advisories](../../security/advisories/new),
or by email to **spencermcguire@gmail.com** if you prefer. Please do not open
a public issue for a security vulnerability.

Mercury Chat does not operate a bug bounty program.

A useful report includes:

- A concise description and your severity assessment.
- The affected component by file path and line range
  (e.g. `Packages/MercuryCore/Sources/MercuryKit/HermesAuthenticator.swift:64-99`).
- Platform and OS version, and the commit SHA you tested against.
- A reproduction, or a clear explanation of the attack path if a live
  reproduction is impractical.

I will acknowledge reports as soon as I reasonably can. Mercury Chat is
maintained by one person in spare time, so please allow for delay — a report
is not being ignored.

## Supported versions

Mercury Chat has not yet had a tagged release. Until it does, only the latest
commit on `main` is supported. Fixes land there; there are no backports.

## Scope

Mercury Chat is a client. It has no backend of its own, no developer-operated
service, and no account system — it talks only to the Hermes Agent server the
user points it at. The trust boundary this policy treats as load-bearing is
**between the app and the user's device**: credentials the app holds must not
leak to other apps, other devices, or the network in ways the user did not
choose.

### In scope

- **Credential storage.** Anything that exposes Keychain items beyond their
  intended reach, or that weakens the device-only, after-first-unlock
  protection they are written with (`KeychainTokenStore`).
- **Token handling.** Leakage or misuse of access tokens, refresh tokens, or
  WebSocket dial tickets — including ticket reuse across dials, since tickets
  are meant to be single-use with a 30-second TTL (`HermesAuthenticator`).
- **The native-PKCE sign-in flow.** Weak or predictable code verifiers or CSRF
  `state`, missing state validation, code interception, or any way to redeem an
  authorization code that was not issued to this attempt.
- **The loopback redirect listener.** It binds `127.0.0.1` on an OS-assigned
  port to receive one OAuth redirect. Anything that lets a non-local party
  reach it, that leaves it listening beyond the one redirect, or that injects
  into the page it serves back (`LoopbackRedirectListener`).
- **Transport decisions.** Cases where the app uses plaintext HTTP, accepts a
  certificate, or discloses credentials when it should not have.
- **The plaintext-HTTP warning gate.** Connecting over plaintext to a
  non-loopback host requires an explicit user override. A way to reach that
  state *without* the override is in scope.
- **URL and token parsing.** Mishandling of pasted dashboard URLs, including
  how the `?token=` parameter is lifted (`ServerEndpoint`).
- **Rendering of server-controlled content.** Injection or escape issues in how
  transcript text, tool output, or server-supplied strings are displayed.

### Out of scope

- **Hermes Agent itself.** The backend is a separate upstream project. Report
  those to [its own security channel](https://github.com/NousResearch/hermes-agent/security/advisories/new)
  or `security@nousresearch.com`, not here. The `hermes-agent/` directory in
  this repository is an untracked reference clone and ships in nothing.
- **How you configure your own server.** Exposing a Hermes Agent server to the
  internet, choosing weak credentials, or granting an agent broad permissions
  are operator decisions, not client vulnerabilities.
- **What your server does with your data downstream**, including anything it
  forwards to model providers. See [PRIVACY.md](PRIVACY.md) for where that
  boundary sits.
- **Plaintext HTTP after you accepted the override.** The app warns clearly and
  requires an explicit opt-in per server; traffic being readable afterward is
  the documented consequence, not a flaw. Bypassing the warning is in scope —
  see above.
- **Attacks requiring an already-compromised device**, a jailbroken OS, or
  physical access to an unlocked, signed-in device.
- **Reports produced solely by automated scanners** with no demonstrated attack
  path.

## Disclosure

Please give me a reasonable chance to ship a fix before publishing. I am happy
to credit you in the release notes and the advisory — tell me how you would
like to be named, or say if you would rather stay anonymous.
