#!/bin/bash
# Explicit hardware smoke probe; the unit-test harness remains device-free.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
mkdir -p build/diagnostics
probe_dir="$(mktemp -d build/diagnostics/airpods-XXXXXX)"
swiftc -swift-version 6 -parse-as-library \
    Sources/Scribird/Audio/{SystemAudioCapture,OutputSampleRateMonitor,MicrophoneCapture,AnalyzerInputPump,CaptureBoundaryCoordinator,AudioStreamConverter,AudioBufferCopy,OneShotBuffer,AudioLevelTracker,AVAudioPCMBuffer+Peak,AudioDevice,AudioDeviceMonitor}.swift \
    scripts/AudioCaptureProbe.swift -o "$probe_dir/probe"
"$probe_dir/probe"
