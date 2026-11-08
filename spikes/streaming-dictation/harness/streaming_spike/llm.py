"""Take-level dictation cleanup with the app's prompt (Sources/LegatoAgent/Prompts/dictation-take-cleanup.md)."""
from __future__ import annotations

import json
import time

import anthropic

from .common import LEGATO_PROMPT, LLM_PRICES

SYSTEM = LEGATO_PROMPT.read_text()


def cost_usd(model: str, in_tok: int, out_tok: int) -> float:
    pin, pout = LLM_PRICES[model]
    return (in_tok * pin + out_tok * pout) / 1e6


async def clean(client: anthropic.AsyncAnthropic, model: str, text: str, effort: str = "low") -> dict:
    """One call, plain-text reply, exactly the app's input shape (no recent takes, empty field, no vocabulary)."""
    payload = json.dumps({"text": text, "recentTakes": [], "textBeforeCursor": "", "vocabulary": []}, ensure_ascii=False)
    max_tokens = 8000 + len(text)  # thinking tokens count against max_tokens
    t0 = time.monotonic()
    async with client.messages.stream(model=model, max_tokens=max_tokens, system=SYSTEM,
                                      messages=[{"role": "user", "content": payload}],
                                      output_config={"effort": effort}) as stream:
        msg = await stream.get_final_message()
    dt = time.monotonic() - t0
    out = "".join(b.text for b in msg.content if b.type == "text").strip()
    if msg.stop_reason not in ("end_turn", "stop_sequence"):
        raise RuntimeError(f"{model} stop_reason={msg.stop_reason}")
    return {"text": out, "seconds": dt, "in_tok": msg.usage.input_tokens, "out_tok": msg.usage.output_tokens,
            "cost_usd": cost_usd(model, msg.usage.input_tokens, msg.usage.output_tokens), "model": model}
