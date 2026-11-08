"""Paths, keys, clip list, shared price constants."""
from __future__ import annotations

import json
import os
from pathlib import Path

SESSIONS = Path.home() / "Documents/sessions"
CACHE = Path(os.environ.get("LEGATO_SPIKE_CACHE") or Path.home() / "Library/Caches/legato/spikes/streaming-dictation")
REPO_ROOT = Path(__file__).resolve().parents[4]


def _main_checkout() -> Path:
    """The main checkout (worktrees share its .env)."""
    common = REPO_ROOT / ".git"
    if common.is_file():  # a worktree: "gitdir: <main>/.git/worktrees/<name>"
        common = Path(common.read_text().split(":", 1)[1].strip()).parents[1]
    return common.parent


KEYS_FILE = _main_checkout() / ".env"
LEGATO_PROMPT = REPO_ROOT / "Sources/LegatoAgent/Prompts/dictation-take-cleanup.md"

CLIPS = """6C975BFA-7397-4DE6-93C1-859607774980 44CC3C9C-17AE-459D-896D-8D63FCD6CAFA 638D6398-9191-4A67-8083-4E699662271F
EDEBCBE5-3DAD-4E37-86FC-44E54F79D6F4 0E96460B-A6A3-4825-8D86-414B2C998C58 41E8AED4-8592-497B-ACA9-F83D53FD331A
E2B2D0C1-12E7-45B0-80D4-2061610A9B85 5A584904-A351-4607-BEBE-6B324186B40B 1B75015E-A302-477C-9977-5D4FCDF775B2
57648BF4-092C-40E7-8EA4-1140B098607E 7213C6FA-6665-42C5-BE10-1C872EBCCCC9 F67ADFB1-B20F-419D-BF54-A306AF963ACD
2CF7E797-8CD0-47DD-9721-BF18A3093851""".split()

# Soniox RT configs: (name, max_non_final_tokens_duration_ms, enable_endpoint_detection)
CONFIGS = {
    "nf4-ep1": (4000, True),
    "nf4-ep0": (4000, False),
    "nf6-ep1": (6000, True),
    "nf6-ep0": (6000, False),
}

# USD per 1M tokens (input, output). Soniox: USD per audio hour (assumed, rounded up; the guard is conservative).
LLM_PRICES = {
    "claude-haiku-5-5": (0.10, 0.50),
    "claude-sonnet-5-5": (2.00, 10.00),
    "claude-opus-5-5": (4.00, 20.00),
}
SONIOX_RT_USD_PER_HOUR = 0.20
SONIOX_ASYNC_USD_PER_HOUR = 0.20
USD_PER_EUR = 1.05  # EUR 1 ~ USD 1.05..1.2; use the low rate so EUR is not understated


def load_keys() -> dict[str, str]:
    """SONIOX_API_KEY / ANTHROPIC_API_KEY from env, else the dotenv file. Never print the values."""
    out: dict[str, str] = {}
    file_vals: dict[str, str] = {}
    if KEYS_FILE.exists():
        for line in KEYS_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                file_vals[k.strip().removeprefix("export ").strip()] = v.strip().strip("'\"")
    for k in ("SONIOX_API_KEY", "ANTHROPIC_API_KEY"):
        v = os.environ.get(k) or file_vals.get(k)
        if v:
            out[k] = v
    return out


def write_json(path: Path, obj: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False))


def read_json(path: Path):
    return json.loads(path.read_text())
