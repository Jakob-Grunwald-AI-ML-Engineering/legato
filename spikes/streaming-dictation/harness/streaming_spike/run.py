"""CLI: prepare | estimate | run | report.   uv run python -m streaming_spike.run <cmd> [--clips ID,ID] [--parallel N]"""
from __future__ import annotations

import argparse
import asyncio
import sys

import anthropic

from . import llm, soniox
from .common import (CACHE, CONFIGS, LLM_PRICES, SONIOX_ASYNC_USD_PER_HOUR, SONIOX_RT_USD_PER_HOUR, USD_PER_EUR,
                     load_keys, read_json, write_json)
from .prepare import run as prepare_run, usable_clips

HAIKU, SONNET, OPUS = "claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"
BUDGET_EUR = 5.0


def audio_seconds(clips: list[str]) -> float:
    from .prepare import pcm_path
    return sum(pcm_path(c).stat().st_size / 32000 for c in clips)


def estimate_usd(clips: list[str]) -> dict[str, float]:
    """Worst-case-ish: ~3.2 words/s of speech, 1.5 tokens/word, prompt ~1.5k tokens, 4x output for low-effort thinking."""
    hours = audio_seconds(clips) / 3600
    text_tok = audio_seconds(clips) * 3.2 * 1.5
    n = len(clips)
    def llm_cost(model: str, calls_per_clip: int, effort_x: float = 4.0) -> float:
        pin, pout = LLM_PRICES[model]
        calls = calls_per_clip * n
        return (calls * 1500 * pin + calls * 0 + (text_tok * calls_per_clip) * pin + text_tok * calls_per_clip * effort_x * pout) / 1e6
    return {"soniox_rt": hours * len(CONFIGS) * SONIOX_RT_USD_PER_HOUR, "soniox_async": hours * SONIOX_ASYNC_USD_PER_HOUR,
            "haiku": llm_cost(HAIKU, len(CONFIGS) + 1), "sonnet": llm_cost(SONNET, len(CONFIGS)),
            "opus_ref": llm_cost(OPUS, 1, effort_x=6.0)}


def guard(clips: list[str]) -> float:
    est = estimate_usd(clips)
    total_eur = sum(est.values()) / USD_PER_EUR
    print({k: round(v, 3) for k, v in est.items()}, f"-> total ~EUR {total_eur:.2f} (budget EUR {BUDGET_EUR})")
    if total_eur > BUDGET_EUR:
        sys.exit("estimate above budget: aborting")
    return total_eur


def cached(path):
    return read_json(path) if path.exists() else None


async def process_clip(clip: str, keys: dict, claude: anthropic.AsyncAnthropic, sem: asyncio.Semaphore) -> None:
    async with sem:
        async def rt(cfg: str) -> None:
            p = CACHE / "rt" / cfg / f"{clip}.json"
            if not p.exists():
                write_json(p, await soniox.stream_clip(keys["SONIOX_API_KEY"], clip, cfg))

        async def asyn() -> dict:
            p = CACHE / "async" / f"{clip}.json"
            if not p.exists():
                write_json(p, await soniox.async_transcribe(keys["SONIOX_API_KEY"], clip))
            return read_json(p)

        async def post(name: str, model: str, text: str, effort: str = "low") -> None:
            p = CACHE / "llm" / name / f"{clip}.json"
            if not p.exists():
                write_json(p, await llm.clean(claude, model, text, effort))

        async def after_async() -> None:
            a = await asyn()
            await asyncio.gather(post("async+haiku", HAIKU, a["text"]), post("ref-opus", OPUS, a["text"], "medium"))

        async def after_rt(cfg: str) -> None:
            await rt(cfg)
            text = soniox.final_text(read_json(CACHE / "rt" / cfg / f"{clip}.json"))
            await asyncio.gather(post(f"{cfg}+haiku", HAIKU, text), post(f"{cfg}+sonnet", SONNET, text))

        await asyncio.gather(after_async(), *[after_rt(c) for c in CONFIGS])
        print("done", clip[:8], flush=True)


async def run_all(clips: list[str], parallel: int) -> None:
    keys = load_keys()
    claude = anthropic.AsyncAnthropic(api_key=keys["ANTHROPIC_API_KEY"], max_retries=3)
    sem = asyncio.Semaphore(parallel)
    res = await asyncio.gather(*[process_clip(c, keys, claude, sem) for c in clips], return_exceptions=True)
    bad = [(c, r) for c, r in zip(clips, res) if isinstance(r, BaseException)]
    for c, r in bad:
        print("FAILED", c[:8], type(r).__name__, str(r)[:300])
    if bad:
        sys.exit(1)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["prepare", "estimate", "run", "report"])
    ap.add_argument("--clips", help="comma list of ids or id prefixes (default: all usable)")
    ap.add_argument("--parallel", type=int, default=2, help="clips processed concurrently (x4 websocket connections each)")
    args = ap.parse_args()
    prepare_run()
    clips = usable_clips()
    if args.clips:
        want = args.clips.split(",")
        clips = [c for c in clips if any(c.startswith(w) for w in want)]
    if args.cmd == "prepare":
        print(len(clips), "clips ready;", round(audio_seconds(clips) / 60, 1), "min of audio")
    elif args.cmd == "estimate":
        guard(clips)
    elif args.cmd == "run":
        keys = load_keys()
        missing = [k for k in ("SONIOX_API_KEY", "ANTHROPIC_API_KEY") if k not in keys]
        guard(clips)
        if missing:
            sys.exit(f"blocked on keys: missing {', '.join(missing)} (env or the main checkout .env)")
        asyncio.run(run_all(clips, args.parallel))
    else:
        from .report import build
        build(clips)


if __name__ == "__main__":
    main()
