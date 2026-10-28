#!/usr/bin/env bash
# Only --download fetches weights. Existing files are checked and reused, never removed.
set -euo pipefail
cd "$(dirname "$0")/.."
model=${1:-gemma3-1b}
mode=${2:---plan}
case "$mode" in --plan|--download) ;; *) echo 'Usage: stage-model.sh gemma3-1b|qwen3-1.7b [--plan|--download]' >&2; exit 64;; esac
[ "$model" != qwen3-0.6b ] || { echo 'Use the conversion experiment for the 0.6B artifact.' >&2; exit 1; }
repo=$(jq -er --arg id "$model" '.models[]|select(.id==$id)|.repository' models.json)
revision=$(jq -er --arg id "$model" '.models[]|select(.id==$id)|.revision' models.json)
printf 'Pinned checkpoint: %s @ %s\nTarget: .cache/models/%s\nNo files are deleted.\n' "$repo" "$revision" "$model"
[ "$mode" = --download ] || exit 0
mkdir -p .cache/models
manifest=".cache/models/$model-download-manifest.json"
curl --fail --location --silent --show-error "https://huggingface.co/api/models/$repo/revision/$revision?blobs=true" -o "$manifest"
[ "$(jq -r '.sha' "$manifest")" = "$revision" ] || { echo 'Revision mismatch.' >&2; exit 1; }
# Compiled checkpoint parts plus complete tokenizer metadata. README/licence files are metadata evidence.
selection=".cache/models/$model-files.tsv"
jq -r '.siblings[] | select((.rfilename | test("^[^/]+\\.mlmodelc/")) or (.rfilename | test("^(meta\\.yaml|config\\.json|tokenizer.*|special_tokens_map\\.json|added_tokens\\.json|README\\.md|LICENSE.*)$"))) | [.rfilename, .size, (.lfs.sha256 // ""), .blobId] | @tsv' "$manifest" > "$selection"
required=$(awk -F '\t' '{sum+=$2} END {printf "%.0f",sum}' "$selection")
free_kib=$(df -Pk . | awk 'NR==2 {print $4}')
[ "$free_kib" -gt $((required / 1024 + 3145728)) ] || { echo 'Insufficient disk for checkpoint plus 3 GiB reserve.' >&2; exit 1; }
while IFS=$'\t' read -r file size lfs_sha blob; do
  destination=".cache/models/$model/$file"
  mkdir -p "$(dirname "$destination")"
  if [ ! -f "$destination" ]; then
    curl --fail --location --silent --show-error "https://huggingface.co/$repo/resolve/$revision/$file" -o "$destination"
  fi
  [ "$(stat -f %z "$destination")" = "$size" ] || { echo "Size mismatch: $file" >&2; exit 1; }
  # Empty TSV columns collapse with bash IFS; prefer the original metadata lookup for LFS hashes.
  expected=$(jq -r --arg file "$file" '.siblings[]|select(.rfilename==$file)|.lfs.sha256 // empty' "$manifest")
  if [ -n "$expected" ]; then
    [ "$(shasum -a 256 "$destination" | awk '{print $1}')" = "$expected" ] || { echo "SHA256 mismatch: $file" >&2; exit 1; }
  fi
done < "$selection"
printf 'Verified sizes and LFS SHA256 for %s at %s. Preserve manifest with run provenance.\n' "$model" "$revision"
