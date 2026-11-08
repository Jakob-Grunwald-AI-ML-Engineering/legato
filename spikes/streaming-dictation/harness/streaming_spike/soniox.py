"""Soniox real-time (websocket, wall-clock paced) and async (files + transcriptions) clients."""
from __future__ import annotations

import asyncio
import json
import time

import httpx
import websockets

from .common import CACHE, CONFIGS, SESSIONS, write_json
from .prepare import pcm_path

RT_URL = "wss://stt-rt.soniox.com/transcribe-websocket"
API = "https://api.soniox.com/v1"
CHUNK_MS = 100
TAIL_SILENCE_MS = 300  # docs: ~200 ms of silence before finalize
SPECIAL = {"<end>", "<fin>"}


def start_message(nf_ms: int, endpoint: bool) -> dict:
    """Mirrors Sources/LegatoSoniox/SonioxConfig.swift (dictation, Note mode, no terms/background), plus the knobs under test."""
    return {
        "model": "stt-rt-v6", "audio_format": "pcm_s16le", "sample_rate": 16000, "num_channels": 1,
        "language_hints": ["de", "en"], "enable_language_identification": True,
        "enable_endpoint_detection": endpoint, "max_non_final_tokens_duration_ms": nf_ms,
        "context": {"general": [{"key": "composer", "value": "Mode: Note\n"}], "terms": []},
    }


async def stream_clip(api_key: str, clip: str, config: str) -> dict:
    """Stream one clip in real time. Returns every response with a monotonic timestamp relative to audio start."""
    nf_ms, endpoint = CONFIGS[config]
    pcm = pcm_path(clip).read_bytes()
    step = 16000 * 2 * CHUNK_MS // 1000
    audio_s = len(pcm) / 32000
    pcm += bytes(16000 * 2 * TAIL_SILENCE_MS // 1000)
    responses: list[dict] = []
    t_fin_sent = None
    async with websockets.connect(RT_URL, additional_headers={"Authorization": f"Bearer {api_key}"},
                                  max_size=None, ping_interval=15) as ws:
        await ws.send(json.dumps(start_message(nf_ms, endpoint)))
        t0 = time.monotonic()

        async def reader() -> None:
            async for raw in ws:
                msg = json.loads(raw)
                msg["t"] = time.monotonic() - t0
                responses.append(msg)
                if msg.get("error_code"):
                    return

        task = asyncio.create_task(reader())
        for i, off in enumerate(range(0, len(pcm), step)):
            delay = t0 + i * CHUNK_MS / 1000 - time.monotonic()
            if delay > 0:
                await asyncio.sleep(delay)
            await ws.send(pcm[off:off + step])
        await asyncio.sleep(max(0, t0 + len(pcm) / 32000 - time.monotonic()))
        t_fin_sent = time.monotonic() - t0
        await ws.send(json.dumps({"type": "finalize"}))
        await ws.send("")  # empty text frame ends the stream
        await asyncio.wait_for(task, timeout=60)
    errors = [r for r in responses if r.get("error_code")]
    if errors:
        raise RuntimeError(f"soniox error {errors[0].get('error_code')}: {errors[0].get('error_message')}")
    last = responses[-1]
    fin = [r["t"] for r in responses if any(t["text"] == "<fin>" for t in r.get("tokens", []))]
    return {"clip": clip, "config": config, "audio_s": audio_s, "t_fin_sent": t_fin_sent,
            "t_fin": fin[0] if fin else None, "t_finished": last["t"] if last.get("finished") else None,
            "responses": [{k: r[k] for k in ("t", "tokens", "final_audio_proc_ms", "total_audio_proc_ms") if k in r}
                          for r in responses]}


def final_text(rec: dict) -> str:
    toks = [t["text"] for r in rec["responses"] for t in r["tokens"] if t["is_final"] and t["text"] not in SPECIAL]
    return "".join(toks).strip()


async def async_transcribe(api_key: str, clip: str) -> dict:
    """Upload the original m4a, transcribe with stt-async-v6 (same hints/context as the app). Wall time is the latency."""
    h = {"Authorization": f"Bearer {api_key}"}
    path = SESSIONS / clip / "audio.m4a"
    t0 = time.monotonic()
    async with httpx.AsyncClient(base_url=API, headers=h, timeout=120) as c:
        r = await c.post("/files", files={"file": (f"{clip}.m4a", path.read_bytes(), "audio/mp4")})
        r.raise_for_status()
        file_id = r.json()["id"]
        t_up = time.monotonic() - t0
        body = {"model": "stt-async-v6", "file_id": file_id, "language_hints": ["de", "en"],
                "enable_language_identification": True,
                "context": {"general": [{"key": "composer", "value": "Mode: Note\n"}], "terms": []}}
        r = await c.post("/transcriptions", json=body)
        r.raise_for_status()
        tid = r.json()["id"]
        while True:
            r = await c.get(f"/transcriptions/{tid}")
            r.raise_for_status()
            st = r.json()
            if st["status"] == "completed":
                break
            if st["status"] == "error":
                raise RuntimeError(f"async error: {st.get('error_type')}")
            await asyncio.sleep(0.25)
        t_done = time.monotonic() - t0
        r = await c.get(f"/transcriptions/{tid}/transcript")
        r.raise_for_status()
        tr = r.json()
        t_all = time.monotonic() - t0
        await c.delete(f"/transcriptions/{tid}")
        await c.delete(f"/files/{file_id}")
    return {"clip": clip, "text": tr["text"].strip(), "t_upload": t_up, "t_done": t_done, "t_total": t_all,
            "audio_s": (st.get("audio_duration_ms") or 0) / 1000}
