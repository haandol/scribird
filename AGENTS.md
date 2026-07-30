# Repository Guidelines

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
- **Use Carbon `RegisterEventHotKey` for the global shortcut.** An `NSEvent` global
  monitor requires accessibility permission (`kTCCServiceAccessibility`), which breaks the
  rule that this app asks only for microphone and audio capture.
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
- `swift test`: run the unit test suite (158 tests, no hardware or network required).

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
  recording continues, and that the language and audio-saving rows are disabled with a
  stated reason while recording.
- Press the version check with the network off and confirm it reports a failure that
  leaves recording unaffected. With the network on, confirm it distinguishes "up to date"
  from a failure — silence for either would be indistinguishable to the user.

## Commit & Pull Request Guidelines

Commit subjects are short and in Korean, for example `입력 레벨 미터 추가 및 조용한 캡처
실패 노출`. Bodies explain *why*, and when a change came from a measurement, they include
the numbers and the failure mode that was ruled out. Keep that standard — it is the
project's primary record of hardware behavior.

Pull requests should explain behavior changes, list verification commands, note permission
or storage impacts, and include screenshots for SwiftUI changes. Never include recorded
meeting audio or generated transcripts.
