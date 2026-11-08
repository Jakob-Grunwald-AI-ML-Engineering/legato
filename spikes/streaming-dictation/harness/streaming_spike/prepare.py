"""Convert each session's audio.m4a to 16 kHz mono PCM s16le and screen for silent / synthetic clips."""
from __future__ import annotations

import math
import struct
import subprocess

from .common import CACHE, CLIPS, SESSIONS, read_json, write_json


def pcm_path(clip: str):
    return CACHE / "pcm" / f"{clip}.pcm"


def convert(clip: str) -> None:
    out = pcm_path(clip)
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists() and out.stat().st_size > 0:
        return
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(SESSIONS / clip / "audio.m4a"),
                    "-ac", "1", "-ar", "16000", "-f", "s16le", str(out)], check=True)


def screen(clip: str) -> dict:
    """Frame RMS stats: silent = peak very low; synthetic-TTS hint = digital silence between words (p5 ~ -inf)
    and no noise floor. Heuristic only; the report states what was flagged."""
    data = pcm_path(clip).read_bytes()
    n = len(data) // 2
    samples = struct.unpack(f"<{n}h", data[: n * 2])
    frame = 320  # 20 ms
    db = []
    for i in range(0, n - frame, frame):
        ms = sum(s * s for s in samples[i:i + frame]) / frame
        db.append(10 * math.log10(ms + 1e-9) - 90.3)  # dBFS (32768^2 -> 90.3 dB)
    db.sort()
    pick = lambda q: db[int(q * (len(db) - 1))]
    return {"clip": clip, "seconds": n / 16000, "p5_db": round(pick(.05), 1), "p50_db": round(pick(.5), 1),
            "p95_db": round(pick(.95), 1), "peak": max(abs(s) for s in samples)}


def run() -> list[str]:
    """Returns clips to use. Writes screening stats to the cache."""
    stats = []
    for c in CLIPS:
        convert(c)
        stats.append(screen(c))
    write_json(CACHE / "screen.json", stats)
    return [s["clip"] for s in stats if s["peak"] > 1000]


def usable_clips() -> list[str]:
    skip = set(read_json(CACHE / "skip.json")) if (CACHE / "skip.json").exists() else set()
    return [c for c in CLIPS if c not in skip]
