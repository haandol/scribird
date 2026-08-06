# Repository Guidelines

This file is the agent-facing contract and is loaded into context every session. The
human-facing docs cover the same ground for contributors, so keep them in step when a rule
here changes:

- [`README.md`](./README.md) — what the app does, install, usage, output layout, permissions
- [`CONTRIBUTING.md`](./CONTRIBUTING.md) — build, test, manual smoke test, commit conventions
- [`docs/Troubleshooting.md`](./docs/Troubleshooting.md) — user-facing diagnosis by symptom
- [`docs/adr/`](./docs/adr/) — why each decision was made, and the alternatives rejected

The **Architecture Invariants** below are the part that exists nowhere else. Everything else
in this file is duplicated in `CONTRIBUTING.md` on purpose, because an agent has this file
and not that one.

## Project Structure & Module Organization

`Scribird` is a Swift 6.2+ macOS 26 menu-bar application. All transcription and storage
happens on-device; nothing leaves the machine. Application code lives under
`Sources/Scribird/`:

- `Audio/`: microphone capture (`AVAudioEngine`), system-audio capture (Core Audio
  process tap), sample-rate conversion, level tracking, and original-audio recording.
- `Transcription/`: `SpeechAnalyzer` sessions, language selection, model installation,
  and multilingual arbitration.
- `Transcript/`: speaker and segment models, timeline merging, and JSONL/Markdown
  persistence.
- `UI/`: the SwiftUI transcript view, the settings window, the floating window,
  global-hotkey registration, and the update check.
- `MeetingRecorder.swift`: application state and pipeline orchestration.

Bundle metadata, entitlements, and the editable app icon are in `Resources/`. Generated
artifacts belong in `.build/` and `build/`; do not edit or commit them as source.

## Architecture Invariants

Read these before touching the capture or transcription path. Each one was established
by measurement, and breaking it reintroduces a bug that is hard to notice.

- **Two independent capture paths, one analyzer each.** Microphone audio is always `me`
  and system output is always `remote`, so speaker labels need no inference. Never merge
  the sources upstream of `TranscriptTimeline.ingest`.
- **Do not reintroduce ScreenCaptureKit.** It forces screen-recording permission
  (`kTCCServiceScreenCapture`) even when only audio is wanted. System audio comes from a
  Core Audio process tap, which needs only `kTCCServiceAudioCapture`. The app must never
  request screen-recording permission.
- **One path failing must not kill the other.** A missing microphone permission still
  leaves system-audio transcription working, and vice versa. Only fail the session when
  both sources are down; when one is up, record and surface a warning.
- **Permission denial is silent.** Both paths keep delivering callbacks with zeroed
  content when unauthorized, and Core Audio even returns `status=0` for tap and aggregate
  device creation. Never treat a success return as proof of capture — judge by amplitude.
- **Measure amplitude with `peakAmplitude()`.** It handles interleaved vs. deinterleaved
  layout and Int16/Int32/Float32. Hand-rolled `floatChannelData[0][frame]` access assumes
  a deinterleaved layout and silently misreads the interleaved process-tap buffers.
- **Record originals before resampling.** `AudioRecorder.write` must receive the capture
  buffer, not the 16 kHz mono transcription buffer, or reprocessing value is lost.
- **Append finalized segments immediately.** Do not buffer the transcript in memory until
  session end. Writing per segment is what survives an app crash; the per-segment fsync on
  top of it covers OS panic and power loss.
- **Never defer a finalized segment's write to a detached task.** Measured: reproducing that
  order lost utterances in 200 of 200 runs, with 0 persisted while 5 were on screen — the
  deferred writes hadn't started when the session closed. It fails both ways at once: the
  append hits a closed handle and the readable transcript was already rendered without that
  utterance, so the two-format redundancy does not save it. Anything that finalizes a segment
  must await the write, and stop/rotation must await the arbiter's flush — which is why the
  arbiter's decision callback is async. A segment the user read on screen must be in the
  output; arriving after the session closed is counted, never silently dropped.
- **A failed locale reservation must not block recording.** Measured with 0 reservations
  held: the audio-format query still returned `16000 Hz, Int16` and the analyzer prepared
  successfully. Reservation only keeps macOS from reclaiming a model mid-session, so treat
  its failure as a warning whenever the model is already installed, and fail the session
  only when the model is absent (nothing to hold the download with). Reclaim this app's own
  leftover reservations and retry before giving up — reservations outlive the process
  (measured: a locale reserved in one run was still listed by a separate run), so a crash
  otherwise eats the quota until the next launch.
