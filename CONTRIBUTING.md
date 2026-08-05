# Contributing to Scribird

Issues and pull requests are both welcome. This document covers what you need to build,
test, and get a change merged.

Before touching the capture or transcription path, read the
[architecture invariants](./AGENTS.md#architecture-invariants) in `AGENTS.md`. Each one was
established by measurement, and undoing one reintroduces a bug that is hard to notice —
usually a bug that produces *silence* rather than an error.

## Running the app in Xcode or from the command line

Scribird is a Swift Package with no external dependencies. The required macOS and Swift
versions are declared in `Package.swift`.

```bash
swift build -c debug   # compile with actor data-race checks enabled
swift test             # STT fixture and device tests need local resources
./build.sh release     # produce and sign build/Scribird.app
./install.sh           # release-build, then install into /Applications
```

The Claude Code plugin under [`plugin/`](./plugin/README.md) is separate from the app and has
its own suite, which needs neither the toolchain nor AWS:

```bash
cd plugin/scribird-diarize/skills/multi-speaker-diarize
/usr/bin/python3 -m unittest discover -s tests
```

Two things about running it:

- **Run it as a bundle, not as a bare executable.** macOS ties permissions (TCC) to the
  bundle identifier, so `swift run` can never obtain microphone or audio-capture permission.
  Use `./build.sh release && open build/Scribird.app`.
- **Restart an already-running copy** after `./install.sh` — replacing the bundle on disk
  does not affect the running process.

### Signing

`build.sh` looks for a `Developer ID Application` or `Apple Development` certificate in your
keychain, overridable with `SIGN_IDENTITY`:

```bash
SIGN_IDENTITY="Apple Development: you@example.com (XXXXXXXXXX)" ./build.sh release
```

Without a certificate it falls back to ad-hoc signing. **The app still builds and runs, but
system-audio capture silently yields silence** because ad-hoc signing leaves
`TeamIdentifier` empty and the process tap never prompts. If you are working on the
system-audio path, you need a real certificate — a free Apple Developer account provides an
`Apple Development` one.

## ADR-first workflow

Design decisions live in [`docs/adr/`](./docs/adr/), and the ADR comes **before** the code.

- **Behavior changes** — update the relevant ADR first, then bring the code to it in the
  same commit. That includes changing a requirement value even when it looks like a one-line
  constant edit, because such a number is a contract the ADR keeps, not a tuning knob. The
  deciding question: would a developer changing this value at will be violating a
  requirement?
- **Bug fixes, refactors, docs, formatting** — no ADR needed. A structural change that does
  not alter behavior is scoped by the pull request itself.
- **New areas** — write the ADR directly. See
  [`docs/adr/authoring-rules.md`](./docs/adr/authoring-rules.md) for what belongs in one and
  what does not.

The ADR body records *why*, the alternatives that were rejected, and the requirement
contract the result must honor. It never carries file paths or function names, and code
never carries ADR IDs — the two are located by reading and searching, so that renumbering an
ADR doesn't force a code change and vice versa.

## Testing

Tests live in `Tests/ScribirdTests/` and run with `swift test`. Name methods
`test_<behavior>_<expectedResult>()`. Keep them deterministic — no sleeps, no real audio
hardware, no network.

Two conventions matter more here than coverage does:

- **Encode the measured failure, not a synthetic one.** Where a decision came from an
  observation — confidence values, dBFS levels, buffer layouts — feed those exact numbers
  in. A test built on invented input passes without proving the rule is needed.
- **Verify the test discriminates.** After writing a test for an invariant, break that
  invariant in the source and confirm the test fails. Several tests here initially passed
  against deliberately broken code, because the input did not actually exercise the rule.

Some traps that are easy to hit here:

- **Tests must not reach the network.** The update-check tests intercept requests and
  synthesize responses; follow that rather than talking to a real host.
- **`Bundle.main` under `swift test` is the test runner, not the app**, so it reports the
  macOS version instead of the app's. Inject the version being compared rather than reading
  the bundle.
- **Anything writing under the real home directory must redirect it** to a temporary one.
  The transcript-store tests override `HOME`; follow that pattern.
- **Match the source's actor isolation in the test class** instead of weakening the source
  annotation to make a test compile.
- **The device-switch tests are the one exception to "no hardware":** they change the real
  default output device and restore it, and skip themselves when the machine has only one
  output device. Core Audio callbacks arrive off the main actor, so collect their values in
  the lock-wrapped box in the shared test support rather than capturing a local `var` —
  Swift 6 rejects the latter, and the fix is the box, not a weaker annotation.

### Speech-to-text fixture tests

The transcription pipeline downstream of capture — conversion, timing, the analyzer, and
language arbitration — is covered by running a real audio file through it. Synthetic input
can't tell you what text, confidence, or timings come back, so it can't catch a regression
in transcription quality.

**The audio file is not in the repository.** This project doesn't commit recorded
conversations, and the fixture is a medical consultation, so it's no exception. Point the
tests at a local file:

```bash
SCRIBIRD_STT_FIXTURE=/path/to/audio.mp3 swift test --filter SpeechTranscriptionFixtureTests
```

Without it the tests skip themselves, so CI stays green and contributors without the file
aren't blocked. If you add a fixture, record its ground-truth text and the keywords that must
survive alongside it — the tests compare against those, not against a golden transcript,
because the on-device model's exact wording changes between OS versions.

Some of these tests skip themselves with a stated reason rather than passing, to hold a known
defect visible instead of asserting the broken behavior is correct. Each skip message says
what to fix to re-enable it. **Don't loosen an assertion to turn a skip into a pass** — read
the message and either fix the defect or leave the skip alone.

### Taking screenshots for the docs

Screenshots live in `docs/images/`. Take them by hand, from a real session you're willing to
show — open the transcript window with the global hotkey, get it into the state you want, then
capture that window alone rather than cropping a full-screen shot:

```bash
screencapture -w -o out.png     # click the window; -o drops the drop shadow
```

**Never capture a real meeting.** Whatever is on screen ends up in the repository, and this
project doesn't commit meeting content in any form. Say something innocuous into the mic and
play innocuous audio for the remote side, or replace the text afterwards.

There is deliberately no fixture or demo mode for this. Code that fabricates transcript
content has to sit in the same state machine that records real meetings, and that's a bad place
for a switch whose whole job is to make the app show things that never happened.

### Manual smoke test

Hardware capture, session rotation, and the global hotkey cannot be covered by `swift test`
— neither a Carbon event target nor a live capture rotation exists there. Changes to those
paths need a manual pass:

**Capture.** Build and install the bundle, start a recording, confirm both level meters move,
speak and play remote audio, then stop. Verify `transcript.jsonl`, `transcript.md`, `me.m4a`,
and `remote.m4a` exist in `~/Documents/Scribird/<date_time>/` (or under the save location if you
changed it), and that the `.m4a` files actually open — a container that was never finalized still
has bytes on disk.

**Session rotation.** While recording, start a new session, keep speaking, then stop. Two
session directories must exist, each with a playable `.m4a` and a `transcript.md` whose
timecodes start near zero. A second meeting whose timecodes carry on from where the first one
ended means the time rebase was lost. The displayed session location must switch to the new
directory at the boundary, and **no file-explorer window may open** — the boundary means the
meeting is continuing.

**Session folder.** The location must be shown in **every** state — while recording (the
session being written to), after stopping (the last one), and on a machine that has never
recorded, where it points at the root and opening it must still work even though that folder
doesn't exist yet. Then confirm stopping opens the folder by itself, turn the setting off, and
confirm stopping opens nothing while the displayed location still does. Automated tests cover
the policy but cannot see whether a real window appeared.

**Settings tabs.** Click through all three tabs. Two things to watch: the app must not die, and
no tab may clip its last row. The crash is the one that actually happened — letting the window
size itself from the content while the content sized itself from the window made switching tabs
throw an uncaught Auto Layout exception, and it leaves no crash report. The window is a fixed size
now and tabs scroll inside it, so the remaining risk is a tab that needs more height than the
window has.

**Interface language.** Switch the language in settings and confirm the transcript window
behind it redraws immediately. The strings come from a global value, so if a view forgets to
observe the language it stays in the old one until reopened — and that gap is invisible unless
you watch a second window while switching. Then record briefly, stop, and open `transcript.md`:
its speaker labels must be `Me`/`Remote` regardless of the language you picked. The file is read
later by other tools, so its vocabulary is fixed while the screen's is not.

**Save location.** Point the save location at another folder in settings, record, and confirm
the session directory is created there and the footer path matches. Then point it at a removable
volume, eject it, and start recording: the session must land in the default location **with a
notice saying why**, and settings must still list the chosen folder — the fallback keeps the
choice so re-attaching the volume returns the next session to it. Confirm the earlier sessions
stay where they were; the app never moves them. While recording, the location row must be
disabled with a stated reason. Changing it mid-session would leave one meeting's `.m4a` and
`transcript.md` in two folders, which is the failure this lock prevents and only appears with a
live capture.

**Device switching.** While recording, plug in a headset (or change the output device in
System Settings › Sound). The remote level meter must resume within about a second, a notice
must name the device it moved to, and — critically — the session must **not** split: one
session directory, one pair of `.m4a` files, and `transcript.md` timecodes that keep
increasing across the switch. Repeat for the input device with a USB microphone. Then unplug
the device mid-recording and confirm the other source keeps transcribing.

**Device pinning.** In settings, pick a specific device instead of following the system
default for one source. Then change the system default and confirm that source does **not** move while the
other one does — pinning is per-source. Change the pinned device while recording and confirm
capture reconnects without splitting the session. Finally, unplug the pinned device: the app
must fall back to the system default with a warning, and re-plugging it must return to the
pinned choice — the selection is kept, not erased.

**Global hotkey.** Press the hotkey from another frontmost app, click that app, and confirm
the transcript window stays visible. Then set a combination already taken by another app and
confirm the settings footer reports the failure instead of failing silently.

**Window layering and close.** With the transcript window up, stop a recording and confirm the
session folder appears **in front of** it — the window floats above other apps, so a regression
here shows up as the folder opening behind it, which the automated tests can't see. Click the
transcript window and confirm it returns above other apps. Then press `⌘W` with the transcript
window in front and confirm it goes away while the recording continues (start one first). The
interception lives on the transcript window only, so also check that recording `⌘W` into a
shortcut field in settings still captures it as a combination.

**Settings.** Open the settings window with its shortcut, confirm the transcript window behind
it stays visible and recording continues, and that the rows locked for the duration of a
session are disabled with a stated reason rather than silently ignoring input.

**Update check.** Press it with the network off and confirm it reports a failure that leaves
recording unaffected. With the network on, confirm it distinguishes "up to date" from a
failure — silence for either would be indistinguishable to the user.

**Locale reservation recovery.** Fill the platform's locale-reservation quota with locales
the app doesn't use, then start a recording with two languages. It must start — the app
reclaims its own leftover reservations and retries. A failure claiming the reservation limit
was exceeded is the bug this path exists to prevent. Reservations outlive the process, so a
signed helper sharing the bundle identifier is one way to set this state up.

## Coding style

Four spaces, standard Swift API design: `UpperCamelCase` for types, `lowerCamelCase` for
properties and functions, descriptive enum cases. One primary type per file, placed in the
existing domain folder. Prefer structured concurrency and explicit actor isolation.

**Never weaken Swift 6 concurrency checking** to resolve a data-race diagnostic. Audio
callbacks run off the main actor; use the existing lock and handoff patterns.

Comments are in Korean, as is all user-facing text and every error message. Comment only
non-obvious audio, timing, permission, or language-arbitration behavior — and when the reason
is an empirical finding, **record the measurement, not just the conclusion**. That convention
is why the invariants in `AGENTS.md` are recoverable at all. No formatter or linter is
configured, so match nearby code.

## Commits

This project follows [Conventional Commits v1.0.0](https://www.conventionalcommits.org/en/v1.0.0/).

```
<type>(<scope>): <subject>

[body]

[footer(s)]
```

### Type (required)

| Type | Use for | SemVer |
|---|---|---|
| `feat` | A new capability | MINOR |
| `fix` | A bug fix | PATCH |
| `refactor` | Restructuring with no behavior change | — |
| `perf` | Performance work | — |
| `test` | Tests only | — |
| `docs` | Documentation only | — |
| `chore` | Version bumps, build settings, maintenance | — |
| `style` | Formatting, no logic change | — |
| `ci` | CI/CD configuration | — |

### Scope (optional)

The scopes mirror the ADR categories, so a commit and the decision it implements name the same
area:

| Scope | Covers |
|---|---|
| `capture` | Microphone and system-audio capture, devices, levels |
| `transcription` | Analyzer sessions, language arbitration, model provisioning |
| `session` | Session boundaries, hotkeys, windows, the update check |
| `archive` | Transcript persistence and original-audio recording |

Those four are exactly the ADR categories. Two scopes exist outside that mapping because they
have no ADR to belong to:

| Scope | Covers |
|---|---|
| `plugin` | The Claude Code / Codex plugin |
| `build` | Build and install scripts, package manifest, bundle resources |

Note that a scope is a *decision* area, not a folder — `archive` covers transcript
persistence and the audio recorder even though they sit in different folders, because one ADR
governs them together. When unsure, ask which ADR the change answers to; if none does, it's
probably `plugin` or `build`.

Omit the scope when a change genuinely spans everything — a repository-wide docs pass, for
instance.

### Subject (required)

- **English**, lowercase first letter
- Imperative mood: "add", "fix", "keep" — not "added", "fixes", "keeping"
- No trailing period
- Aim for 50 characters, 72 is the hard limit

English subjects with Korean comments and ADRs is deliberate, not an oversight. The commit log
is read through `git log`, `gh`, and GitHub's UI where the subject is often truncated and
searched; comments and ADRs are read in place, in full, by the people maintaining the audio
path. The two audiences differ, so the language does too.

### Body (optional)

Explain **why**, not what — the diff already says what. Wrap at 72 columns.

**When a change came from a measurement, put the numbers in.** This history is the project's
primary record of hardware behavior, and there is often nowhere else that number lives. State
the value observed and the failure mode it ruled out:

```
fix(archive): raise AAC bitrate to 128k per channel

Re-transcribing 64k audio produced 배포 → 대포. 128k and lossless matched
the original exactly. Mono runs about 54 MB an hour, which is worth paying
because the whole point of keeping the original is reprocessing it.
```

### Footer (optional)

- `BREAKING CHANGE: <description>` — for changes that break compatibility (SemVer MAJOR)
- `Refs: #<issue>` — related issue
- `Co-Authored-By: Name <email>` — co-author

A breaking change is marked with `!` after the type, or with the footer:

```
feat(archive)!: move session directories under Application Support

BREAKING CHANGE: existing sessions in ~/Documents/Scribird are not migrated.
```

### Good examples

```
feat(capture): follow the system default output device while recording
fix(session): register the global hotkey from the app-launch callback
refactor(capture): share one pump between both capture paths
perf(transcription): reuse the converter across buffers of one format
test(capture): assert the tap and the monitor read the same selector
docs: restructure the README for users and add real screenshots
chore: bump the version for release
```

### Bad examples

```
# no type
Update level meter handling

# past tense, capitalized
feat: Added support for pinned devices

# too vague to be searchable
update stuff
fix bug

# two unrelated changes in one commit
feat(capture): add device pinning and fix transcript timing
```

### Atomic commits

One logical change per commit. Don't mix a fix with a feature, or a refactor with a behavior
change. When a change is large, split it — and note that this matters more here than usual:
**a commit that mixes a measurement-driven fix with unrelated work buries the measurement**,
and that record is the reason the history is worth reading.

An ADR change and the code that implements it are the exception: they belong in the *same*
commit, because a decision that isn't yet in code and code that contradicts the decision are
both worse than the pair landing together. See [ADR-first workflow](#adr-first-workflow).

## Pull requests

### Title

Same format as a commit subject:

```
feat(capture): follow the system default output device while recording
```

### Body

```markdown
## Summary

What changed, in a sentence or two.

## Motivation

Why. If a measurement drove it, the numbers go here.

## Verification

Commands you ran, and the result. Include the manual smoke test when the change
touches capture, session rotation, or the hotkey.

## Impact

Permissions, storage layout, or preference keys this affects. "None" is a valid answer.
```

Include screenshots for SwiftUI changes.

> [!IMPORTANT]
> **Never include recorded meeting audio or generated transcripts** — not in commits, not in
> issues, not in pull request attachments. This applies to screenshots too: capture a session
> you're willing to publish, not a real meeting.
