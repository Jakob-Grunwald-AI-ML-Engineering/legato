#!/usr/bin/env bash
set -euo pipefail
: "${1:?Usage: check-cpu-baseline.sh measurements.jsonl run-id}"
: "${2:?Supply the exact detached physical CPU run ID}"
jq -e -s --arg run "$2" '
  map(select(.runID == $run and .status != "started")) |
  length == 1 and all(.[];
    .requestedBackend == "mlx-cpu" and .status == "completed" and
    .executedBackend != null and .computePermission == "cpu" and
    .cpuCompilation == "disabled; interpreted MLX ops" and
    .appStateAtInference == "active" and .endToEndMs > 0 and
    (.rawCandidate | type == "string" and length > 0))
' "$1" > /dev/null || { echo 'FAIL: physical CPU fixture did not complete with explicit uncompiled execution provenance.' >&2; exit 1; }
echo 'PASS: physical CPU fixture completed with explicit uncompiled execution provenance; quality is assessed separately.'