- **Never infer a reservation failure's cause.** Discarding the thrown error and reporting
  "reservation limit exceeded" produced a measured misdiagnosis: the limit is 5, the app
  needs at most 2, and the device had **0** reservations when it claimed the limit was hit.
  The limit is per app (measured: with one app holding 5 of 5, another still reserved
  successfully), so this app alone cannot reach it. Carry the reason macOS gave —
  `SFSpeechErrorDomain` code 11 is the real limit error — plus the requested and
  currently-reserved locales, or the next occurrence is undiagnosable too.
- **Judge a reservation by the reserved list, not by the return value.** `reserve` is
  set-semantics and returns `false` for an already-reserved locale (measured), so reading
  the return value as failure makes every session after the first run reclaim and retry.
- **Arbitrate multilingual results per token, not per segment.** Segment-level comparison
  deletes whole utterances in code-switching meetings. See `LanguageArbiter` for the three
  rules and the measured failure cases behind them.
- **A session boundary must not stop capture.** Rotating to a new session keeps both
  capture paths running and swaps only the transcript store and audio sinks. Stopping and
  restarting instead would re-enter the model-provisioning gate and lose the opening of
  the next meeting. Rebase segment timings onto the new session before arbitration, or
  the arbiter's regions drift out of step with the segment ranges.
- **Close audio containers when rotating.** `AudioRecorder.rotate` must finish the old
  sinks before pointing at the new directory. Reusing the file handle across the boundary
  leaves the previous meeting's `.m4a` unfinalized — bytes on disk that will not open.
- **Watch the same output selector the tap targets.** macOS has two default-output
  selectors and they move independently — setting one leaves the other unchanged
  (measured: `sysOut=106 / defOut=94` after switching only the system-output selector).
  Each selector's listener fires only for its own selector, so watching
  `kAudioHardwarePropertyDefaultOutputDevice` while the tap targets
  `DefaultSystemOutputDevice` means device-change notifications never arrive. The tap and
  the monitor must read the selector from one shared source, and a test must assert they
  match — the mismatch is invisible in code review and only shows up by switching a real
  device.
- **A meeting-language change swaps the transcribers, not the session.** All three language
  configurations report the same optimal format (measured: `16000 Hz, 1ch, Int16, interleaved`
  for Korean alone, English alone, and both), so a language switch never justifies reopening
  capture — swap the analyzer's modules and leave the pump, the audio files, and the timeline
  alone. Two rules make it safe. **Verify the models are installed before touching a live
  analyzer**: adding an uninstalled locale throws, and the throw is unrecoverable — the module
  list stayed polluted afterward, setting it back to the original returned success without
  restoring anything, and the healthy locale's result stream died with the same error, taking the
  in-flight utterance with it. **Drain the pending utterance before detaching a locale**: a
  transcriber withholds a finalize far longer than expected (measured: 13.14 s in one
  un-finalized segment despite 1.5 s gaps between sentences), so detaching loses everything since
  the last finalize. You cannot force a finalize instead — the request never returns while input
  is open (measured: 90 s, and 10.4 s even bounded to audio already fed), which freezes the
  recording. The volatile result already holds that text, so persist what was on screen.
- **A device change swaps the capture, not the session.** Reconnecting keeps the pump, so
  the transcript store, audio sinks, and frame-based timeline all continue. Rebuilding the
  input stream instead would send the analyzer into teardown and re-enter the
  model-provisioning gate, losing exactly the audio around the switch. Per-source
  isolation still applies: only the affected source reconnects, and losing it does not stop
  the other.
- **Following the system default is the safe default; pinning is opt-in.** A user who
  changes nothing must still have capture follow their headset. A pinned source deliberately
  ignores default-device changes, but a pin whose device is absent falls back to the default
  *and keeps the selection* — erasing it would lose the choice when the headset is
  re-plugged, and refusing to fall back would keep capturing silence.
- **An unusable save location falls back; it never refuses to record.** The user can point the
  output root at a synced folder or an external volume, so it can be gone when a session starts.
  Recording into the default location and saying so is recoverable; declining to start loses the
  meeting, and a meeting happens once. The same asymmetry as a missing pinned device — and like
  that case, **the fallback keeps the user's choice** so reconnecting the volume restores it.
  Judge the folder by trying to create it and checking writability, not by the stored path
  existing: a detached volume leaves the path behind. **Resolve the root once per session and
  reuse it across a session boundary** — re-resolving at the boundary splits one meeting's
  successor into a different folder mid-recording. The app never moves or deletes the user's
  existing output: a half-finished move of a meeting that cannot be re-recorded is worse than
  transcripts living in two folders.
