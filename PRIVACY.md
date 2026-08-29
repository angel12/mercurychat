# Privacy Policy for Mercury Chat

**Last updated:** August 28, 2026

Mercury Chat is a client app for [Hermes Agent](https://github.com/NousResearch/hermes-agent). It connects
to a Hermes Agent server that **you** run and control. Mercury Chat has no backend of its own: there is no
Mercury Chat account, no Mercury Chat server, and no service operated by the developer that your data passes
through.

This policy explains what Mercury Chat stores, what it sends, and where it sends it.

## The short version

- Mercury Chat collects **no** personal data and transmits **no** data to the developer.
- Mercury Chat contains **no** analytics, advertising, tracking, or crash-reporting services, and no
  third-party SDKs of any kind.
- Everything you type in Mercury Chat goes to the Hermes Agent server you chose to connect to, and
  nowhere else.
- Credentials are stored in the device Keychain; server addresses are stored in app preferences.
  Both stay on your device.

## Information stored on your device

Mercury Chat stores the following locally. None of it is transmitted to the developer or to any third
party.

| What | Where | Why |
|---|---|---|
| Addresses of servers you have connected to | App preferences (`UserDefaults`) | So the connect screen can list them and reconnect on launch |
| The most recently used server | App preferences | To reconnect automatically when you reopen the app |
| Servers you explicitly allowed over plaintext HTTP | App preferences | So Mercury Chat does not re-prompt for a warning you already accepted |
| Access tokens, passwords, and OAuth credentials for those servers | Device Keychain | To authenticate to your server without asking every time |

Keychain items are written with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: they are
available only after the device has been unlocked once, and they are **not** synchronized to iCloud
Keychain or to your other devices.

Conversation transcripts are held in memory while the app is running and are re-fetched from your
server when you resume a session. Mercury Chat does not maintain its own separate on-device archive of
your conversations.

Removing a saved server from the connect screen deletes its stored credentials from the Keychain and
its address from app preferences. Deleting the app removes all locally stored data.

## Information sent to your Hermes Agent server

When you use Mercury Chat, the following is sent over the network **only** to the server address you
entered:

- The prompts and messages you type.
- Images you attach to a message (chosen from your photo library or files, pasted, or dragged
  in). Mercury Chat resizes large images before sending; attached images are held in memory only
  and are not archived on your device.
- Authentication credentials (a token, a username and password, or an OAuth authorization result).
- Session, profile, and project selections, and control actions such as interrupting, renaming,
  branching, or deleting a session.
- Responses to prompts your server raises, including tool-approval decisions and any values you
  supply to administrator-password or secret requests.

That server is operated by you or by whoever you obtained it from. **Mercury Chat does not control what
happens to data once it reaches your server.** Hermes Agent may in turn send your conversation
content to model providers or other services according to how you have configured it. Those
services' handling of your data is governed by their own terms and privacy policies, not by this
one.

Mercury Chat does not contact any host other than the server address you supply and, during OAuth
sign-in, the authorization endpoint that your server advertises.

## Network and transport

Mercury Chat requests **Local Network** access on iOS and visionOS so it can reach a Hermes Agent server
running on your Mac or elsewhere on your LAN. It uses this permission for no other purpose — it does
not scan, enumerate, or catalog devices on your network.

Mercury Chat uses HTTPS wherever the address you supply is HTTPS. If you enter a plaintext `http://`
address for a host that is not a loopback address, Mercury Chat warns you that your credentials and
message content would cross the network unencrypted and requires an explicit override before
connecting. Whether your connection is encrypted is determined by the address you choose.

On macOS, signing in with OAuth briefly opens a listener on a loopback address (`127.0.0.1`) to
receive the authorization redirect, as described in RFC 8252. It accepts only that redirect and
closes immediately afterward.

## What Mercury Chat does not do

- No analytics or usage telemetry of any kind.
- No advertising, advertising identifiers, or tracking across apps or websites.
- No third-party crash-reporting or attribution SDKs.
- No sale or sharing of personal information — no personal information is collected to sell or
  share.
- No user accounts, registration, or profiles with the developer.

Mercury Chat does not collect data as defined by Apple's App Tracking Transparency framework and does not
present a tracking prompt.

## Children

Mercury Chat is a developer tool and is not directed to children under 13 (or the equivalent minimum age
in your jurisdiction). The developer does not knowingly collect personal information from children —
or, in fact, from anyone.

## Your rights

Because the developer receives, stores, and processes none of your data, there is nothing held by
the developer to access, correct, export, or delete. Data held by your Hermes Agent server is under
your control on that server. Locally stored data can be removed by forgetting the server in the app
or by deleting the app.

## Changes to this policy

If this policy changes, the updated version will be posted at this address with a revised "Last
updated" date. Material changes will be noted in the app's release notes.

## Contact

Questions about this policy can be sent to <spencermcguire@gmail.com>.
