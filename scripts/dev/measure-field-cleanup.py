#!/usr/bin/env python3
"""Offline aggregate-only analysis of private recorded Soniox responses and PCM.

Python 3.12+, stdlib only. Never prints speech text or makes provider calls.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
from pathlib import Path


def quantiles(values: list[float]) -> dict[str, float | int]:
    values = sorted(values)
    if not values:
        return {"n": 0}
    return {"n": len(values), **{name: round(values[int((len(values) - 1) * q)], 3)
                                for name, q in (("p50", .5), ("p90", .9), ("max", 1.0))}}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path, help="Cache directory containing rt/nf4-ep1 and pcm")
    args = parser.parse_args()
    files = sorted((args.corpus / "rt/nf4-ep1").glob("*.json"))
    if not files:
        parser.error("No recorded response files found")
    fingerprint = hashlib.sha256()
    pcm_fingerprint = hashlib.sha256()
    clips: list[list[tuple[float, float]]] = []
    sentence_lengths: list[float] = []
    gaps: list[float] = []
    delays: list[float] = []
    remaining: list[float] = []
    endpoints: list[tuple[list[float], int, bool]] = []
    seconds = 0.0
    for path in files:
        raw = path.read_bytes()
        fingerprint.update(path.name.encode())
        fingerprint.update(raw)
        rec = json.loads(raw)
        seconds += rec["audio_s"]
        words: list[dict[str, str | int]] = []
        eps: list[tuple[float, float]] = []
        for response in rec["responses"]:
            for token in response["tokens"]:
                if not token["is_final"]:
                    continue
                if token["text"] in ("<end>", "<fin>"):
                    if token["text"] == "<end>" and words:
                        eps.append((response["t"], int(words[-1]["end"]) / 1000))
                    continue
                if not words or token["text"][:1].isspace():
                    words.append({"text": "", "start": token["start_ms"], "end": token["end_ms"]})
                words[-1]["text"] = str(words[-1]["text"]) + token["text"].strip()
                words[-1]["end"] = token["end_ms"]
        words = [word for word in words if word["text"]]
        intervals = [(int(word["start"]) / 1000, int(word["end"]) / 1000) for word in words]
        clips.append(intervals)
        gaps.extend(max(0.0, nxt[0] - prev[1]) for prev, nxt in zip(intervals, intervals[1:]))
        count = 0
        for word in words:
            count += 1
            if str(word["text"]).rstrip("'\")]").endswith((".", "!", "?")):
                sentence_lengths.append(float(count))
                count = 0
        if count:
            sentence_lengths.append(float(count))
        pcm_path = args.corpus / "pcm" / (path.stem + ".pcm")
        pcm = pcm_path.read_bytes()
        pcm_fingerprint.update(pcm_path.name.encode())
        pcm_fingerprint.update(pcm)
        samples = struct.unpack(f"<{len(pcm) // 2}h", pcm)
        levels = [20 * math.log10(max(math.sqrt(sum(s * s for s in samples[i:i + 320]) / 320) / 32768, 1e-9))
                  for i in range(0, len(samples) - 320, 320)]
        for arrival, end in eps:
            delays.append(arrival - end)
            next_start = next((start for start, _ in intervals if start > end), rec["audio_s"])
            remaining.append(next_start - arrival)
            endpoints.append((levels, int(arrival / .02), any(start <= arrival <= stop for start, stop in intervals)))
    total_words = sum(map(len, clips))
    windows = []
    for size, overlap in ((40, 8), (60, 12), (80, 16)):
        spans: list[float] = []
        input_words = 0
        for words in clips:
            pos = 0
            while pos < len(words):
                end = min(pos + size, len(words))
                spans.append(words[end - 1][1] - words[pos][0])
                input_words += end - pos
                if end == len(words):
                    break
                pos = end - overlap
        windows.append({"words": size, "overlap": overlap, "calls": len(spans), "extra_input_fraction": round(input_words / total_words - 1, 3), "audio_span_seconds": quantiles(spans)})
    gates = []
    for threshold in (-65, -60, -55, -50, -45):
        for hold in (.1, .2, .3, .5):
            accepted = inside_word = 0
            for levels, at, voice in endpoints:
                count = round(hold / .02)
                window = levels[max(0, at - count):at]
                if len(window) == count and max(window) < threshold:
                    accepted += 1
                    inside_word += voice
            gates.append({"dbfs": threshold, "hold_seconds": hold, "accepted": accepted, "inside_word": inside_word})
    print(json.dumps({"response_sha256": fingerprint.hexdigest(), "pcm_sha256": pcm_fingerprint.hexdigest(),
                      "clips": len(clips), "audio_seconds": round(seconds, 2), "raw_words": total_words,
                      "sentence_words": quantiles(sentence_lengths), "word_gap_seconds": quantiles(gaps),
                      "endpoint_delay_seconds": quantiles(delays), "endpoint_remaining_silence_seconds": quantiles(remaining),
                      "endpoints_after_next_word_start": sum(value <= 0 for value in remaining),
                      "window_candidates": windows, "endpoint_and_pcm_candidates": gates}, indent=2))


if __name__ == "__main__":
    main()
