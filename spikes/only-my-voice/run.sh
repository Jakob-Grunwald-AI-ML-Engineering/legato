#!/bin/bash
set -euo pipefail
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--compare-gpu" ) ]]; then
    echo "Usage: bash $0 [--compare-gpu]" >&2
    echo 'Unknown arguments; only --compare-gpu is supported.' >&2
    exit 2
fi
cd "$(dirname "$0")"
if [[ ! -d .cache/models/CamPlusPlus_v2.mlmodelc || ! -f .cache/sentences/manifest.json || ! -f .cache/audio/0_jackson_0.wav ]]; then
    echo 'Missing public assets. First run: uv run python prepare.py; uv run python prepare_sentences.py' >&2
    exit 1
fi
output_dir="$(mktemp -d "$PWD/.cache/run.XXXXXX")"
export ONLY_MY_VOICE_OUTPUT_DIR="$output_dir"
swiftc -O Sources/main.swift -o .cache/voice-spike
.cache/voice-spike . - --cpu-only
uv run --offline python evaluate.py "$output_dir/embeddings-digits-cpu.json" --output-dir "$output_dir"
.cache/voice-spike . .cache/sentences/manifest.json --cpu-only
uv run --offline python evaluate.py "$output_dir/embeddings-sentences-cpu.json" --output-dir "$output_dir"
if [[ "${1:-}" == "--compare-gpu" ]]; then
    .cache/voice-spike . -
    uv run --offline python evaluate.py "$output_dir/embeddings-digits-gpu.json" --output-dir "$output_dir"
fi
printf 'Results: %s\n' "$output_dir"
