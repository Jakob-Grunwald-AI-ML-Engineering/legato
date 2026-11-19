#!/usr/bin/env python3
"""Compare dictation cleanup prompts on synthetic spoken samples (#316).

Python 3.12+, stdlib only. Builds the app's dictation request (SentenceCleanupClient.request: cached system prompt,
the submit_sentence tool, the model's thinking and tool_choice, sorted-key JSON) for each style and sends it to the
Anthropic API with ANTHROPIC_API_KEY. Samples are synthetic; no user data.

  eval.py run [--configs line:haiku,send:haiku,send:sonnet] [--only id,id] --out results.json
  eval.py report results.json [--verdicts verdicts.json] > report.md
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PROMPTS = ROOT / "Sources/LegatoAgent/Prompts"
SAMPLES = Path(__file__).with_name("samples.json")
VOCABULARY = ["Jakob Grunwald", "Legato"]
MODELS = {"haiku": "claude-haiku-5-5", "sonnet": "claude-sonnet-5-5"}
# ModelChoice.thinking
THINKING = {"haiku": {"type": "disabled"}, "sonnet": {"type": "between_tools"}}
# SentenceCleanupClient: the prompt file and the tool's text description per DictationCleanupStyle.
STYLES = {
    "line": ("dictation-cleanup.md", "The complete cleaned text, every meaningful word of the input in order, however long or unusual. Never a placeholder, stub, summary or note."),
    "send": ("dictation-send.md", "The complete written text the speaker meant, with all of its content, however long or unusual. Never a placeholder, stub, summary, answer or note."),
}


def max_tokens(characters: int, style: str) -> int:
    """SentenceCleanupClient.lineMaxTokens."""
    return min(4096, max(384, characters // 2 + (384 if style == "send" else 256)))


def request(sample: dict, style: str, model: str, index: int) -> dict:
    prompt_file, text_description = STYLES[style]
    tool = {"name": "submit_sentence", "description": "Submit this sentence's local copyedit once. Copy sentenceID and sequence exactly.",
            "strict": True, "eager_input_streaming": True,
            "input_schema": {"type": "object", "additionalProperties": False, "required": ["sentenceID", "sequence", "text"],
                             "properties": {"sentenceID": {"type": "string"}, "sequence": {"type": "integer"},
                                            "text": {"type": "string", "description": text_description}}}}
    source = {"sentenceID": f"eval-{sample['id']}", "sequence": index, "text": sample["text"], "vocabulary": VOCABULARY,
              "previousLines": sample.get("previousLines", []), "textBeforeCursor": sample.get("textBeforeCursor", "")}
    tool_choice = {"type": "tool", "name": "submit_sentence"} if model == "haiku" else {"type": "auto"}
    return {"model": MODELS[model], "max_tokens": max_tokens(len(sample["text"]), style), "stream": True, "thinking": THINKING[model],
            "system": [{"type": "text", "text": (PROMPTS / prompt_file).read_text(encoding="utf-8"),
                        "cache_control": {"type": "ephemeral", "ttl": "1h"}}],
            "messages": [{"role": "user", "content": json.dumps(source, sort_keys=True, ensure_ascii=False, separators=(",", ":"))}],
            "tools": [tool], "tool_choice": tool_choice}


def call(body: dict) -> dict:
    """Streams one request; returns the tool's text, stop reason, first-text and total milliseconds, and usage."""
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", method="POST",
                                 data=json.dumps(body, sort_keys=True, ensure_ascii=False).encode(),
                                 headers={"x-api-key": os.environ["ANTHROPIC_API_KEY"], "anthropic-version": "2023-06-01",
                                          "content-type": "application/json"})
    began = time.monotonic()
    fragments, first_text, stop, usage, tool_index, initial = "", None, None, {}, None, None
    with urllib.request.urlopen(req, timeout=60) as response:
        event = None
        for raw in response:
            line = raw.decode().rstrip("\n")
            if line.startswith("event: "):
                event = line[7:]
            elif line.startswith("data: "):
                data = json.loads(line[6:])
                if event == "error":
                    raise RuntimeError(json.dumps(data))
                for key, value in (data.get("usage") or data.get("message", {}).get("usage") or {}).items():
                    if isinstance(value, int):
                        usage[key] = value
                if event == "content_block_start" and data["content_block"]["type"] == "tool_use":
                    tool_index, initial = data["index"], data["content_block"].get("input")
                elif event == "content_block_delta" and data.get("index") == tool_index and data["delta"]["type"] == "input_json_delta":
                    fragments += data["delta"]["partial_json"]
                    if first_text is None and '"text"' in fragments:
                        rest = fragments.split('"text"', 1)[1].lstrip(": \n")
                        if rest.startswith('"') and len(rest) > 1:
                            first_text = time.monotonic() - began
                elif event == "message_delta":
                    stop = data["delta"].get("stop_reason")
    total = time.monotonic() - began
    submitted = json.loads(fragments) if fragments else (initial or {})
    return {"text": submitted.get("text"), "stop": stop, "firstTextMs": None if first_text is None else round(first_text * 1000),
            "totalMs": round(total * 1000), "usage": usage}


