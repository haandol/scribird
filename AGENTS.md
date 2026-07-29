# Repository Guidelines

## Project Structure & Module Organization

`Scribird` is a Swift 6.2 macOS 26 menu-bar application. Application code lives under `Sources/Scribird/`:

- `Audio/`: microphone and system-audio capture, conversion, and recording.
- `Transcription/`: SpeechAnalyzer sessions, language selection, model installation, and multilingual arbitration.
- `Transcript/`: speaker and segment models, timeline merging, and JSONL/Markdown persistence.
- `UI/`: the SwiftUI menu-bar window.
- `MeetingRecorder.swift`: application state and pipeline orchestration.

Bundle metadata, entitlements, and the editable app icon are in `Resources/`. Generated artifacts belong in `.build/` and `build/`; do not edit or commit them as source.

## Build, Test, and Development Commands

- `swift build -c debug`: compile quickly with actor data-race checks enabled.
- `./build.sh release`: create and ad-hoc sign `build/Scribird.app`, including its `.icns` icon.
- `open build/Scribird.app`: run the locally built bundle.
- `./install.sh`: release-build and replace `/Applications/Scribird.app`; restart an already running copy.
- `swift test`: run tests after a test target is added.

Run the app as a bundle rather than as a bare executable because macOS associates microphone and screen/audio-capture permissions with the bundle identifier.

## Coding Style & Naming Conventions

Use four spaces in Swift files and follow standard Swift API design: `UpperCamelCase` for types, `lowerCamelCase` for properties and functions, and descriptive enum cases. Keep one primary type per file and place code in the existing domain folder. Prefer structured concurrency and explicit actor isolation; do not weaken Swift 6 concurrency checks. Use short comments only for non-obvious audio, timing, or language-arbitration behavior. No formatter or linter is configured, so keep changes consistent with nearby code.

## Testing Guidelines

There is currently no test target. Add tests under `Tests/ScribirdTests/` and register `.testTarget(name: "ScribirdTests", dependencies: ["Scribird"])` in `Package.swift`. Name XCTest methods `test_<behavior>_<expectedResult>()`. Prioritize deterministic tests for `LanguageArbiter`, `TranscriptTimeline`, and persistence; hardware capture changes also require a manual microphone/system-audio smoke test.

## Commit & Pull Request Guidelines

This checkout contains no Git history, so no established commit convention can be inferred. Use short imperative subjects, for example `Add system audio capture retry`. Pull requests should explain behavior changes, list verification commands, note permission or storage impacts, and include screenshots for SwiftUI changes. Never include recorded meeting audio or generated transcripts.
