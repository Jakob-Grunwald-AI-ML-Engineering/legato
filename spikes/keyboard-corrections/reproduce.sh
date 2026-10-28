#!/bin/bash
# Creates and retains a new workspace; never edits the supplied repository.
set -euo pipefail
REPO="${1:?Usage: bash reproduce.sh /path/to/legato-repository}"
PAYLOAD="$(cd "$(dirname "$0")" && pwd)"
REV=9e113ed85b1d24449028ac200ef71a464d1ee3e0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/legato-evaluation.XXXXXXXX")"
printf 'Fresh retained workspace: %s\n' "$WORK"
cp -R "$PAYLOAD/." "$WORK/"
mkdir "$WORK/source" "$WORK/run-reports" "$WORK/execution-provenance" "$WORK/tmp"
git -C "$REPO" archive "$REV" | tar -x -C "$WORK/source"
cp "$WORK/source/Package.resolved" "$WORK/execution-provenance/Package.resolved"
# All original source inputs except the expected stub-deleted lockfile must remain byte-identical.
source_inventory() {
    (cd "$WORK/source" && find . -type f ! -path ./Package.resolved -exec shasum -a 256 {} + | LC_ALL=C sort)
}
source_inventory > "$WORK/execution-provenance/source-before.sha256"
(cd "$WORK" && shasum -a 256 Fixtures/patches.json Fixtures/alternatives.json) > "$WORK/execution-provenance/fixtures-before.sha256"
export LEGATO_STUB_DEPS=1
export CLANG_MODULE_CACHE_PATH="$WORK/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$WORK/module-cache"
export TMPDIR="$WORK/tmp"
run_swift() {
    local name="$1" action="$2" package="$3" build="$4"
    shift 4
    local status=0
    swift "$action" --package-path "$package" --scratch-path "$build" --cache-path "$WORK/cache" --config-path "$WORK/config" --security-path "$WORK/security" --disable-sandbox --jobs 4 "$@" > "$WORK/run-reports/$name.log" 2>&1 || status=$?
    printf '%s\n' "$status" > "$WORK/run-reports/$name.exit"
    if [ "$status" -ne 0 ]; then
        printf '%s failed (exit %s); see %s\n' "$name" "$status" "$WORK/run-reports/$name.log" >&2
        exit "$status"
    fi
}
run_swift patch-baseline test "$WORK/source" "$WORK/build-baseline" --filter 'FieldWriter|ProxyEditPlanner|TypewriterReveal'
run_swift alternative-baseline test "$WORK/source" "$WORK/build-baseline" --filter 'InputSuggestionState|InputSuggestionLanguages|WordAlternatives|VersionWordsSource|LLMAlternativeReranker'
run_swift sent-boundary-baseline test "$WORK/source" "$WORK/build-baseline" --filter 'LiveSentBoundary|DictationVersionsLive|AppliedCursorCoding'
run_swift harness-boundaries test "$WORK" "$WORK/build-harness" --filter ScratchPatchBoundaries
run_swift patch run "$WORK" "$WORK/build-harness" PatchEvaluation --fixtures "$WORK/Fixtures/patches.json" --report "$WORK/run-reports/patches.jsonl" --summary "$WORK/run-reports/patch-summary.json"
run_swift alternatives run "$WORK" "$WORK/build-harness" AlternativeEvaluation --fixtures "$WORK/Fixtures/alternatives.json" --report "$WORK/run-reports/alternatives.jsonl" --summary "$WORK/run-reports/alternative-summary.json"
xcrun --sdk iphoneos swiftc -typecheck -target arm64e-apple-ios26.0 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" -module-cache-path "$WORK/sdk-module-cache" "$WORK/Sources/SpeechSDKProbe.swift" > "$WORK/run-reports/speech-sdk-compile.log" 2>&1
[ "$(wc -l < "$WORK/run-reports/patches.jsonl" | tr -d ' ')" -eq 164 ]
[ "$(wc -l < "$WORK/run-reports/alternatives.jsonl" | tr -d ' ')" -eq 288 ]
(cd "$WORK" && shasum -a 256 Fixtures/patches.json Fixtures/alternatives.json) > "$WORK/execution-provenance/fixtures-after.sha256"
cmp "$WORK/execution-provenance/fixtures-before.sha256" "$WORK/execution-provenance/fixtures-after.sha256"
source_inventory > "$WORK/execution-provenance/source-after.sha256"
cmp "$WORK/execution-provenance/source-before.sha256" "$WORK/execution-provenance/source-after.sha256"
find "$WORK/run-reports" -type f -exec shasum -a 256 {} + > "$WORK/execution-provenance/output.sha256"
find "$WORK/build-harness" -type f \( -name PatchEvaluation -o -name AlternativeEvaluation \) -exec shasum -a 256 {} + > "$WORK/execution-provenance/binaries.sha256"
printf 'Targeted baselines and runners passed. Reports retained in %s/run-reports\n' "$WORK"
