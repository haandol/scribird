# Security Policy

## Supported versions

Only the [latest release](https://github.com/haandol/scribird/releases/latest) is supported.
Fixes go into a new release rather than being backported.

## Reporting a vulnerability

Report privately through
[GitHub Security Advisories](https://github.com/haandol/scribird/security/advisories/new)
rather than opening a public issue.

Please include what the issue lets an attacker do, the steps to reproduce it, and the app and
macOS versions you saw it on. **Do not attach meeting audio or transcripts** — describe the
data flow instead.

## What is in scope

Scribird holds microphone and system-audio capture permission and writes meeting content to
disk, so the interesting failures are about that content escaping or those permissions being
borrowed. In particular:

- **Meeting data leaving the device.** The app makes exactly one network request — the
  release lookup behind *새 버전 확인*, and only on that button press. Anything that causes a
  request the user did not initiate, or that attaches app-produced data (transcript text,
  usage counts, a device identifier) to that request, is a vulnerability, not a feature
  request.
- **Escalating the permissions Scribird already holds.** The app requests microphone and
  audio capture, and deliberately never requests screen recording or accessibility. A path
  that lets another process capture audio through Scribird's grant, or that causes Scribird
  to request a permission it does not need, is in scope.
- **Transcript and audio file handling.** Session directories under `~/Documents/Scribird/`
  are written with the user's own permissions. Path traversal, predictable-name collisions
  that clobber existing files, or content written outside that root are in scope.
- **The update path.** Scribird reports that a newer release exists and opens the release page;
  it never downloads or installs anything. Anything that turns the check into a download or
  execution path is in scope.

## What is not in scope

- **App Sandbox being disabled.** This is a deliberate, documented decision — it is needed for
  Core Audio process taps and for writing under `~/Documents`. See
  [`docs/adr/capture/0001-system-audio-process-tap.md`](./docs/adr/capture/0001-system-audio-process-tap.md).
- **Builds not being notarized.** Releases are ad-hoc distributed and Gatekeeper will warn on
  first launch. This is stated in the README and is not a vulnerability report; build from
  source if it matters to you.
- **Transcripts surviving uninstallation.** Meeting records in `~/Documents/Scribird/` are
  intentionally left behind when the app is removed. An uninstall should not discard a
  meeting record.
- **Anything requiring an attacker who already has local code execution as the user.** At that
  point they can read `~/Documents` directly, without Scribird.
- **The two-speaker attribution ceiling**, or recognition accuracy generally. Those are
  documented limitations.
