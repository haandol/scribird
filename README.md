<div align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Scribird" />

  <h1>Scribird</h1>

  <p><strong>A macOS menu-bar app that transcribes your meetings in real time — entirely on-device.</strong></p>

  <p>
    <a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT" /></a>
    <img src="https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg" alt="Platform: macOS 26+" />
    <img src="https://img.shields.io/badge/Swift-6.2%2B-orange.svg" alt="Swift 6.2+" />
    <a href="https://github.com/haandol/scribird/releases/latest"><img src="https://img.shields.io/github/v/release/haandol/scribird?label=release" alt="Latest release" /></a>
  </p>
</div>

Scribird writes down your Zoom or Teams meeting while it happens. Your microphone is
labeled **me**, whatever comes out of your speakers is labeled **remote**, and when the
meeting ends you are left with a transcript and the meeting audio in a single folder.

Transcription and storage both happen on your machine. **Neither the meeting audio nor the
transcript ever leaves the device.** macOS may download the mandatory English Speech asset
at launch, and the app checks for releases only when you press *Check for updates* — see
[Network use](#network-use).

The interface is available in **Korean and English**, following your system language by default
and switchable in settings. The screenshots below use the English interface and fixed,
non-identifying mock meeting data rendered by the real SwiftUI components.

> [!NOTE]
> A separate, opt-in [plugin](#optional-splitting-remote-into-individual-speakers) for Claude
> Code and Codex can split *remote* in legacy source-separated sessions into individual
> participants afterwards. It sends the saved audio to **your own** AWS account, so it is
> deliberately outside the app. Scribird itself only asks macOS for the mandatory English
> Speech asset at launch; release lookup remains user-initiated.

<div align="center">
  <img src="docs/images/transcript.png" width="520" alt="Scribird transcript window in English: recording status, microphone mute control, per-source level meters, and a mock conversation with Me aligned right and Remote aligned left" />
</div>

*Me* is aligned right, *Remote* is aligned left, and the two use different colors. The `EN`
badge shows which language each utterance was recognized in. The last line is dimmed because
it is still volatile — the moment it is finalized it sharpens and is written to disk.

## Features

|  | |
|---|---|
| **Automatic speaker attribution** | Microphone is *me*, system output is *remote*. The audio path decides the speaker, so there is nothing to infer and nothing to get wrong |
| **Live transcription** | Volatile text appears dimmed while you speak and sharpens once finalized. Finalized text is written to disk immediately |
| **Korean + English** | Both languages are recognized at once. Code-switching meetings keep both sides thanks to token-level arbitration |
| **Switch language mid-meeting** | Pick any installed meeting language from the transcript window while recording. The audio and transcript continue — only the transcribers change |
| **Meeting audio kept** | Microphone and system output are mixed live into one mono `meeting.m4a` for natural playback and later re-transcription |
| **Silent failures surfaced** | A denied permission raises no error; it just delivers silence. Scribird judges by amplitude and warns you mid-recording |
| **Input level meters** | Per-source dBFS in real time with the recommended range marked, so you don't find out after the meeting |
| **Per-meeting session boundaries** | Starting a new meeting swaps the output files without interrupting capture — you don't lose the opening of the next meeting |
| **Follows device changes** | Plug in a headset mid-meeting and capture moves with it, without splitting the transcript or the audio files |
| **Or pin a device** | Choose a specific microphone or output device per source and capture stays there, even when the system default moves |
| **Korean or English interface** | The screen follows your system language and can be switched in settings. Transcript files keep English speaker labels either way, so tools reading them see one vocabulary |
| **Shortcuts** | `⌥⌘S` brings up the transcript window globally. While Scribird has focus, the configurable microphone-mute shortcut (default `⌘Y`) toggles only your microphone |

## System Requirements

macOS 26 or later, on Apple silicon or Intel. The on-device `SpeechAnalyzer` API that
Scribird is built on does not exist on earlier releases, so there is no back-deployed
build.

The English language model is mandatory. If it is missing, macOS downloads it when Scribird
starts. Korean is optional and can be installed from settings.

## Installation

### From a release

Download `Scribird-<version>.zip` from the
[latest release](https://github.com/haandol/scribird/releases/latest), unzip it, and move
`Scribird.app` into `/Applications`.

> [!IMPORTANT]
> **These builds are not notarized.** On macOS 26, Gatekeeper can show an alert with only
> *Move to Trash* and *Done*; right-clicking the app and choosing *Open* may still be blocked.
> After confirming that the ZIP came from this repository's release page and that its
> SHA-256 matches the release notes:
>
> 1. Move `Scribird.app` to `/Applications` and try to open it once.
> 2. In the warning, click **Done** — not *Move to Trash*.
> 3. Open System Settings › Privacy & Security, scroll down to **Security**, and click
>    **Open Anyway** next to Scribird.
> 4. Authenticate, then confirm **Open** when macOS asks again.
>
> This creates an exception for this copy of Scribird. Do not disable Gatekeeper globally or
> remove quarantine metadata from an app whose source and checksum you have not verified.
> See Apple's [guidance for opening an unnotarized app](https://support.apple.com/102445).
> A build made locally from source does not normally need this override.

### From source

You need a Swift 6.2+ toolchain and macOS 26 (verified on Swift 6.3.3 / macOS 26.5.2).

```bash
git clone https://github.com/haandol/scribird.git
cd scribird
./install.sh          # release-build, then replace /Applications/Scribird.app
```

To build and run it in place instead:

```bash
./build.sh release
open build/Scribird.app
```

It has to be wrapped in an `.app` bundle and code-signed. A bare executable cannot obtain
microphone or audio-capture permission, because macOS ties permissions (TCC) to the bundle
identifier.

> [!WARNING]
> **Signing is a functional requirement here, not a distribution one.** `build.sh` looks for
> a `Developer ID Application` or `Apple Development` certificate in your keychain (override
> with `SIGN_IDENTITY`). Without one it falls back to ad-hoc signing, which leaves
> `TeamIdentifier` empty — and in that state system-audio capture never prompts and silently
> delivers nothing but silence. If the remote voice isn't picked up, check the signing
> identity before you debug anything else.

## How to use it

1. Click the waveform icon in the menu bar, or press `⌥⌘S`, to bring up the transcript window.
2. Wait for the English model to show as installed, then press **Start**.
3. Check that both level meters move — a meter that doesn't move means that source isn't arriving.
4. When the meeting changes, press **✎** to cut the transcript. Capture is not interrupted.
5. Press **Stop**. It wraps up within 6 seconds and shows a link to the output folder.

### Reading the level meters

The shaded band is the recommended range, **-24 to -3 dBFS**. Below -24 the source is too
quiet to be worth re-listening to later; above -3 it is clipping. If a source stays silent
past its grace period — 4 seconds for the microphone, 8 for system output, because a
meeting may genuinely have nothing playing yet — the meter is replaced by the likely cause
and a link to the relevant System Settings pane.

### Settings

Everything you set once and forget lives in the settings window (`⌘,`), split across three tabs
by what the setting is *about* — **General** (interface language, both hotkeys, the update check),
**Recording** (language models, meeting language, plus what the output contains and where it goes), and **Device**
(which microphone and which output device to capture). The transcript window keeps only what you
look at during a meeting.

**The meeting language is in both places on purpose.** You set it before a meeting in settings,
but you find out it was wrong *during* one — a missing utterance is the signal — so the transcript
window carries the same picker. Changing it there does not interrupt anything: capture keeps
running, `meeting.m4a` keeps growing, and the transcript continues in the same file. Only
installed language combinations appear. Install Korean from settings before selecting Korean
or Korean + English.

**The interface is available in Korean and English.** It follows your system language unless
you pick one, and picking one keeps it even if the system language later changes. Note that this
is separate from the *meeting* language — you can read an English interface while recording a
Korean meeting, or the reverse. Speaker labels inside `transcript.md` are always English
regardless of this setting, because that file is read later by other tools and its vocabulary
should not depend on a preference.

<div align="center">
  <img src="docs/images/settings.png" width="480" alt="Scribird Recording settings in English: English installed, Korean available to install, meeting audio enabled, and the transcript folder" />
</div>

The Recording tab shows model status per language. English is mandatory and installed
automatically when absent; Korean remains optional and is installed from this screen. During
recording, settings that would contradict live transcribers or open file handles are disabled
with an explanation. **Capture devices stay editable while recording**, because that's exactly
when you notice you picked the wrong one. The folder-opening toggle and interface language also
stay editable because they do not alter the live capture or archive.

## Where your data goes

Each session gets its own directory, named for the moment it started:

```
~/Documents/Scribird/2026-07-31_142530/
```

**You can put that folder somewhere else.** Settings → Save location lets you pick any folder —
a synced folder so meetings reach your other machines, an external volume, or an encrypted disk.
Pick nothing and it stays where it is above. Two things to know: existing transcripts are **not**
moved when you change it (the app never relocates your files — a half-finished move of a meeting
you can't re-record is worse than two folders), and if the folder you picked is gone at the
moment you start recording — an unplugged drive — Scribird records into the default location
instead and tells you so. It does not refuse to record, because a meeting happens once.

**The transcript window always shows where recordings are stored**, so you can confirm one is
actually being saved without waiting for it to end. Click it to open that folder. What it
points at follows the app's state — the session being written to while recording, the last one
after stopping, and the root above them before you've recorded anything — and the label says
which of the three you're looking at.

When a recording stops, that session's folder opens on its own, and the transcript window steps
behind it — it floats above other apps so a meeting can't hide it, but not above something you
just asked for. Click the transcript window to bring it back above everything. Turn the
auto-opening off in settings if you record back-to-back meetings and don't want the window.
Starting a *new session* mid-meeting does not open anything, since you're still in the meeting.

| File | Contents |
|---|---|
| `transcript.jsonl` | One finalized utterance per line (speaker, timestamp, confidence, language), flushed as soon as it is finalized |
| `transcript.md` | Readable transcript, grouped by speaker |
| `meeting.m4a` | Microphone and system output mixed live into one 48 kHz mono AAC file |

`meeting.m4a` is only written when *Save meeting audio* is on, which
is the default. Nothing here is ever pruned or rotated — the folder grows until you delete
from it.

### Network use

When the mandatory English Speech asset is absent, Scribird asks macOS to install it at
launch. Korean is downloaded only after you press its install button in settings. These
system asset requests never include meeting audio, transcripts, usage counts, or a device
identifier.

The release lookup behind *Check for updates* fires only from that button
press. There is no launch or periodic release check. Scribird never downloads an update
either — it points you at the release page. Release downloads are not notarized, so follow
the first-launch steps in [Installation](#from-a-release).

## Optional: splitting *remote* into individual speakers

Because a meeting app mixes participants down before Scribird ever sees them, *remote* is one
label for everyone on the far side.

[`plugin/scribird-diarize`](./plugin/README.md) is a Claude Code plugin that does exactly that.
It currently supports legacy sessions that contain `remote.m4a` and `me.m4a`; current
`meeting.m4a` sessions are not source-separated and are not accepted by this workflow. For
legacy sessions it sends `remote.m4a` to Amazon Transcribe for speaker partitioning and overlays only the speaker
boundaries onto the transcript you already have, splitting the single `상대방` label
(*remote*, as the app writes it) into actual participant names when evidence supports them,
or `Unknown 1` / `Unknown 2` otherwise:

```
Before   [상대방]   00:12  Let's ship on Tuesday next week, then.
         [상대방]   00:18  I'd prefer the week after. QA needs the time.

After    [Alice]     00:12  Let's ship on Tuesday next week, then.
         [Unknown 2] 00:18  I'd prefer the week after. QA needs the time.
```

> [!WARNING]
> **This sends meeting audio to Amazon Transcribe under your own AWS account.** That is the
> opposite of how the app works, which is why it lives outside the app and never runs on its
> own. It uses your local `aws` credentials, prints exactly what it is about to send, and
> refuses to proceed until you confirm.
>
> The plugin uploads the saved M4A to a private S3 location and runs an Amazon Transcribe batch
> job. It states the required AWS permissions and temporary storage location before asking for
> approval, and deletes the job objects after a successful run unless you explicitly keep them.

### Prerequisites

| | Check |
|---|---|
| [Claude Code](https://claude.com/claude-code) or [Codex](https://developers.openai.com/codex/cli) | `claude --version` / `codex --version` |
| AWS CLI with working credentials | `aws sts get-caller-identity` |
| A region set | `aws configure get region` |
| Python 3 | already there — macOS ships `/usr/bin/python3`, and nothing needs `pip install` |

The batch path needs `s3:CreateBucket`, `s3:PutBucketPublicAccessBlock`, `s3:PutObject`,
`s3:GetObject`, `s3:DeleteObject`, `s3:ListBucket`,
`transcribe:StartTranscriptionJob`, and `transcribe:GetTranscriptionJob`.

### Install

The repository doubles as a plugin marketplace for both agents. Register it, then install the
plugin from it — substitute the path where you cloned this repository.

**Claude Code**

```bash
claude plugin marketplace add ~/git/scribird
claude plugin install scribird-diarize@scribird
```

Inside a session, `/plugin marketplace add ~/git/scribird` then picking it from `/plugin` does
the same thing. Invoke it with `/multi-speaker-diarize` or just describe the task.

**Codex**

```bash
codex plugin marketplace add ~/git/scribird
codex plugin add scribird-diarize@scribird
```

Invoke it with `$multi-speaker-diarize` or describe the task. Verify with
`codex plugin list`, which should show `scribird-diarize@scribird` as *installed, enabled*.

Both read the same skill; the two `plugin.json` files differ only in the metadata each agent
expects. Once this repository is on GitHub you can also register it remotely — with
`claude plugin marketplace add haandol/scribird` or `codex plugin marketplace add
haandol/scribird` — which is the same marketplace fetched over Git instead of read from disk.

### Use it

Just ask, in either agent:

```
split the remote speaker in ~/Documents/Scribird/2026-07-31_142530 by participant
```

The agent picks the session, reads the language out of your existing transcript, shows you what
is about to be sent, and waits. Nothing leaves the machine until you say yes. It then reports
how many speakers were found and which words the two engines heard differently. Before analysis,
it asks for the participant count and names you know. Names and optional role hints stay local;
verified matches are applied, and every unresolved speaker receives a stable `Unknown N` name
instead of failing the merge.

You can also run the scripts directly, which is useful when you want to see the exact steps:

```bash
cd plugin/scribird-diarize/skills/multi-speaker-diarize
SESSION=~/Documents/Scribird/2026-07-31_142530

# 1. Print the plan and stop (exit 3). Nothing has been sent yet.
/usr/bin/python3 scripts/run_transcribe.py \
  --session "$SESSION" --language-code ko-KR --max-speakers 5

# 2. Approve and run it.
/usr/bin/python3 scripts/run_transcribe.py \
  --session "$SESSION" --language-code ko-KR --max-speakers 5 --yes

# 3. Overlay the speaker boundaries onto your transcript.
/usr/bin/python3 scripts/merge_speakers.py --session "$SESSION" --aws-remote "$SESSION/aws-remote.json"

# 4. Optionally apply locally verified participant names.
/usr/bin/python3 scripts/merge_speakers.py \
  --session "$SESSION" \
  --aws-remote "$SESSION/aws-remote.json" \
  --speaker-names "$SESSION/speaker-names.json"
```

### What you get

Three new files land next to the originals, which are never modified:

| File | Contents |
|---|---|
| `transcript.speakers.md` | The readable transcript, now split by speaker. Body text is still your on-device transcript |
| `transcript.speakers.jsonl` | Machine-readable. Keeps the original `me`/`remote` in a `source` field, so the certain two-way split is always recoverable |
| `diarization-report.md` | How many speakers, how much each one talked, and every word the two engines wrote differently |

When participant names are provided, `speaker-names.json` remains local and records the evidence
used for verified names and candidates. Invalid or conflicting entries are reported as warnings;
they do not prevent the three result files from being generated.

### Two properties worth knowing

These are what make the result trustworthy:

- **The `me` / `remote` split is never re-derived.** That one came from the audio path and
  cannot be wrong; only the *inside* of `remote` is estimated. `me.m4a` is not sent at all
  unless you ask for it, since a microphone's speaker is already settled. (Pass
  `--sources remote,me` when the meeting was in-person and other voices reached your mic.)
- **Your on-device transcript stays the transcript.** Amazon Transcribe is called for speaker
  boundaries, not for text. Where the two engines disagree on a word, the difference is
  reported rather than silently applied — deciding which one is right needs meaning, and the
  script doesn't claim to have it.

### Batch behavior

The plugin has one cloud-analysis path: upload to S3 and run an Amazon Transcribe batch job.
It can set `--max-speakers` from 2–30 and use multi-language identification. A missing bucket
is created with public access blocked; successful runs delete their per-run objects by default.
There is no streaming fallback.

See [`plugin/README.md`](./plugin/README.md) for the full option list and the reasoning behind
each default.

## Permissions

Two things have to be allowed on first launch. **Screen-recording permission is never
requested**, and neither is accessibility.

| Permission | System Settings pane | Used for |
|---|---|---|
| Microphone | Privacy & Security › Microphone | Transcribing what you say |
| Audio Recording | Privacy & Security › Audio Recording | Transcribing the remote voices |

If one of the two is missing, the other keeps working. Microphone transcription still runs
without a meeting app open, and your own speech is still recorded without audio-capture
permission. The session is only abandoned when both sources fail.

## Preferences Storage

Everything in the settings window persists across launches. Preferences live in
`~/Library/Preferences/com.scribird.app.plist` under the `com.scribird.app` domain:

```bash
defaults read com.scribird.app
```

| Key | Setting | Default |
|---|---|---|
| `interfaceLanguage` | Interface language | unset (follow system language) |
| `transcriptionLanguage` | Meeting language | `english` |
| `savesOriginalAudio` | Save original audio | `true` |
| `pinnedInputDeviceUID` | Pinned microphone | unset (follow system default) |
| `pinnedOutputDeviceUID` | Pinned output device | unset (follow system default) |
| `transcriptRootPath` | Save location | unset (use the default folder) |
| `hotKeyCode`, `hotKeyModifiers` | Global hotkey (show transcript) | `⌥⌘S` |
| `settingsHotKeyCode`, `settingsHotKeyModifiers` | Open settings | `⌘,` |

Window positions and the menu-bar item position are stored in the same domain by AppKit.
A value that can't be interpreted falls back to its default rather than failing to start a
recording — deleting the whole domain resets every setting:

```bash
defaults delete com.scribird.app
```

> [!NOTE]
> Because these persist, a setting you changed once stays changed. If original-audio saving
> was turned off in an earlier session, no `.m4a` files appear in later ones. The current
> language is always readable in the transcript window's header for that reason.

## Troubleshooting

Start with the cheap checks; each one rules out a whole class of cause.

1. **Are both level meters moving?** A meter that never moves means that source is not
   arriving at all — that is a permission or device problem, not a transcription problem.
2. **Is anything actually playing?** System-audio capture taps the output device. If the
   meeting app is routing to a headset that isn't the system default output, Scribird
   won't see it.
3. **Check the signing identity.** An ad-hoc-signed build silently yields silence on the
   system-audio path:
   ```bash
   codesign -dv /Applications/Scribird.app 2>&1 | grep TeamIdentifier
   ```
   An empty or missing `TeamIdentifier` is the problem. Rebuild with a real certificate.
4. **Confirm the permission is actually granted**, in System Settings › Privacy & Security
   under both *Microphone* and *Audio Recording*.

For permission resets, device-switching problems, model download failures, and the rest,
see **[docs/Troubleshooting.md](./docs/Troubleshooting.md)**.

## Known limitations

All of these came out of measurement or are direct consequences of a design decision.
Knowing them up front saves some surprise.

- **Speaker separation tops out at *me* vs. *everyone remote*.** Individual participants are
  not distinguished. Apple Speech has no diarization API, and meeting apps mix participants
  down to a single stream before handing it to Core Audio. That is exactly why the original
  audio is kept per source — see
  [splitting *remote* afterwards](#optional-splitting-remote-into-individual-speakers) for an
  opt-in tool that does it, at the cost of leaving the device.
- **Remote audio recognizes less accurately.** The remote voice has already been through a
  codec and been played back. It is especially noticeable in Korean.
- **Switching devices costs a moment of audio.** Scribird follows the default input and
  output device while recording, so plugging in a headset right before or during a meeting
  keeps transcription going — but the audio during the reconnect itself is not captured, and
  cannot be recovered. A notice names the device it moved to so the gap isn't mistaken for
  silence in the meeting.
- **A pinned device stops following the system.** That's the point of pinning, but it means
  plugging in a headset won't move a pinned source. Settings states which device each source
  is on, and if a pinned device is absent Scribird falls back to the system default and says
  so — the pin itself is kept, so reconnecting the device restores it.
- **If the meeting is monolingual, picking that one language is more accurate.** In a
  multilingual configuration, utterances at a code-switching boundary can be clipped short.
  Choosing a single language skips the arbiter entirely, so that loss doesn't occur.
- **Language and original-audio saving are locked while recording.** Changing them would
  contradict the transcribers and file handles that already exist.
- **Stop completes within 6 seconds.** The transcript and audio files must be saved even if
  one transcriber stops responding, so past that deadline the remaining tasks are cancelled
  and whatever was secured is written out.
- **App Sandbox is off.** That is convenient for working with Core Audio taps and for keeping
  transcripts in Documents. Targeting the App Store would mean turning it on and adjusting
  the file-access scope.

Zoom and Scribird *can* share the microphone — macOS input devices are multi-client, so the
mic opens even while a meeting app is using it. Note that the meeting app's echo
cancellation can change the characteristics of the microphone signal.

## Uninstallation

```bash
rm -rf /Applications/Scribird.app
defaults delete com.scribird.app
tccutil reset Microphone com.scribird.app
tccutil reset AudioCapture com.scribird.app
```

> [!TIP]
> Your meetings are **not** removed by any of the above. Transcripts and audio stay in
> `~/Documents/Scribird/` — or wherever you pointed the save location — until you delete them
> yourself, which is deliberate — an uninstall should not throw away a meeting record.

---

## How it works

The key to speaker separation is splitting the audio **before** anything is mixed.

```
Microphone in  ──→ AVAudioEngine tap       ──→ SpeechAnalyzer #1 ──→ [me]     ─┐
                                                                               ├─→ TranscriptTimeline ─→ JSONL + Markdown
System output  ──→ Core Audio Process Tap  ──→ SpeechAnalyzer #2 ──→ [remote] ─┘
   (whatever Zoom/Teams plays back)
```

Sound arriving through the microphone is necessarily me, and sound the system plays back is
necessarily someone else. Giving each source its own `SpeechAnalyzer` makes the speaker
label a fact rather than an inference.

System audio comes from a **Core Audio process tap** rather than ScreenCaptureKit because
of permissions. ScreenCaptureKit checks screen-recording permission
(`kTCCServiceScreenCapture`) even when all you want is audio — its entry point
`SCShareableContent` is an API that returns a list of windows and displays, and that is also
the only TCC service its backing daemon `/usr/libexec/replayd` references. Calling it from a
bundle that declares only `NSAudioCaptureUsageDescription` fails with `-3801
(userDeclined)`. A process tap uses `kTCCServiceAudioCapture` and nothing else.

The reasoning behind each decision and the alternatives that were rejected are recorded in
the repository's ADR index. If you want to know *why* something is the way it is, that is the
primary source. The ADRs are written in Korean.

## Contributing

Issues and pull requests are both welcome. See **[CONTRIBUTING.md](./CONTRIBUTING.md)** for
the build commands, the manual smoke test that hardware changes require, the ADR-first
workflow, and the commit conventions.

Two things are worth knowing before you start:

- The **[architecture invariants](./AGENTS.md#architecture-invariants)** in `AGENTS.md` were
  each established by measurement. Read them before touching the capture or transcription
  path — undoing one reintroduces a bug that is hard to notice.
- **Never commit recorded meeting audio or generated transcripts.**

To report a security issue, see [SECURITY.md](./SECURITY.md).

## Credits

Built on Apple's on-device `SpeechAnalyzer` and Core Audio process taps. The app icon is in
[`Resources/AppIcon.png`](./Resources/AppIcon.png) and is regenerated into `.icns` at build
time by `build.sh`.

## License

[MIT](./LICENSE)
