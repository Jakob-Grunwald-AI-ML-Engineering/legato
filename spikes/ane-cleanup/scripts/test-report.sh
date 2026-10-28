#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .cache
cat > .cache/report-invalid.jsonl <<'JSON'
{"status":"completed","runID":"test","requestedBackend":"anemll","executedBackend":"anemll-coreml","modelRevision":"a1b00f628f348c8ff55c9fe088e5db97535fd567","appStateAtInference":"active","startClassification":"backgroundFixture","anePlacement":"unverified","inputTokens":800,"outputTokens":12,"outputCap":128,"contextLength":4096,"endToEndMs":10}
JSON
if bash scripts/report.sh .cache/report-invalid.jsonl > .cache/report-invalid.log 2>&1; then
  echo 'FAIL: validator accepted a foreground run mislabeled as background.' >&2; exit 1
fi
cat > .cache/report-valid.jsonl <<'JSON'
{"status":"completed","runID":"test","requestedBackend":"anemll","executedBackend":"anemll-coreml","modelRevision":"a1b00f628f348c8ff55c9fe088e5db97535fd567","appStateAtInference":"background","appStateAtSettlement":"background","backgroundCompletionEligible":true,"startClassification":"backgroundFixture","anePlacement":"unverified; requires Instruments","inputTokens":800,"outputTokens":12,"outputCap":128,"contextLength":4096,"endToEndMs":10}
JSON
bash scripts/report.sh .cache/report-valid.jsonl > .cache/report-valid.log
cat > .cache/report-capped.jsonl <<'JSON'
{"status":"capped","runID":"test","requestedBackend":"anemll","executedBackend":"anemll-coreml","modelRevision":"a1b00f628f348c8ff55c9fe088e5db97535fd567","appStateAtInference":"active","startClassification":"foregroundFixture","anePlacement":"unverified","qualityPassed":true,"inputTokens":800,"outputTokens":128,"outputCap":128,"contextLength":4096,"endToEndMs":10}
JSON
if bash scripts/report.sh .cache/report-capped.jsonl > .cache/report-capped.log 2>&1; then
  echo 'FAIL: validator accepted capped cleanup as quality success.' >&2; exit 1
fi
echo 'PASS: report rejects mislabeled background and capped quality success, accepts unverified placement without claiming ANE.'
cat > .cache/report-interrupted.jsonl <<'JSON'
{"status":"completed","runID":"interrupted","requestedBackend":"mlx-cpu","executedBackend":"mlx-cpu:qwen","modelRevision":"pinned","appStateAtInference":"background","appStateAtSettlement":"background","backgroundCompletionEligible":false,"foregroundInterruptedAt":"2026-10-27T20:00:01Z","startClassification":"backgroundFixture","anePlacement":"unverified","endToEndMs":10}
JSON
if bash scripts/report.sh .cache/report-interrupted.jsonl > .cache/report-interrupted.log 2>&1; then
  echo 'FAIL: validator accepted a background-start run interrupted by foreground activity.' >&2; exit 1
fi
