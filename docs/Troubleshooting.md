# Troubleshooting

Scribird's failure modes are unusual, because the two APIs it depends on **fail silently
when unauthorized**. A denied microphone permission still delivers audio callbacks — filled
with zeros. Core Audio goes further and returns `status=0` for both tap and aggregate-device
creation without any capture permission at all. In one measured session: tap `status=0`,
aggregate `status=0`, 374 callbacks delivered, zero non-zero samples, peak amplitude
`0.00000`.

That is why the level meters exist, and why they are the first thing to check. Nothing else
distinguishes "recording fine" from "recording silence".

## Quick fixes — try these first

### 1. Are both level meters moving?

A meter that never moves means that source is not arriving **at all**. That is a permission
or device problem, not a transcription problem, and no amount of waiting will fix it.

Scribird gives each source a grace period before it accuses anything — 4 seconds for the
microphone, 8 for system output, because a meeting may genuinely have nothing playing yet.
Past that, a silent source is replaced in the UI by the likely cause plus a button that
opens the relevant System Settings pane.

### 2. Is anything actually playing?

System-audio capture taps the **default output device**. If the meeting app routes audio to
a headset that isn't the system default output, Scribird never sees it. Check System
Settings › Sound › Output against what you're actually listening through.

### 3. Check the signing identity

An ad-hoc-signed build has an empty `TeamIdentifier`, and in that state the process tap
never prompts for permission and silently yields silence:

```bash
codesign -dv /Applications/Scribird.app 2>&1 | grep TeamIdentifier
```

Expected output is a real team ID. If the line is missing or empty, rebuild with a keychain
certificate:

```bash
security find-identity -v -p codesigning     # confirm you have one
./install.sh                                  # build.sh picks it up automatically
```

Microphone capture still works under ad-hoc signing, which makes this failure look
source-specific: *me* transcribes and *remote* doesn't. Check the signature before you
suspect the tap configuration.

### 4. Confirm the permission is actually granted

System Settings › Privacy & Security, under **both** *Microphone* and *Audio Recording*.
Scribird must be listed and enabled in each. It appears in *Audio Recording*, not *Screen
Recording* — Scribird never requests screen recording.

## Diagnose by symptom

### Only my own voice is transcribed

The system-audio path is down. In order of likelihood:

1. Ad-hoc signature (see above) — silent, and the most common cause on a self-built app.
2. *Audio Recording* permission not granted.
3. The meeting app is not routing through the default output device.
4. Nothing is playing yet — the transcript starts when the other side speaks.

### Only the remote voices are transcribed

The microphone path is down: *Microphone* permission not granted, no input device
available, or the input device is muted at the hardware level. Scribird surfaces a warning
for this rather than failing, because a half-working session is still worth recording.

### Both meters move, but the transcript stays empty

That is a transcription problem, not a capture problem. Check:

- **The English model finished installing.** It is mandatory and macOS downloads it when the
  app starts if needed. Settings shows *Downloading* and a retry action rather than an
  unreliable percentage; recording stays disabled until English is installed.
- **The language matches.** If the meeting is in Korean but English is selected, recognition
  quality collapses rather than erroring.
- **Levels are high enough.** Below roughly -50 dBFS the utterance gate never opens. The
  meters shade the recommended range, -24 to -3 dBFS.

### The recording is audible but transcribes poorly

Peak level can look fine while the overall recording is far too quiet. In a measured case
the peak was -11.6 dBFS — perfectly normal — while the speech-interval average was -47.6
dBFS. Scribird judges this by the average, not the peak, and warns when it drops below -30
dBFS. Raise the input volume in System Settings › Sound › Input rather than expecting
Scribird to compensate; original audio is never gain-corrected, deliberately, so
re-transcription sees exactly what was captured.

Remote audio also recognizes less accurately in general — it has already been through a
codec and been played back. This is especially noticeable in Korean.

### The model download fails or the language can't be selected

The on-device model is downloaded and installed by macOS, not by Scribird. The messages you
might see here mean different things:

- **"이 기기에서 지원하지 않습니다"** — macOS does not offer that locale for on-device
  transcription on this hardware. Nothing Scribird can do.
