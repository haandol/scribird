# Validate and package the candidate

Run the maintained checks for the actual changed areas. For a full Scribird release,
the repository's ordinary suites are:

```bash
bash scripts/check-swift-tests.sh
bash scripts/check-python-tests.sh
./build.sh release
codesign --verify --deep --strict --verbose=2 build/Scribird.app
codesign -dv --verbose=4 build/Scribird.app
```

The Swift check includes the audio regressions and skips tests that change the
user's real default audio device. Preserve existing fixture/model opt-ins and
record actual skips. For changed live-control behavior, enable the documented MCP
socket integration. Do not repeat the audio harness after an already passing full
suite unless a new failure or change requires it.

Use the affected-area manual checks in `AGENTS.md`/`CONTRIBUTING.md` when capture,
session rotation, hardware, shortcuts or UI behavior changes. Unit tests do not
substitute for those checks. If an applicable manual check cannot run, leave it as
a release blocker. Skills/archive-metadata changes do not by themselves require
starting a microphone recording or changing the user's audio devices.

Require a real `Apple Development` or `Developer ID Application` signature and a
nonempty `TeamIdentifier`. The build script's ad-hoc fallback is not a releasable
system-audio build. Scribird is not currently notarized; do not claim notarization
or disable Gatekeeper as an installation workaround.

Package the checked app with macOS metadata preserved. Before using an existing
archive path, establish whether it is the matching verified candidate; never
silently overwrite an unrelated or published asset.

```bash
release_version="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
release_archive="build/Scribird-${release_version}.zip"
test ! -e "$release_archive"
ditto -c -k --sequesterRsrc --keepParent build/Scribird.app "$release_archive"
unzip -t "$release_archive"
shasum -a 256 "$release_archive"
```

Write a checksum companion using the ZIP basename so users can verify it after
download. Extract the ZIP into a `mktemp -d` directory and recheck the bundle's
version, build number and strict signature. Verify the exact candidate's source
tree matches what was built; do not label an artifact from an older checkout as
the new target. Keep the checksum and verification outputs with the local notes.