- **Resolve a device UID by the returned device number, not the status.**
  `kAudioHardwarePropertyTranslateUIDToDevice` returned `status=0` for a UID that does not
  exist and handed back device `0`. Trusting the status opens capture on device zero, which
  fails silently — the same class of lie as the tap and the listener removal below. Store the
  UID rather than the `AudioObjectID`, which is reassigned every launch.
- **Filter the device list by direction.** A measured machine had input-only, output-only,
  and bidirectional devices side by side (7 devices: 3 input-only, 2 output-only, 2 both).
  Offering an output-only device as a microphone fails the moment it's chosen. Virtual
  devices created by meeting apps are listed on purpose — capturing only the meeting app's
  output is a real configuration.
- **Set the microphone's device before reading its format.** `AVAudioEngine` only uses the
  default input, so pinning goes through the underlying audio unit. Changing the device
  changes the channel count with it (measured: built-in 1ch → USB headset 2ch), so reading
  the format first installs a tap in the previous device's format. Read back the property
  after setting it — success alone isn't proof it applied.
- **Core Audio listener removal does not take effect.**
  `AudioObjectRemovePropertyListenerBlock` returned `status=0` and the callback still fired
  twice on the next device switch; calling it three times in a row behaved identically, and
  pinning the block via `@convention(block)` changed nothing. This is the same class of lie
  as the tap returning `status=0` without permission. Gate delivery behind an explicit
  active flag rather than trusting removal, or notifications arriving after stop will reopen
  captures that were already torn down.
