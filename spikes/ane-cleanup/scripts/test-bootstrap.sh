#!/usr/bin/env bash
# Regression: repeated preparation cannot silently reverse an applied BSD patch.
set -euo pipefail
cd "$(dirname "$0")/.."
checkout=.cache/Anemll-Anemll-f4ad26d/anemll-swift-cli
[ -d "$checkout" ] || { echo 'Run setup.sh --prepare first.' >&2; exit 1; }
bash scripts/setup.sh --prepare > .cache/bootstrap-first.log 2>&1
shasum -a 256 "$checkout/Package.swift" "$checkout/Sources/AnemllCore/InferenceManager.swift" "$checkout/Sources/AnemllCore/Tokenizer.swift" > .cache/bootstrap-first.sha256
bash scripts/setup.sh --prepare > .cache/bootstrap-second.log 2>&1
shasum -a 256 "$checkout/Package.swift" "$checkout/Sources/AnemllCore/InferenceManager.swift" "$checkout/Sources/AnemllCore/Tokenizer.swift" > .cache/bootstrap-second.sha256
cmp .cache/bootstrap-first.sha256 .cache/bootstrap-second.sha256
rg -q 'exact: "1.3.5"' "$checkout/Package.swift"
rg -q 'public var cancellationCheck' "$checkout/Sources/AnemllCore/InferenceManager.swift"
rg -q 'addSpecialTokens: false' "$checkout/Sources/AnemllCore/Tokenizer.swift"
echo 'PASS: two setup runs preserve identical patched source hashes, transformer pin, cancellation hook and raw tokenization.'
