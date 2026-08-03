# Contributing to Scribird

Issues and pull requests are both welcome. This document covers what you need to build,
test, and get a change merged.

Before touching the capture or transcription path, read the
[architecture invariants](./AGENTS.md#architecture-invariants) in `AGENTS.md`. Each one was
established by measurement, and undoing one reintroduces a bug that is hard to notice —
usually a bug that produces *silence* rather than an error.

## Running the app in Xcode or from the command line

Scribird is a Swift Package with no external dependencies. macOS 26 and a Swift 6.2+
toolchain are required (verified on Swift 6.3.3 / macOS 26.5.2).

```bash
swift build -c debug   # compile with actor data-race checks enabled
swift test             # 242 tests; STT fixture and device tests need local resources
./build.sh release     # produce and sign build/Scribird.app
./install.sh           # release-build, then install into /Applications
```

The Claude Code plugin under [`plugin/`](./plugin/README.md) is separate from the app and has
its own suite, which needs neither the toolchain nor AWS:

```bash
cd plugin/scribird-diarize/skills/multi-speaker-diarize
/usr/bin/python3 -m unittest discover -s tests   # 112 tests
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
  constant edit (the stop deadline, the silence threshold, the audio bitrate), because those
  numbers are contracts the ADR keeps, not tuning knobs.
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

Some specifics:

- Tests must not reach the network. The update-check tests intercept `URLProtocol` and
  synthesize responses.
- `Bundle.main` under `swift test` is the test runner, not the app, so it reports the macOS
  version. Inject the version being compared rather than reading the bundle.
- `TranscriptStore` writes under `~/Documents`, so its tests override `HOME` to a temporary
  directory. Follow that pattern for anything else touching the real filesystem.
- `LanguageArbiter.arbitrate` and `AudioLevelTracker` are `@MainActor`/actor-isolated. Give
  the test class matching isolation instead of weakening the source annotation.
- The device-switch tests are the one exception to "no hardware": they change the real
  default output device and restore it, and skip themselves when the machine has only one
  output device. Core Audio listener callbacks arrive off the main actor, so collect their
  values in the lock-wrapped box in `TestSupport` rather than capturing a local `var` —
  Swift 6 will reject the latter, and the fix is the box, not a weaker annotation.

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

One test is skipped with a stated reason rather than passing: a long garbage token from the
non-matching locale swallows an adjacent region and takes the `insulin` span with it. That's
a real defect in region assignment, and the skip message says what to fix to re-enable it.
Don't loosen the assertion to make it pass.

### Taking screenshots for the docs

Screenshots live in `docs/images/`. Take them by hand, from a real session you're willing to
show — open the transcript window with `⌥⌘S`, get it into the state you want, then capture that
window alone rather than cropping a full-screen shot:

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
and `remote.m4a` exist in `~/Documents/Scribird/<date_time>/`, and that the `.m4a` files
actually open — a container that was never finalized still has bytes on disk.

**Session rotation.** While recording, press the ✎ button, keep speaking, then stop. Two
session directories must exist, each with a playable `.m4a` and a `transcript.md` whose
timecodes start near `00:00:00`. A second meeting starting at `01:02:05` means the time
rebase was lost.

**Device switching.** While recording, plug in a headset (or change the output device in
System Settings › Sound). The remote level meter must resume within about a second, a notice
must name the device it moved to, and — critically — the session must **not** split: one
session directory, one pair of `.m4a` files, and `transcript.md` timecodes that keep
increasing across the switch. Repeat for the input device with a USB microphone. Then unplug
the device mid-recording and confirm the other source keeps transcribing.

**Device pinning.** In settings, pick a specific device instead of *시스템 기본* for one
source. Then change the system default and confirm that source does **not** move while the
other one does — pinning is per-source. Change the pinned device while recording and confirm
capture reconnects without splitting the session. Finally, unplug the pinned device: the app
must fall back to the system default with a warning, and re-plugging it must return to the
pinned choice — the selection is kept, not erased.

**Global hotkey.** Press the hotkey from another frontmost app, click that app, and confirm
the transcript window stays visible. Then set a combination already taken by another app and
confirm the settings footer reports the failure instead of failing silently.

**Settings.** Open `⌘,`, confirm the transcript window behind it stays visible and recording
continues, and that the language and audio-saving rows are disabled with a stated reason
while recording.

**Update check.** Press it with the network off and confirm it reports a failure that leaves
recording unaffected. With the network on, confirm it distinguishes "up to date" from a
failure — silence for either would be indistinguishable to the user.

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

| Scope | Covers | Code lives in |
|---|---|---|
| `capture` | Microphone and system-audio capture, devices, levels | `Audio/` |
| `transcription` | Analyzer sessions, language arbitration, model provisioning | `Transcription/` |
| `session` | Session boundaries, hotkeys, windows, the update check | `UI/`, `MeetingRecorder.swift` |
| `archive` | Transcript persistence and original-audio recording | `Transcript/`, `Audio/AudioRecorder` |

The first four are exactly the ADR categories, so a commit and the decision it implements name
the same area. Two scopes exist outside that mapping because they have no ADR to belong to:

| Scope | Covers |
|---|---|
| `plugin` | The Claude Code / Codex plugin under `plugin/` |
| `build` | `build.sh`, `install.sh`, `Package.swift`, bundle resources |

Note that a scope is a *decision* area, not a folder — `archive` covers both
`Transcript/` and the recorder inside `Audio/`, because one ADR governs them together. When
unsure, ask which ADR the change answers to; if none does, it's probably `plugin` or `build`.

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
chore: bump version to 0.1.3
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
