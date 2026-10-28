#!/usr/bin/env bash
set -euo pipefail
: "${1:?Usage: report.sh measurements.jsonl}"
jq -s -e '
  def valid:
    (.runID | type == "string" and length > 0) and
    (.modelRevision | type == "string" and length > 0) and
    (if (.startClassification | startswith("backgroundFixture")) then (.status == "started" or .appStateAtInference == "background" or (.appStateAtInference == "notStarted" and .status != "completed" and .status != "timingOnly")) else true end) and
    (if (.startClassification | startswith("backgroundFixture")) and (.status as $status | ["completed", "timingOnly", "timingOnlyCapped", "capped", "guardRejected"] | index($status)) then (.backgroundCompletionEligible == true and .appStateAtSettlement == "background" and .foregroundInterruptedAt == null) else true end) and
    (if .status == "capped" then .qualityPassed != true else true end) and
    (if .anePlacement == "verified" then (.instrumentsTrace | type == "string" and length > 0) else true end) and
    (if .status == "completed" and .requestedBackend == "anemll" then
      (.inputTokens > 0 and .outputTokens > 0 and .outputTokens <= .outputCap and
       .inputTokens + .outputCap + 2 <= .contextLength and .executedBackend == "anemll-coreml")
     else true end) and
    (if .endToEndMs != null then .endToEndMs >= 0 else true end);
  all(.[]; valid)
' "$1" > /dev/null || { echo 'Invalid measurement: provenance, background state, ANE evidence, capped quality or token arithmetic.' >&2; exit 1; }
printf 'backend\tmodel_revision\tstatus\tcount\tmean_total_ms\n'
jq -r -s '
  map(select(.status != "started")) |
  group_by([.requestedBackend,.modelRevision,.status])[] |
  [.[0].requestedBackend,.[0].modelRevision,.[0].status,length,
   ([.[].endToEndMs | select(. != null)] | if length == 0 then "N/A" else add / length end)] | @tsv
' "$1"
