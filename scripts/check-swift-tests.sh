#!/bin/bash
# Keep the measured audio regressions and selector assertions in the ordinary suite.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

# Only these tests change the user's real default audio device. Speech/model and
# screenshot integration tests retain their existing fixture opt-ins.
swift test --skip AudioDeviceSwitchNotificationTests "$@"
