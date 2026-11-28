#!/usr/bin/env bash
# Replay kept voice recordings through the production background-voice filter (scripts/dev/voice-replay.md).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec swift run --quiet -c release --package-path "$root" legato-voice-replay "$@"
