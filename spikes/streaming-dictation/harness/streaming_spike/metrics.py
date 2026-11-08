"""Word-level metrics: stream flips and display/final lag, WER, flip budget, sentence breaks."""
from __future__ import annotations

import re
from difflib import SequenceMatcher

SPECIAL = {"<end>", "<fin>"}


def norm_words(text: str) -> list[str]:
    text = text.lower().replace("’", "'")
    return re.findall(r"[^\W_]+(?:'[^\W_]+)*", text)


def edits(a: list[str], b: list[str]) -> int:
    """Word edit count between two token lists (replace counts max of both sides)."""
    n = 0
    for op, i1, i2, j1, j2 in SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if op != "equal":
            n += max(i2 - i1, j2 - j1)
    return n


def wer(ref: str, hyp: str) -> tuple[int, int]:
    r, h = norm_words(ref), norm_words(hyp)
    prev = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        cur = [i]
        for j, hw in enumerate(h, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (rw != hw)))
        prev = cur
    return prev[-1], len(r)


def flip_budget(a: str, b: str) -> dict:
    """Words changed on the field when text `a` is replaced by `b`: lexical (normalized) and with case/punctuation."""
    raw_a, raw_b = a.split(), b.split()
    return {"lexical": edits(norm_words(a), norm_words(b)), "raw": edits(raw_a, raw_b), "words": max(1, len(raw_a))}


def group_words(tokens: list[dict]) -> list[dict]:
    words: list[dict] = []
    for t in tokens:
        if t["text"] in SPECIAL:
            continue
        if not words or t["text"][:1].isspace():
            words.append({"text": "", "start": t.get("start_ms"), "end": t.get("end_ms"), "final": True})
        w = words[-1]
        w["text"] += t["text"].strip()
        if w["start"] is None:
            w["start"] = t.get("start_ms")
        w["end"] = t.get("end_ms", w["end"])
        w["final"] = w["final"] and t["is_final"]
    return [w for w in words if w["text"]]


def analyze_rt(rec: dict) -> dict:
    """Replay the response sequence the way a text field would show it: finals + current non-finals."""
    finals: list[dict] = []
    live: list[dict] = []  # words currently displayed with bookkeeping
    flips: list[dict] = []
    n_end = 0
    for r in rec["responses"]:
        nonfinal = []
        for t in r["tokens"]:
            if t["text"] == "<end>":
                n_end += 1
            if t["is_final"]:
                finals.append(t)
            else:
                nonfinal.append(t)
        new = group_words(finals + nonfinal)
        t_now = r["t"]
        head_ms = r.get("total_audio_proc_ms", 0)
        a = [w["text"] for w in live]
        b = [w["text"] for w in new]
        out: list[dict] = []
        for op, i1, i2, j1, j2 in SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
            if op == "equal":
                for k in range(j2 - j1):
                    w = live[i1 + k]
                    nw = new[j1 + k]
                    out.append({**w, "final": nw["final"], "start": nw["start"], "end": nw["end"],
                                "t_final": w["t_final"] if w["t_final"] is not None else (t_now if nw["final"] else None)})
                continue
            old = live[i1:i2]
            growth = i1 == i2 and i1 == len(live)  # words appended after everything shown: not a flip
            # the last shown word only grows (partial word completed, punctuation appended): an extension, not a flip
            extension = (i2 - i1 == 1 and i1 == len(live) - 1 and j2 > j1 and b[j1].lower().startswith(a[i1].lower()))
            growth = growth or extension
            if not growth:
                lexical = norm_words(" ".join(a[i1:i2])) != norm_words(" ".join(b[j1:j2]))
                ref = live[min(i1, len(live) - 1)]
                flips.append({"t": t_now, "size": (i2 - i1) or (j2 - j1), "lexical": lexical,
                              "head": i1 >= len(live) - 1, "reach_words": len(live) - i1,
                              "reach_s": max(0.0, (head_ms - (ref["start"] or head_ms)) / 1000)})
            first = min((w["first"] for w in old), default=t_now)
            for nw in new[j1:j2]:
                out.append({**nw, "first": first, "form_first": t_now, "changed": bool(old) and not growth,
                            "t_final": t_now if nw["final"] else None})
        live = out
    final_words = [w for w in live if w["final"]]
    lag_disp = [w["first"] - (w["end"] or 0) / 1000 for w in final_words if w["end"] is not None]
    lag_final = [w["t_final"] - (w["end"] or 0) / 1000 for w in final_words if w["end"] is not None and w["t_final"] is not None]
    lag_stable = [w["form_first"] - (w["end"] or 0) / 1000 for w in final_words if w["end"] is not None]
    text = "".join(t["text"] for t in finals if t["text"] not in SPECIAL).strip()
    sentences = split_sentences(final_words)
    return {"audio_s": rec["audio_s"], "n_words": len(final_words), "text": text,
            "lag_display": lag_disp, "lag_final": lag_final, "lag_stable": lag_stable,
            "words_changed": sum(1 for w in final_words if w["changed"]),
            "flips": flips, "n_end": n_end,
            "end_latency": (rec["t_fin"] - rec["audio_s"]) if rec.get("t_fin") else None,
            "finished_latency": (rec["t_finished"] - rec["audio_s"]) if rec.get("t_finished") else None,
            "sentence_ends_ms": [s["end_ms"] for s in sentences], "n_sentences": len(sentences),
            "sentence_words": [s["words"] for s in sentences]}


def split_sentences(words: list[dict]) -> list[dict]:
    out, n = [], 0
    for w in words:
        n += 1
        if re.search(r"[.!?]['\")\]]*$", w["text"]):
            out.append({"end_ms": w["end"] or 0, "words": n})
            n = 0
    if n:
        out.append({"end_ms": words[-1]["end"] or 0, "words": n, "open": True})
    return out


def break_overlap(a_ms: list[int], b_ms: list[int], tol_ms: int = 600) -> tuple[int, int, int]:
    """(matched, only_a, only_b) sentence breaks between two configs for the same clip."""
    unused = list(b_ms)
    matched = 0
    for x in a_ms:
        hit = next((y for y in unused if abs(x - y) <= tol_ms), None)
        if hit is not None:
            matched += 1
            unused.remove(hit)
    return matched, len(a_ms) - matched, len(b_ms) - matched