def run(args: argparse.Namespace) -> None:
    samples = json.loads(SAMPLES.read_text(encoding="utf-8"))
    if args.only:
        samples = [s for s in samples if s["id"] in args.only.split(",")]
    configs = args.configs.split(",")
    results = json.loads(Path(args.out).read_text()) if args.out and Path(args.out).exists() and args.merge else {"samples": {}, "configs": []}
    results["configs"] = sorted(set(results["configs"]) | set(configs), key=lambda c: ["line:haiku", "send:haiku", "send:sonnet"].index(c) if c in ["line:haiku", "send:haiku", "send:sonnet"] else 9)
    for config in configs:
        style, model = config.split(":")
        # Warm the cache once per config so latencies are the cached path (as in the app, which warms at session start).
        call(request({"id": "warm", "text": "Okay."}, style, model, 0))
    # Interleaved by sample, so a slow minute of the API does not fall on one config only.
    jobs = [(config, i, s) for i, s in enumerate(samples) for config in configs]

    def one(job):
        config, i, sample = job
        style, model = config.split(":")
        try:
            return config, sample, call(request(sample, style, model, i + 1))
        except Exception as error:  # noqa: BLE001 - reported per sample
            return config, sample, {"error": str(error)[:300]}

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        for config, sample, result in pool.map(one, jobs):
            entry = results["samples"].setdefault(sample["id"], {"sample": sample, "outputs": {}})
            entry["sample"] = sample
            entry["outputs"][config] = result
            print(f"{config:12} {sample['id']:22} {result.get('totalMs', '-')} ms", file=sys.stderr)
    Path(args.out).write_text(json.dumps(results, ensure_ascii=False, indent=1), encoding="utf-8")


def cell(text: str | None) -> str:
    if text is None:
        return "*(none)*"
    if text == "":
        return "*(empty)*"
    return text.replace("|", "\\|").replace("\n", "<br>")


def report(args: argparse.Namespace) -> None:
    results = json.loads(Path(args.results).read_text(encoding="utf-8"))
    verdicts = json.loads(Path(args.verdicts).read_text(encoding="utf-8")) if args.verdicts else {}
    configs = results["configs"]
    names = {"line:haiku": "Old (line prompt, Haiku)", "send:haiku": "New (send prompt, Haiku)", "send:sonnet": "New (send prompt, Sonnet 5.5)"}
    print("| # | Sample | Spoken input | " + " | ".join(names.get(c, c) for c in configs) + " | Verdict |")
    print("|---|---|---|" + "---|" * len(configs) + "---|")
    for n, (sid, entry) in enumerate(results["samples"].items(), 1):
        sample = entry["sample"]
        spoken = cell(sample["text"])
        if sample.get("textBeforeCursor"):
            spoken = f"*before cursor:* {cell(sample['textBeforeCursor'])}<br>*said:* {spoken}"
        outs = []
        for c in configs:
            o = entry["outputs"].get(c, {})
            if "error" in o:
                outs.append(f"*error:* {cell(o['error'])}")
            else:
                outs.append(f"{cell(o.get('text'))}<br>`{o.get('firstTextMs')}/{o.get('totalMs')} ms`")
        print(f"| {n} | {sample['kind']} | {spoken} | " + " | ".join(outs) + f" | {cell(verdicts.get(sid, ''))} |")
    print()
    print("| Config | first text p50 | first text max | total p50 | total max | output tokens (sum) |")
    print("|---|---|---|---|---|---|")
    for c in configs:
        outs = [e["outputs"][c] for e in results["samples"].values() if c in e["outputs"] and "error" not in e["outputs"][c]]
        first = sorted(o["firstTextMs"] for o in outs if o.get("firstTextMs") is not None)
        total = sorted(o["totalMs"] for o in outs)
        tokens = sum(o["usage"].get("output_tokens", 0) for o in outs)
        if total:
            print(f"| {names.get(c, c)} | {first[len(first) // 2] if first else '-'} | {first[-1] if first else '-'} | "
                  f"{total[len(total) // 2]} | {total[-1]} | {tokens} |")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("run")
    r.add_argument("--configs", default="line:haiku,send:haiku,send:sonnet")
    r.add_argument("--only")
    r.add_argument("--out", required=True)
    r.add_argument("--merge", action="store_true", help="keep other configs already in --out")
    r.add_argument("--workers", type=int, default=4)
    p = sub.add_parser("report")
    p.add_argument("results")
    p.add_argument("--verdicts")
    args = parser.parse_args()
    run(args) if args.command == "run" else report(args)


if __name__ == "__main__":
    main()