- **"언어 모델을 붙잡아 두지 못한 채 녹취합니다"** — a warning, not a failure. Recording and
  transcription continue on the already-installed model. The only risk is that macOS reclaims
  the model mid-meeting, which would stop transcription partway through; restart the recording
  if you'd rather not take that chance on a meeting that matters.
- **"…확보하지 못했고 모델이 아직 설치되지 않아…"** — the model is not installed *and* could
  not be held for download, so there is nothing to transcribe with. The message carries the
  reason macOS gave along with which locales were held at the time.

macOS caps how many locales can be held at once, but the cap is per app, and Scribird needs
only the ones you selected — so it can't reach the cap on its own. Leftover reservations from
a crash can occupy the quota, and Scribird reclaims its own before retrying, so quitting and
relaunching is not a fix you should need.

**Read the reason in the message rather than assuming the limit was hit.** A reservation
failure alone does not prevent transcription when the model is already installed, and an
older version of this app reported "the reservation limit was exceeded" for unrelated
failures — including on machines holding no reservations at all.

#### A model stays on *Downloading*, or Korean disappeared after working before

Scribird 0.1.8 and later treats installation and model reservation as separate operations.
It waits for the macOS installation request and verifies the final installed-locale list;
it does not cancel the request because the reported percentage stopped changing.

Older builds could cancel a stalled-looking `Progress` object. On macOS 26.6.1 that
cancellation unsubscribed `transcription.ko`, reduced the active Speech asset set from
English + Korean + metadata to English + metadata, and removed an already-installed Korean
model. The measured Korean download was 132,120,576 bytes, with a 170,065,920-byte installed
footprint.

The same cancellation can leave MobileAsset with a pending set job. The UI then says
*Downloading*, but system logs show zero transferred bytes and a request queued behind a
job that is still being cancelled. Low disk space may make asset management more aggressive,
but it was not the direct cause in the measured case: macOS reported
`filesystemSpaceCritical: N`.

Try this recovery in order:

1. Quit Scribird completely.
2. Restart the Mac. This is the safest way to restart the system-owned Speech asset services.
3. If restarting the Mac is impractical, restart only the two root-owned asset daemons:

   ```bash
   sudo killall mobileassetd
   sudo killall assetsubscriptiond
   ```

   `launchd` starts them again automatically. Do not delete anything under
   `/System/Library/AssetsV2`; that is macOS-owned state shared with other system features.
4. Open Scribird, go to Settings › Recording, and press **Install** for Korean once. Leave the
   request running even if no percentage appears.

Installation is complete only when Settings says **Installed** and the meeting-language
picker adds **Korean** and **Korean + English**. For an advanced check, the installed locale
list returned by macOS must contain `ko_KR`; the presence of a Korean manifest alone does not
mean the model is installed.

### Audio stops being captured mid-meeting

Scribird follows the default input and output device while recording, so a headset plugged in
mid-meeting should recover on its own within about a second, with a notice naming the device
it moved to. The audio during the reconnect is lost and can't be recovered — that gap is
expected, not a malfunction.

If capture does **not** come back:

1. **Check the level meter, not the transcript.** If the meter is moving, capture recovered
   and the problem is elsewhere.
2. **Check whether that source is pinned.** Open `⌘,` › 캡처 장치. If a specific device is
   selected instead of *시스템 기본*, that source deliberately ignores system-default changes.
   Switch it back to *시스템 기본*, or pick the device you're actually using — you can do this
   while recording.
3. **Confirm the new device is the system default output** in System Settings › Sound ›
   Output. When following the default, Scribird tracks that setting; it does not follow
   whichever device a particular app chose for itself.
4. **Look for a notice saying the reconnect failed.** Scribird reports that rather than
   failing quietly, and it keeps the other source running. Stop and start again to pick the
   device up cleanly.

A device that disappears entirely (unplugged, powered off) leaves that one source down while
the other keeps transcribing. Only losing both ends the session.

### The transcript window won't come up with the hotkey

Another app already owns that combination. Registration failure is reported in the settings
window's shortcut row rather than failing silently — open `⌘,` and look there. Pick a
different combination; anything with no modifier, or Shift alone, is rejected because it
would intercept ordinary typing.

If the hotkey does nothing *and* no error appears, use the menu-bar icon instead — that path
always works and is the reason it's kept.

### An `.m4a` won't open

