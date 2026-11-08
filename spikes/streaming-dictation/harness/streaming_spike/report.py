"""Aggregate cached results into tables (stdout + CACHE/tables.md + CACHE/aggregate.json). Numbers only."""
from __future__ import annotations

import statistics as st

from .common import CACHE, CONFIGS, SONIOX_ASYNC_USD_PER_HOUR, SONIOX_RT_USD_PER_HOUR, read_json, write_json
from .metrics import analyze_rt, break_overlap, flip_budget, wer
from .soniox import final_text


def pct(xs: list[float], q: float) -> float | None:
    if not xs:
        return None
    xs = sorted(xs)
    k = (len(xs) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def f(x, nd=2, unit=""):
    return "n/a" if x is None else f"{x:.{nd}f}{unit}"


def build(clips: list[str]) -> None:
    clips = [c for c in clips if (CACHE / "llm/ref-opus" / f"{c}.json").exists()
             and all((CACHE / "rt" / g / f"{c}.json").exists() for g in CONFIGS)]
    refs = {c: read_json(CACHE / "llm/ref-opus" / f"{c}.json") for c in clips}
    asyn = {c: read_json(CACHE / "async" / f"{c}.json") for c in clips}
    rt = {g: {c: read_json(CACHE / "rt" / g / f"{c}.json") for c in clips} for g in CONFIGS}
    an = {g: {c: analyze_rt(rt[g][c]) for c in clips} for g in CONFIGS}
    llmr = lambda name, c: read_json(CACHE / "llm" / name / f"{c}.json")
    minutes = sum(an["nf4-ep1"][c]["audio_s"] for c in clips) / 60
    hours = minutes / 60
    words_total = sum(len(refs[c]["text"].split()) for c in clips)
    out: list[str] = [f"Clips: {len(clips)}, audio {minutes:.1f} min, reference words {words_total}\n"]
    agg: dict = {"clips": len(clips), "minutes": minutes}

    # --- stream behaviour per config
    out.append("### Real-time stream behaviour (pooled over clips)\n")
    out.append("| config | flips/min (all) | flips/min behind head | lexical behind head/min | reach p50/p90 (words) | reach p50/p90 (s) | final words changed after first display | first-display lag p50/p90 (s) | stable-form lag p50/p90 (s) | per-word final lag p50/p90 (s) | end-of-audio to final p50/p90 (s) |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for g in CONFIGS:
        A = [an[g][c] for c in clips]
        fl = [x for a in A for x in a["flips"]]
        deep = [x for x in fl if not x["head"]]
        lex = [x for x in deep if x["lexical"]]
        nw = sum(a["n_words"] for a in A)
        ch = sum(a["words_changed"] for a in A)
        lag = lambda k: [v for a in A for v in a[k]]
        endl = [a["end_latency"] for a in A if a["end_latency"] is not None]
        row = dict(flips_pm=sum(x["size"] for x in fl) / minutes, deep_pm=sum(x["size"] for x in deep) / minutes,
                   lex_pm=sum(x["size"] for x in lex) / minutes, changed=ch / nw if nw else 0,
                   reach_w=[pct([x["reach_words"] for x in deep], q) for q in (.5, .9)],
                   reach_s=[pct([x["reach_s"] for x in deep], q) for q in (.5, .9)],
                   lag_disp=[pct(lag("lag_display"), q) for q in (.5, .9)], lag_stable=[pct(lag("lag_stable"), q) for q in (.5, .9)],
                   lag_final=[pct(lag("lag_final"), q) for q in (.5, .9)], end=[pct(endl, q) for q in (.5, .9)])
        agg.setdefault("stream", {})[g] = row
        out.append(f"| {g} | {row['flips_pm']:.1f} | {row['deep_pm']:.1f} | {row['lex_pm']:.1f} | {f(row['reach_w'][0],0)}/{f(row['reach_w'][1],0)} | "
                   f"{f(row['reach_s'][0],1)}/{f(row['reach_s'][1],1)} | {row['changed']*100:.1f}% | {f(row['lag_disp'][0])}/{f(row['lag_disp'][1])} | "
                   f"{f(row['lag_stable'][0])}/{f(row['lag_stable'][1])} | {f(row['lag_final'][0])}/{f(row['lag_final'][1])} | {f(row['end'][0])}/{f(row['end'][1])} |")

    # --- sentences
    out.append("\n### Sentences and endpoints\n")
    out.append("| config | sentences/min | mean words/sentence | `<end>` tokens/min |")
    out.append("|---|---|---|---|")
    for g in CONFIGS:
        A = [an[g][c] for c in clips]
        sw = [w for a in A for w in a["sentence_words"]]
        row = dict(spm=sum(a["n_sentences"] for a in A) / minutes, wps=st.mean(sw) if sw else 0, endpm=sum(a["n_end"] for a in A) / minutes)
        agg.setdefault("sentences", {})[g] = row
        out.append(f"| {g} | {row['spm']:.1f} | {row['wps']:.1f} | {row['endpm']:.1f} |")
    out.append("\nSentence-break agreement, endpointing on vs off (breaks within 600 ms):\n")
    out.append("| pair | matched | only endpointing on | only endpointing off |")
    out.append("|---|---|---|---|")
    for nf in ("nf4", "nf6"):
        m = oa = ob = 0
        for c in clips:
            x, y, z = break_overlap(an[f"{nf}-ep1"][c]["sentence_ends_ms"], an[f"{nf}-ep0"][c]["sentence_ends_ms"])
            m, oa, ob = m + x, oa + y, ob + z
        agg.setdefault("break_overlap", {})[nf] = [m, oa, ob]
        out.append(f"| {nf}: ep1 vs ep0 | {m} | {oa} | {ob} |")

    # --- arms
    out.append("\n### Arms (reference = async + Opus cleanup; biased toward async arms)\n")
    out.append("| arm | WER vs ref | latency to final p50/p90 (s) | flip budget: lexical words changed (% of RT-final words) | incl. case/punctuation | post-pass cost (USD / audio hour) |")
    out.append("|---|---|---|---|---|---|")
    ref_t = {c: refs[c]["text"] for c in clips}

    def arm(name, texts, lat, base_texts, cost):
        e = [wer(ref_t[c], texts[c]) for c in clips]
        w = sum(a for a, _ in e) / sum(b for _, b in e)
        fb = [flip_budget(base_texts[c], texts[c]) for c in clips] if base_texts else None
        fbl = sum(x["lexical"] for x in fb) / sum(x["words"] for x in fb) if fb else 0
        fbr = sum(x["raw"] for x in fb) / sum(x["words"] for x in fb) if fb else 0
        flipm = sum(x["lexical"] for x in fb) / minutes if fb else 0
        agg.setdefault("arms", {})[name] = dict(wer=w, lat=[pct(lat, .5), pct(lat, .9)], budget_lex=fbl, budget_raw=fbr,
                                                budget_lex_per_min=flipm, cost_per_hour=cost / hours)
        out.append(f"| {name} | {w*100:.1f}% | {f(pct(lat,.5),1)}/{f(pct(lat,.9),1)} | {fbl*100:.1f}% ({flipm:.1f}/min) | {fbr*100:.1f}% | {cost/hours:.2f} |")

    for g in CONFIGS:
        base = {c: final_text(rt[g][c]) for c in clips}
        endl = {c: an[g][c]["end_latency"] or 0 for c in clips}
        arm(f"{g} none", base, list(endl.values()), None, 0)
        for key, model in (("haiku", "haiku"), ("sonnet", "sonnet")):
            L = {c: llmr(f"{g}+{key}", c) for c in clips}
            arm(f"{g} + {model}", {c: L[c]["text"] for c in clips}, [endl[c] + L[c]["seconds"] for c in clips], base,
                sum(L[c]["cost_usd"] for c in clips))
        arm(f"{g} + async", {c: asyn[c]["text"] for c in clips}, [asyn[c]["t_total"] for c in clips], base,
            sum(an[g][c]["audio_s"] for c in clips) / 3600 * SONIOX_ASYNC_USD_PER_HOUR)
        H = {c: llmr("async+haiku", c) for c in clips}
        arm(f"{g} + async + haiku", {c: H[c]["text"] for c in clips}, [asyn[c]["t_total"] + H[c]["seconds"] for c in clips], base,
            sum(an[g][c]["audio_s"] for c in clips) / 3600 * SONIOX_ASYNC_USD_PER_HOUR + sum(H[c]["cost_usd"] for c in clips))
    out.append(f"\nRT streaming cost (all arms add it once): about {SONIOX_RT_USD_PER_HOUR:.2f} USD / audio hour (assumed rate). "
               f"Reference Opus pass: {sum(refs[c]['cost_usd'] for c in clips):.3f} USD total.")
    text = "\n".join(out)
    (CACHE / "tables.md").write_text(text)
    write_json(CACHE / "aggregate.json", agg)
    print(text)