- **Never let a window size itself from content that sizes itself from the window.** Pairing
  `NSHostingController.sizingOptions = .preferredContentSize` with a root view that uses
  `.fixedSize(vertical:)` is a feedback loop: the view asks for a height, the window resizes, the
  resize re-runs layout. Measured — switching settings tabs killed the app immediately with
  `NSGenericException: The window has been marked as needing another Update Constraints in Window
  pass, but it has already had more ... passes than there are views in the window`. It leaves no
  crash report (SIGTRAP through AppKit's uncaught-exception handler), so the only way to see the
  reason is to break on `objc_exception_throw`. The settings window is therefore a fixed size and
  its tabs scroll inside it — an empty strip on a short tab is better than an item that can't be
  reached, and this window has no resize handle to recover with.
- **SwiftUI's `.keyboardShortcut` does nothing in this app.** It is dispatched through the
  menu system, and a `MenuBarExtra`-only app has no main menu (measured: `NSApp.mainMenu` is
  nil, so a shortcut attached to a button never fires even while its window is key). Intercept
  the key in the window's `sendEvent` instead — that runs ahead of both the input method and
  SwiftUI's own handling. Don't fix it by building a main menu: a menu-bar app that has no
  Dock icon would then take over the system menu bar whenever it activates.
- **Match shortcuts by key code, not by character.** With a Korean input source active, the
  `charactersIgnoringModifiers` of a keyDown arrives empty, so a character comparison silently
  stops working mid-composition. The key code is layout- and input-method-independent.
- **A shortcut another app owns globally cannot be won locally.** Measured: a menu-bar utility
  had registered `⌘,` globally, this app never saw the key, and quitting that utility made it
  work immediately. That is why the settings shortcut is re-bindable — a fixed combination
  turns into a missing feature on those machines, with no way for the user to tell why.
- **The settings shortcut is deliberately not global.** It only fires while the transcript
  window is in front. Registering it globally would steal `⌘,` from every other app.
- **Use Carbon `RegisterEventHotKey` for the global shortcut.** An `NSEvent` global
  monitor requires accessibility permission (`kTCCServiceAccessibility`), which breaks the
  rule that this app asks only for microphone and audio capture.
- **Register the hotkey from the app-launch callback, not a view's lifecycle.** A
  `MenuBarExtra`'s content closure is not built until the user first opens the popover, so
  registering inside it left the shortcut dead until the menu-bar icon was clicked once —
  and because registration never ran, the existing failure notice did not surface it
  either. Anything that must work before any UI is drawn belongs in the app delegate.
- **Screen strings are translated; archive strings are not.** The interface language is
  user-selectable (Korean/English, defaulting to the system language), so every user-facing
  string needs both. The transcript file is the opposite: its speaker labels and headings are
  fixed English regardless of that setting, because the file outlives the session and other
  tools read it — the diarization plugin in this repo picks its own labels to match. If the
  archive format followed the setting, one folder would end up holding two vocabularies and a
  reader could not tell which setting produced a given file. The machine-readable speaker field
  is unchanged by all of this; only human-readable text is in scope.
- **Put both languages on adjacent lines, never in separate files.** A string that exists in
  only one language is invisible to whoever doesn't use that language, so the gap never shows up
  in development. Keeping the pair together makes a missing half a compile error instead.
- **Error messages must be translated too.** They are the part that matters most: this app's
  failures are mostly permission problems, permissions fail silently, and the message is the
  only path by which a user can fix one. A screen that is translated except when something goes
  wrong defeats the point.
- **Test wording by language, never by the machine's locale.** Assertions that hard-code Korean
  text pass or fail depending on the system language of whoever runs them. Pass the language
  explicitly, or assert the rule (two labels differ, four buttons are distinct) instead of the
  words.
- **Never fetch without the user asking.** The update check is the only network call in
  the app, and it fires only from the button press. Do not add a launch check, a periodic
  check, or a preference that enables one — even defaulted off, that turns "this app makes
  no network requests" into a claim the user has to verify in settings. The request must
  also carry nothing the app produced: no transcript, no usage counts, no device id.
- **Compare versions positionally.** String comparison ranks `0.10.0` below `0.9.0`, so a
  user on 0.9.0 is never told about the 0.10.0 release. Read the running version from the
  bundle rather than a constant in code, or the two drift apart.
- **Do not weaken Swift 6 concurrency checking** to resolve a data-race diagnostic.
  Audio callbacks run off the main actor; use the existing lock/handoff patterns.

## Build, Test, and Development Commands

- `swift build -c debug`: compile quickly with actor data-race checks enabled.
- `./build.sh release`: create and sign `build/Scribird.app`, including its `.icns` icon.
- `open build/Scribird.app`: run the locally built bundle.
- `./install.sh`: release-build and replace `/Applications/Scribird.app`; restart an
  already running copy for the new build to take effect.
- `swift test`: run the unit test suite (no network required). The device-switch
  tests do change the real default output device and restore it; they skip themselves on a
  machine with only one output device.

Run the app as a bundle rather than as a bare executable, because macOS ties microphone
and audio-capture permissions (TCC) to the bundle identifier.

**Signing matters for functionality, not just distribution.** `build.sh` prefers a real
keychain certificate (`Developer ID Application` or `Apple Development`, overridable with
`SIGN_IDENTITY`). Ad-hoc signing leaves `TeamIdentifier` empty, and while microphone
access still works, the process tap never prompts and silently yields silence. If system
audio is unexpectedly silent, check the signing identity before debugging tap
configuration.

## Coding Style & Naming Conventions

Use four spaces in Swift files and follow standard Swift API design: `UpperCamelCase` for
types, `lowerCamelCase` for properties and functions, and descriptive enum cases. Keep one
primary type per file and place code in the existing domain folder. Prefer structured
concurrency and explicit actor isolation.

Comments are in Korean, as is user-facing UI text and all error messages. Comment only
non-obvious audio, timing, permission, or language-arbitration behavior — and when the
reason is an empirical finding, record the measurement rather than just the conclusion.
That convention is why the invariants above are recoverable. No formatter or linter is
configured, so keep changes consistent with nearby code.

## Testing Guidelines

Tests must not reach the network. The update-check tests intercept `URLProtocol` and
synthesize responses; add nothing that talks to a real host. Note that `Bundle.main` under
`swift test` is the test runner, not the app, so it reports the macOS version — inject the
version being compared instead of reading the bundle.

Tests live under `Tests/ScribirdTests/` and run with `swift test`. Name XCTest methods
`test_<behavior>_<expectedResult>()` and keep them deterministic — no sleeps, no real
audio hardware, no network.

Two conventions matter more than coverage here:

- **Encode the measured failure, not a synthetic one.** Where a decision came from an
  observation (confidence values, dBFS levels, buffer layouts), feed those exact numbers
  in. A test built on invented input passes without proving the rule is needed.
- **Verify the test discriminates.** After writing a test for an invariant, break that
  invariant in the source and confirm the test fails. Several tests here initially passed
  against deliberately broken code because the input did not actually exercise the rule.

`TranscriptStore` writes under `~/Documents`, so its tests override `HOME` to a temporary
directory. Follow that pattern for anything else touching the real filesystem.

`LanguageArbiter.arbitrate` and `AudioLevelTracker` are `@MainActor`/actor-isolated; test
classes need matching isolation rather than weakened source annotations.

Hardware capture changes cannot be covered this way and require a manual smoke test:
build and install the bundle, start a recording, confirm both level meters move, speak and
play remote audio, then stop and verify `transcript.jsonl`, `transcript.md`, `me.m4a`, and
`remote.m4a` in `~/Documents/Scribird/<date_time>/`. Verify that the `.m4a` files actually
open — a container that was never finalized still has bytes on disk.

Session rotation and the global hotkey also need that manual pass, since neither the
Carbon event target nor a live capture rotation exists under `swift test`:

- While recording, press the new-session button, keep speaking, then stop. Two session
  directories must exist, each with a playable `.m4a` and a `transcript.md` whose
  timecodes start near `00:00:00` — a second meeting starting at `01:02:05` means the
  time rebase was lost.
- Press the hotkey from another frontmost app, click that app, and confirm the transcript
  window stays visible. Then set a combination already taken by another app and confirm
  the footer reports the failure instead of failing silently.
- Open settings with `⌘,`, confirm the transcript window behind it stays visible and
  recording continues, and that the audio-saving and save-location rows are disabled with a
  stated reason while recording. Then click through all three tabs and confirm the app survives
  and no tab clips its last row — the crash this guards against left no crash report, so a test
  run that never switches tabs looks clean.
- While recording, narrow the meeting language from `한국어 + English` to `한국어` in the
  transcript window. Both meters must keep moving, the `.m4a` files must keep growing, and **the
  sentence spoken just before the switch must appear in `transcript.md`** — that utterance is
  normally still un-finalized, so detaching its transcriber without draining loses everything
  since the last finalize. Confirm the settings picker shows the same language afterward.
- Press the version check with the network off and confirm it reports a failure that
  leaves recording unaffected. With the network on, confirm it distinguishes "up to date"
  from a failure — silence for either would be indistinguishable to the user.
- Switch the interface language in settings and confirm the transcript window behind it
  changes immediately — the strings come from a global, so a missing observation dependency
  leaves the window in the old language until it is reopened. Then stop a recording and confirm
  `transcript.md` still uses English speaker labels: that file must not follow the setting.
- Point the save location at another folder, record, and confirm the session lands there and
  that the footer path matches. Then point it at a removable volume, eject it, and start
  recording: it must record into the default location, say why, and still list the chosen
  folder in settings. Re-attach the volume and confirm the next session returns to it. While
  recording, confirm the location row is disabled with a stated reason — a `.m4a` split across
  two folders is the failure this prevents, and it only shows up with a live capture.

## Commit & Pull Request Guidelines

Follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):
`<type>(<scope>): <subject>`.