A container that was never finalized still has bytes on disk. This should not happen —
Scribird verifies each file is readable when closing it — but if it does, the file was
interrupted by a crash or power loss. `transcript.jsonl` will still be complete up to the
last finalized utterance, because it is appended and fsynced per segment rather than
buffered until the end.

### The transcript isn't in the folder I chose

Scribird records into the default location when the folder you picked can't be written at the
moment a session starts — an ejected drive or a deleted synced folder. It shows a notice when
that happens, but if you missed it, look at the path in the transcript window footer: that is
always where the session actually went, not where you pointed it.

Your choice is **not** erased by the fallback. Re-attach the volume and the next session returns
to it — no need to pick the folder again. Verify with:

```bash
defaults read com.scribird.app transcriptRootPath
```

If that path is on a volume that isn't mounted, that's the cause. Sessions recorded before you
changed the location stay in the old folder — Scribird never moves existing transcripts, so a
half-finished move can't lose a meeting you can't re-record. Check both places if a meeting seems
missing.

## Check for conflicts

- **Zoom, Teams, and Scribird can share the microphone.** macOS input devices are
  multi-client, so the mic opens even while a meeting app has it. But the meeting app's echo
  cancellation changes the microphone signal's characteristics, which can affect both level
  readings and recognition.
- **Other system-audio capture tools** (virtual audio devices, loopback drivers, other
  recorders) can change what the default output device is. If one is installed, verify the
  default output is what you expect.

## Advanced

### Reset permissions and re-prompt

If Scribird is stuck in a state where it never prompts, clear its TCC decisions and relaunch:

```bash
tccutil reset Microphone com.scribird.app
tccutil reset AudioCapture com.scribird.app
```

The next launch prompts fresh. Note that `tccutil reset` with no bundle identifier resets
that service for **every** app on the machine — always pass `com.scribird.app`.

If that doesn't help, remove and re-add the app by hand:

1. System Settings › Privacy & Security › Microphone
2. Select Scribird and press **−**
3. Repeat under *Audio Recording*
4. Relaunch Scribird and press Start; both prompts should reappear

### Inspect stored preferences

```bash
defaults read com.scribird.app
```

Scribird's own keys are `transcriptionLanguage`, `savesOriginalAudio`,
`pinnedInputDeviceUID`, `pinnedOutputDeviceUID`, `hotKeyCode`, and `hotKeyModifiers`; the rest
are AppKit window and menu-bar positions. A pinned-device key that's absent means that source
follows the system default:

```bash
defaults read com.scribird.app pinnedOutputDeviceUID   # errors out if not pinned
``` Deleting the domain
resets every setting to its default — English, meeting-audio saving on, `⌥⌘S`:

```bash
defaults delete com.scribird.app
```

This is worth checking when a setting behaves unexpectedly, because these values persist
across launches. **No `.m4a` files in a session directory usually means
`savesOriginalAudio` is `0` from an earlier session**, not that recording failed:

```bash
defaults read com.scribird.app savesOriginalAudio
```

A value the app can't interpret is ignored in favor of the default rather than blocking a
recording, so a corrupt preference shows up as "my setting reverted", never as a failure to
start.

### Verify what was actually captured

The meeting audio file is the ground truth for whether the archive worked. Open it directly:

```bash
open ~/Documents/Scribird/<date_time>/meeting.m4a
```

A file that plays back silence confirms a capture problem; one that sounds correct while
`transcript.jsonl` is empty or wrong points at transcription instead. Because the archive is
a mono mix, use the live per-source meters and warnings to identify which input was missing.

### Confirm a session boundary worked

After pressing **✎** mid-meeting there must be two session directories, each with a playable
`.m4a` and a `transcript.md` whose timecodes start near `00:00:00`. A second meeting whose
transcript starts at `01:02:05` means the time rebase was lost — that's a bug worth
[reporting](https://github.com/haandol/scribird/issues).

## Still stuck?

Open an issue at [github.com/haandol/scribird/issues](https://github.com/haandol/scribird/issues)
with:

- your macOS version and whether the build came from a release or from source
- the output of `codesign -dv /Applications/Scribird.app 2>&1 | grep TeamIdentifier`
- which of the two level meters moved
- any warning text the app showed

**Do not attach meeting audio or transcripts.** Describe the symptom instead — nobody needs
your meeting to diagnose a permission problem.
