#!/bin/bash
# Run measured capture/recording failures without opening devices or downloading models.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
swift test --filter 'SystemAudioFormatTests|OutputSampleRateMonitorTests|CaptureBoundaryTests|AudioStreamConverterTests|AudioRecorderContinuityTests|AudioRecordingTimelineTests|AnalyzerInputPumpTests|OneShotBufferTests|PeakAmplitudeTests'