- **Type**: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `chore`, `style`, `ci`.
- **Scope**: `capture`, `transcription`, `session`, `archive` — the ADR categories, so a
  commit and the decision it implements name the same area. A scope is a decision area, not a
  folder: `archive` covers transcript persistence *and* the audio recorder, because one ADR
  governs both. `plugin` and `build` exist outside that mapping, having no ADR. Omit the scope
  only when a change genuinely spans everything.
- **Subject**: English, lowercase, imperative, no trailing period, ≤72 characters.
  English here while comments and ADRs stay Korean is deliberate: the log is read truncated
  and searched through `git log` and GitHub, whereas comments are read in place by whoever
  maintains the audio path.

Bodies explain *why*, and **when a change came from a measurement they include the numbers
and the failure mode that was ruled out.** Keep that standard — this history is the project's
primary record of hardware behavior, and for many of those numbers there is nowhere else
they live.

One logical change per commit. The exception is an ADR change and the code implementing it,
which belong in the same commit.

Pull requests use a commit-style title and a body covering Summary / Motivation /
Verification / Impact. Include screenshots for SwiftUI changes. Never include recorded
meeting audio or generated transcripts — commits, issues, and attachments alike.

Full rules and examples: [`CONTRIBUTING.md`](./CONTRIBUTING.md#commits).
