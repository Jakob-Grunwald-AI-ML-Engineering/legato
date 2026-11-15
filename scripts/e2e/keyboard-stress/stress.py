#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "==3.14.5"
# dependencies = []
# ///
"""Keyboard dictation stress driver (called by scripts/e2e/keyboard-stress.sh).

Generates seeded Soniox-style dictation takes, replays them through the real app + keyboard in the
simulator harness (-LegatoKeyboardHarness YES), optionally injects user keys / caret moves, then checks
invariants on the final field text and the keyboard's edit journal. Local only; never run in CI.
"""

from __future__ import annotations

import argparse
import collections
import difflib
import json
import os
import random
import re
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
CTL = REPO / "scripts/device/ctl.sh"
BUNDLE = "de.gruenwald.legato"
GROUP = "group.de.gruenwald.legato"
FIELD_ID = "harness-document"
# Letters the generated vocabulary never contains: a user key is one of these, so it can be counted.
MARKERS = "zqxj"

# ---------------------------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------------------------

VOCAB = """maple harbor lantern cedar ribbon meadow copper window garden pillow kettle orchard basket candle ferry
anchor blanket compass dolphin engine forest glacier hammer island jungle(skip) kitchen ladder marble needle olive
paddle rocket saddle timber umbrella valley whistle yarn(skip) button cabin dinner embers feather gravel hollow ivory
lemon mitten nutmeg oyster pebble raisin shovel tunnel velvet wagon willow sparrow thistle barrel biscuit blossom
bramble canoe clover cobble crumble dapper drizzle fiddle flannel gadget goblet hearth hickory kernel larder lotus
mallet muffin napkin pantry parlor pewter plaster pocket porridge puddle rafter ripple rudder sandal shingle sunset
skillet sleeper sorrel spindle stable tassel teapot thimble trellis turnip warbler wicker wren""".replace("(skip)", "").split()
VOCAB = [w for w in VOCAB if not set(w) & set(MARKERS)]
FUNCTION = ["the", "a", "and", "then", "we", "will", "bring", "over", "near", "under", "to", "of", "with", "at", "on",
            "if", "when", "before", "after", "all", "some", "two", "three", "more", "from", "into", "by", "for", "our", "this"]
FILLERS = ["uh", "um"]
ALTS = [("weather", "whether"), ("their", "there"), ("write", "right"), ("to", "two"), ("by", "buy"), ("for", "four"),
        ("no", "know"), ("sea", "see"), ("one", "won"), ("hear", "here")]
# Alternating pairs only use letters outside MARKERS (checked below).
ALTS = [p for p in ALTS if not any(set(w) & set(MARKERS) for w in p)]
WORD_MS = 380
FRAME_S = 0.3

KINDS = {
    # name: (weight, min words, max words)
    "short": (2, 5, 12),
    "normal": (4, 18, 40),
    "resplit": (3, 28, 46),
    "joints": (3, 16, 34),
    "long": (2, 72, 96),
}


def capitalized(text: str) -> str:
    """What the offline stream cleaner does (String.capitalized): every letter run starts uppercase, rest lowercase."""
    return re.sub(r"[A-Za-z]+", lambda m: m.group(0).capitalize(), text)


def tok(text: str, t0: int, final: bool) -> dict:
    return {"text": text, "start_ms": t0, "end_ms": t0 + WORD_MS - 40, "confidence": 0.93, "language": "en", "is_final": final}


@dataclass
class Take:
    index: int
    seed: str
    kind: str
    frames: list
    final_tokens: list  # final token texts, in order (no <end>)
    transcript: str
    last_t: float
    words: int
    user: dict = field(default_factory=dict)  # mid: [fractions], post: n, cursor: [fractions]

    @property
    def expected_clean(self) -> str:
        return capitalized(norm_ws(self.transcript))


def norm_ws(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def make_words(rng: random.Random, n: int) -> list[str]:
    words: list[str] = []
    while len(words) < n:
        r = rng.random()
        if r < 0.06:
            words.append(rng.choice(FILLERS))
        elif r < 0.10:
            words.append(rng.choice(ALTS)[rng.randrange(2)])
        elif r < 0.50:
            words.append(rng.choice(FUNCTION))
        else:
            words.append(rng.choice(VOCAB))
    return words


def punctuate(rng: random.Random, words: list[str], end: str) -> list[str]:
    """Final forms: sprinkle commas, fillers get a comma sometimes, the last word takes `end`."""
    out = []
    for i, w in enumerate(words):
        if i < len(words) - 1 and rng.random() < (0.45 if w in FILLERS else 0.07):
            w += ","
        out.append(w)
    out[-1] = out[-1].rstrip(",") + end
    return out


def provisional(rng: random.Random, final_word: str) -> str:
    """A first guess at a word: sometimes another word, sometimes different punctuation."""
    r = rng.random()
    base = final_word.rstrip(",.?")
    tail = final_word[len(base):]
    if r < 0.10:
        for a, b in ALTS:
            if base == a:
                return b + tail
            if base == b:
                return a + tail
        return rng.choice(VOCAB) + tail
    if r < 0.16:
        return base + rng.choice([",", ".", ""])
    return final_word


def gen_take(seed: int, index: int, kind: str | None = None) -> Take:
    rng = random.Random(seed * 100003 + index)
    if kind is None:
        names = list(KINDS)
        kind = rng.choices(names, weights=[KINDS[n][0] for n in names])[0]
    _, lo, hi = KINDS[kind]
    nwords = rng.randint(lo, hi)
    words = make_words(rng, nwords)
    if kind == "long":
        # > 400 characters whatever the draw.
        while len(" ".join(words)) < 430:
            words += make_words(rng, 5)

    # Split into utterances; each utterance is spoken (provisional tail grows, words firm up) then ended.
    utterances: list[list[str]] = []
    if kind == "short":
        utterances = [words]
    elif kind == "resplit":
        utterances = [words]  # one long utterance, finalized as several segments
    else:
        i = 0
        while i < len(words):
            n = rng.randint(4, 14) if kind == "joints" else rng.randint(6, 22)
            utterances.append(words[i:i + n])
            i += n
    utterances = [u for u in utterances if u]

    frames: list[dict] = []
    final_texts: list[str] = []
    t = 1.2
    clock_ms = 400
    first_token = True
    carry_punct: str | None = None  # a late punctuation token that opens the next utterance

    for ui, uwords in enumerate(utterances):
        last = ui == len(utterances) - 1
        end = "." if last else rng.choice([".", ".", ",", "", "?"])
        finals = punctuate(rng, uwords, end if kind != "joints" or last else rng.choice([",", ".", ""]))
        # Joint flips: a trailing "," / "." sometimes arrives only as the first token of the next utterance.
        late: str | None = None
        if not last and finals[-1][-1:] in ",." and rng.random() < (0.55 if kind == "joints" else 0.2):
            late = finals[-1][-1]
            finals[-1] = finals[-1][:-1]
        # Chunk plan: where the utterance is finalized (and `<end>` placed) in the "resplit"/"long" kinds.
        chunks: list[int] = []
        if kind in ("resplit", "long"):
            pos = 0
            while pos < len(finals):
                pos = min(len(finals), pos + rng.randint(5, 13))
                chunks.append(pos)
        else:
            chunks = [len(finals)]

        # Tokens: (text, start_ms) with a leading space except at the take start / after a carried punctuation.
        toks: list[tuple[str, int]] = []
        for wi, w in enumerate(finals):
            lead = "" if first_token and wi == 0 else " "
            toks.append((lead + w, clock_ms))
            clock_ms += WORD_MS
        # Opening carried punctuation token (comes first in this utterance).
        opener: tuple[str, int] | None = None
        if carry_punct is not None:
            opener = (carry_punct, toks[0][1] - 20)
            carry_punct = None
        first_token = False

        n = len(toks)
        revealed = 0          # tokens spoken so far
        finalized = 0         # tokens already sent as final
        chunk_i = 0
        pending_opener = opener
        # Provisional variants per token index, valid until finalization.
        prov = [provisional(rng, finals[i]) for i in range(n)]
        lead_of = [toks[i][0][: len(toks[i][0]) - len(toks[i][0].lstrip())] for i in range(n)]
        while finalized < n:
            if revealed < n:
                revealed += 1
                t += FRAME_S + rng.random() * 0.12
            else:
                t += FRAME_S
            # Settle: tokens near the head stay provisional; long utterances hold everything until chunks.
            new_final: list[dict] = []
            end_marks = 0
            lag = 3 if kind not in ("resplit", "long") else 10 ** 6
            target = finalized
            if revealed == n and kind not in ("resplit", "long"):
                # normal: firm up progressively behind the head, all of it at the utterance end
                target = n if rng.random() < 0.5 or revealed - finalized <= 1 else finalized + rng.randint(1, revealed - finalized)
            elif revealed == n:
                # resplit/long: the whole provisional sentence firms up as several segments across frames
                target = chunks[chunk_i]
            elif revealed - finalized > lag and kind not in ("resplit", "long"):
                target = revealed - lag
            if target > finalized:
                if pending_opener is not None:
                    new_final.append(tok(pending_opener[0], pending_opener[1], True))
                    final_texts.append(pending_opener[0])
                    pending_opener = None
                for i in range(finalized, target):
                    new_final.append(tok(toks[i][0], toks[i][1], True))
                    final_texts.append(toks[i][0])
                finalized = target
                if kind in ("resplit", "long") and revealed == n and finalized == chunks[chunk_i]:
                    chunk_i += 1
                    new_final.append({"text": "<end>", "is_final": True})
                elif finalized == n:
                    new_final.append({"text": "<end>", "is_final": True})
            # Non-final tail: provisional forms of what is spoken and not yet final.
            tail = []
            for i in range(finalized, revealed):
                tail.append(tok(lead_of[i] + prov[i].strip() if lead_of[i] else prov[i], toks[i][1], False))
            if pending_opener is not None and revealed:
                tail.insert(0, tok(pending_opener[0], pending_opener[1], False))
            # Provisional words firm up a bit between frames.
            for i in range(finalized, revealed):
                if prov[i] != finals[i] and rng.random() < 0.35:
                    prov[i] = finals[i] if rng.random() < 0.7 else provisional(rng, finals[i])
            if revealed >= n and finalized < n and kind in ("resplit", "long"):
                # hold the whole provisional sentence a few frames before it splits
                pass
            frames.append({"t": round(t, 2), "tokens": new_final + tail})
            if revealed == n and finalized < n and kind in ("resplit", "long") and chunk_i == 0 and not new_final:
                t += FRAME_S * 3  # the long sentence sits provisional for a moment
        if late is not None:
            carry_punct = late
        t += 0.6 + rng.random() * 0.8  # pause between utterances
        clock_ms += 500

    if carry_punct is not None:  # nothing follows: it ends the take
        frames.append({"t": round(t, 2), "tokens": [tok(carry_punct, clock_ms, True), {"text": "<end>", "is_final": True}]})
        final_texts.append(carry_punct)
        t += FRAME_S

    transcript = "".join(final_texts)
    return Take(index=index, seed=f"{seed}:{index}", kind=kind, frames=frames, final_tokens=final_texts,
                transcript=transcript, last_t=t, words=len(transcript.split()))


def plan_user(rng: random.Random, take: Take, rate: float, forced: str | None) -> None:
    """Optional user actions: keys mid-take, keys right after stop, caret moves. Fractions are of the replay's wall time."""
    roll = rng.random()
    mode = forced or ("none" if roll >= rate else rng.choice(["mid", "post", "cursor", "mid+post", "cursor+post", "mid+cursor"]))
    user: dict = {"mode": mode}
    if "mid" in mode:
        user["mid"] = sorted(round(rng.uniform(0.2, 0.8), 2) for _ in range(rng.randint(1, 3)))
    if "post" in mode:
        user["post"] = rng.randint(1, 2)
    if "cursor" in mode:
        user["cursor"] = [round(rng.uniform(0.3, 0.85), 2)]
        user["cursor_pos"] = rng.choice(["start", "middle", "late"])
    user["chars"] = [rng.choice(MARKERS) for _ in range(3 + 1 + 1)]
    take.user = user


# ---------------------------------------------------------------------------------------------
# Simulator plumbing
# ---------------------------------------------------------------------------------------------


class Sim:
    def __init__(self, udid: str, verbose: bool):
        self.udid = udid
        self.verbose = verbose
        self.env = dict(os.environ, LEGATO_SIMULATOR=udid)
        self.tool_errors: list[str] = []
        self.journal_dir = self._journal_dir()

    def run(self, argv: list[str], timeout: float = 60) -> subprocess.CompletedProcess:
        return subprocess.run(argv, env=self.env, capture_output=True, text=True, timeout=timeout)

    def ctl(self, *args: str, timeout: float = 60) -> str:
        r = self.run(["bash", str(CTL), "--target", "sim", *args], timeout)
        if r.returncode != 0 and args[0] != "wait":
            raise RuntimeError(f"ctl {' '.join(args)} failed: {(r.stdout + r.stderr).strip()[:300]}")
        return r.stdout

    def command(self, name: str, *args: str, wait: float = 30) -> dict:
        """Send a bridge command and return its terminal record (done / control.done)."""
        cid = self.ctl("send", name, *args).strip().splitlines()[-1]
        out = self.ctl("wait", cid, str(int(wait)), timeout=wait + 15)
        rec: dict = {}
        for line in out.splitlines():
            try:
                j = json.loads(line)
            except ValueError:
                continue
            if j.get("event") in ("done", "control.done", "error", "reply"):
                rec = j
        if rec.get("event") == "error" or rec.get("ok") is False:
            raise RuntimeError(f"{name} failed: {rec}")
        return rec

    def _journal_dir(self) -> Path:
        for argv in (["xcrun", "simctl", "get_app_container", self.udid, BUNDLE, GROUP],
                     ["xcrun", "simctl", "get_app_container", self.udid, BUNDLE, "data"]):
            r = self.run(argv)
            p = r.stdout.strip()
            if r.returncode == 0 and p:
                return Path(p) / "Library/Caches"
        raise RuntimeError("cannot find the app's container: is the build installed?")

    def tap_key(self, ident: str) -> None:
        # The keyboard's accessibility tree is now and then caught mid-redraw (part of the keys missing): try again.
        for attempt in range(6):
            r = self.run(["axe", "tap", "--id", ident, "--udid", self.udid], 30)
            if r.returncode == 0 or "No accessibility element matched" not in r.stdout + r.stderr:
                break
            time.sleep(0.15)
        if r.returncode != 0:
            raise RuntimeError(f"axe tap {ident} failed: {(r.stdout + r.stderr).strip()[:200]}")

    def has_key(self, ident: str) -> bool:
        r = self.run(["axe", "describe-ui", "--udid", self.udid], 30)
        return f'"{ident}"' in r.stdout

    # app diagnostics (live2.cleanup timings prove the scripted cleaner ran, not the network one)
    def _diag_path(self) -> Path | None:
        r = self.run(["xcrun", "simctl", "get_app_container", self.udid, BUNDLE, "data"])
        p = Path(r.stdout.strip()) / "Library/Caches/audio-diag.jsonl" if r.returncode == 0 else None
        return p

    def diag_mark(self) -> int:
        p = self._diag_path()
        return p.stat().st_size if p and p.exists() else 0

    def diag_since(self, mark: int) -> list[dict]:
        p = self._diag_path()
        if not p or not p.exists() or p.stat().st_size < mark:
            return []
        with p.open("rb") as f:
            f.seek(mark)
            data = f.read().decode("utf-8", "replace")
        out = []
        for line in data.splitlines():
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
        return out

    # journal ------------------------------------------------------------------------------
    def journal_mark(self) -> int:
        p = self.journal_dir / "edit-journal.jsonl"
        return p.stat().st_size if p.exists() else 0

    def journal_since(self, mark: int) -> list[dict]:
        cur = self.journal_dir / "edit-journal.jsonl"
        old = self.journal_dir / "edit-journal.1.jsonl"
        size = cur.stat().st_size if cur.exists() else 0
        chunks: list[bytes] = []
        if size < mark and old.exists():  # rotated while the take ran
            chunks.append(old.read_bytes()[mark:])
            mark = 0
        if cur.exists():
            with cur.open("rb") as f:
                f.seek(mark)
                chunks.append(f.read())
        out = []
        for line in b"".join(chunks).decode("utf-8", "replace").splitlines():
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
        return out


def field_state(sim: Sim) -> dict:
    return sim.command("harness-state", wait=15)


# ---------------------------------------------------------------------------------------------
# Running one take
# ---------------------------------------------------------------------------------------------


@dataclass
class Result:
    take: Take
    text: str = ""
    entries: list = field(default_factory=list)
    failures: list = field(default_factory=list)  # (invariant id, message)
    notes: list = field(default_factory=list)
    tool_errors: list = field(default_factory=list)
    taps: list = field(default_factory=list)       # what the tool did as the user
    acted_at: list = field(default_factory=list)   # wall seconds after the replay started, after each user action
    contended: bool = False
    dropped: list = field(default_factory=list)
    resyncs: int = 0
    cleaned: str = ""  # "clean" / "raw" / "none" / "n/a"
    wall: float = 0.0


def quiet_journal(sim: Sim, seconds: float = 1.0, limit: float = 60) -> bool:
    """True once the journal stopped growing for `seconds` (somebody else drives the simulator otherwise)."""
    deadline = time.time() + limit
    while time.time() < deadline:
        a = sim.journal_mark()
        time.sleep(seconds)
        if sim.journal_mark() == a:
            return True
    return False


def run_take(sim: Sim, take: Take, args, workdir: Path) -> Result:
    res = Result(take)
    start_wall = time.time()
    try:
        if not quiet_journal(sim):
            res.contended = True
            res.notes.append("journal kept growing before the take: another driver is using this simulator")
        sim.command("harness-clear", wait=15)
        time.sleep(0.4)
        st = field_state(sim)
        if st.get("text"):
            res.tool_errors.append(f"field not empty after clear: {st.get('text')[:60]!r}")
        name = f"stress-{os.getpid()}-{take.index}.json"
        path = workdir / name
        path.write_text(json.dumps({"note": "keyboard-stress synthetic timeline", "responses": take.frames}))
        sim.ctl("put", str(path), name)
        mark = sim.journal_mark()
        diag_mark = sim.diag_mark()

        t0 = time.time()
        cid = sim.ctl("send", "dictation-debug-replay", name, str(args.speed)).strip().splitlines()[-1]
        waiter = subprocess.Popen(["bash", str(CTL), "--target", "sim", "wait", cid, str(int(take.last_t / args.speed + 120))],
                                  env=sim.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        dur = take.last_t / args.speed
        actions: list[tuple[float, str, object]] = []  # (wall seconds after t0, kind, arg)
        u = take.user
        chars = iter(u.get("chars", []))
        for f in u.get("mid", []):
            actions.append((f * dur, "key", next(chars)))
        for f in u.get("cursor", []):
            actions.append((f * dur, "cursor", u.get("cursor_pos", "middle")))
        actions.sort(key=lambda a: a[0])
        post = [next(chars) for _ in range(u.get("post", 0))]

        def user_thread() -> None:
            try:
                for at, kind, arg in actions:
                    delay = t0 + at - time.time()
                    if delay > 0:
                        time.sleep(delay)
                    do_action(sim, res, kind, arg, take, mark)
                    res.acted_at.append(time.time() - t0)
                if post:
                    # right after stop: the keyboard's live snapshot turns complete before cleanup lands
                    dl = time.time() + dur + 60
                    while time.time() < dl:
                        if any(e.get("kind") == "live" and e.get("snapshot", {}).get("complete") for e in sim.journal_since(mark)):
                            break
                        time.sleep(0.05)
                    for c in post:
                        do_action(sim, res, "key", c, take, mark, after_stop=True)
                        res.acted_at.append(time.time() - t0)
            except Exception as e:  # noqa: BLE001
                res.tool_errors.append(f"user actions: {e}")

        th = threading.Thread(target=user_thread)
        th.start()
        try:
            out, err = waiter.communicate(timeout=dur + 130)
        except subprocess.TimeoutExpired:
            waiter.kill()
            out, err = "", "replay wait timed out"
            res.tool_errors.append("replay did not finish")
            try:
                sim.command("dictation-debug-replay-cancel", wait=10)
            except Exception:  # noqa: BLE001
                pass
        th.join()
        if "control.done" not in out:
            res.tool_errors.append(f"replay completion not seen: {(out + err).strip()[-200:]}")

        # settle: the field text and the journal stop changing (a status that stays up is noted, not waited for)
        last, stable, deadline = None, 0, time.time() + 120
        while time.time() < deadline:
            st = field_state(sim)
            cur = (st.get("text"), sim.journal_mark())
            stable = stable + 1 if cur == last else 0
            last = cur
            if stable >= 3:
                break
            time.sleep(0.8)
        else:
            res.tool_errors.append("field never settled (120 s): text or journal kept changing")
        if st.get("status"):
            res.notes.append(f"keyboard status still showing after the take settled: {st.get('status')!r}")
        res.text = st.get("text", "")
        res.entries = sim.journal_since(mark)
        slow = [d for d in sim.diag_since(diag_mark) if d.get("event") == "live2.cleanup" and (d.get("ms") or 0) >= 500]
        if slow:
            res.tool_errors.append(f"{len(slow)} sentence cleanup(s) took >= 500 ms: the scripted cleaner was not used, so the real (paid) "
                                   "cleaner may have run; the stub is installed per keyboard session")
    except Exception as e:  # noqa: BLE001
        res.tool_errors.append(f"{type(e).__name__}: {e}")
    res.wall = time.time() - start_wall
    return res


def do_action(sim: Sim, res: Result, kind: str, arg, take: Take, mark: int, after_stop: bool = False) -> None:
    if kind == "key":
        sim.tap_key(f"key.{arg}")
        res.taps.append(("key", arg, "post" if after_stop else "mid"))
    elif kind == "cursor":
        text = field_state(sim).get("text", "")
        n = len(text.encode("utf-16-le")) // 2
        off = {"start": 0, "middle": n // 2, "late": max(0, n - 12)}[arg]
        sim.command("harness-cursor", str(off), wait=15)
        res.taps.append(("cursor", off, "mid"))


# ---------------------------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------------------------

JOINT_PATTERNS = {
    "word , word (space before punctuation)": re.compile(r"[^\s,.?] [,.?](?!\w)|[^\s,.?] [,.?]\s"),
    "doubled space": re.compile(r"  +"),
    "doubled punctuation": re.compile(r",,|\.\.(?!\.)|, ,|\. \.|,\.|\.,"),
}


def ngrams(text: str, n: int = 3) -> collections.Counter:
    words = re.findall(r"[a-z]+", text.lower())
    return collections.Counter(tuple(words[i:i + n]) for i in range(len(words) - n + 1))


def markers_in(text: str) -> int:
    return sum(text.lower().count(c) for c in MARKERS)


def short_diff(expected: str, actual: str, width: int = 38) -> str:
    sm = difflib.SequenceMatcher(None, expected, actual, autojunk=False)
    parts = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        parts.append(f"@{i1}: expected {expected[max(0, i1 - 12):i2 + 12]!r} got {actual[max(0, j1 - 12):j2 + 12]!r}")
        if len(parts) >= 3:
            break
    head = f"len expected={len(expected)} actual={len(actual)}"
    return head + "; " + "; ".join(parts) if parts else head


def words_missing_after(take: Take, text: str, acted_wall: float | None, speed: float, margin: float = 0.5) -> list[str]:
    """The transcript's words first heard after `acted_wall` (+ margin) whose provisional forms never differed, that the
    field does not show (in order, case and punctuation aside)."""
    if acted_wall is None:
        return []
    first_seen: dict[int, float] = {}
    shown: dict[int, set] = collections.defaultdict(set)
    finals: list[tuple[str, int]] = []
    for fr in take.frames:
        for tk in fr["tokens"]:
            if tk.get("text") == "<end>" or "start_ms" not in tk:
                continue
            first_seen.setdefault(tk["start_ms"], fr["t"])
            shown[tk["start_ms"]].update(re.findall(r"[a-z']+", tk["text"].lower()))
            if tk.get("is_final"):
                finals.append((tk["text"], tk["start_ms"]))
    spoken: list[tuple[str, bool]] = []  # (word, counted)
    for tx, ms in finals:
        ws = re.findall(r"[a-z']+", tx.lower())
        late = first_seen.get(ms, 0) / speed > acted_wall + margin
        for w in ws:
            spoken.append((w, late and shown[ms] == set(ws)))
    # The words after the action go on at the caret, which may be anywhere in the take: they are looked for on their own.
    start = next((i for i, (_, counted) in enumerate(spoken) if counted), None)
    if start is None:
        return []
    after = spoken[start:]
    have = re.findall(r"[a-z']+", text.lower())
    sm = difflib.SequenceMatcher(None, [w for w, _ in after], have, autojunk=False)
    matched = {i for blk in sm.get_matching_blocks() for i in range(blk.a, blk.a + blk.size)}
    return [w for i, (w, counted) in enumerate(after) if counted and i not in matched]


def check(res: Result, args) -> None:
    take, text, entries = res.take, res.text, res.entries
    if res.tool_errors:
        return
    key_inputs = [i for i, e in enumerate(entries) if e.get("kind") == "input"]
    cursor_inputs = [i for i, e in enumerate(entries) if e.get("kind") == "resync" and e.get("reason") == "cursorMoved"]
    inputs = sorted(key_inputs + cursor_inputs)  # the user's first input is the earliest of either
    typed_keys = [t[1] for t in res.taps if t[0] == "key"]
    cursor_moves = [t for t in res.taps if t[0] == "cursor"]
    if len(key_inputs) != len(typed_keys):
        res.contended = True
        res.notes.append(f"journal shows {len(key_inputs)} user keys but the tool tapped {len(typed_keys)}: foreign or lost input")
    if cursor_moves and not cursor_inputs:
        res.notes.append("the keyboard never saw the caret move (no cursorMoved resync)")
    res.dropped = [e for e in entries if e.get("kind") == "dropped"]
    res.resyncs = sum(1 for e in entries if e.get("kind") == "resync")
    user_acted = bool(inputs) or bool(res.taps)

    # 1. duplicated spans (>= 3 words appearing more often than in the transcript)
    field_ng, base_ng = ngrams(text), ngrams(take.transcript)
    dup = [(" ".join(g), c, base_ng.get(g, 0)) for g, c in field_ng.items() if c > max(base_ng.get(g, 0), 1) or (c > 1 and base_ng.get(g, 0) < c)]
    if dup:
        res.failures.append(("1", "duplicated phrase: " + "; ".join(f"{g!r} x{c} (transcript x{b})" for g, c, b in dup[:3])))

    # 2. joint artefacts Legato introduced (matches touching a user key are ignored)
    for label, rx in JOINT_PATTERNS.items():
        bad = []
        for m in rx.finditer(text):
            around = text[max(0, m.start() - 1):m.end() + 1].lower()
            if any(c in around for c in MARKERS) and user_acted:
                continue
            if rx.search(take.transcript) and len(rx.findall(take.transcript)) >= len(rx.findall(text)):
                continue
            bad.append(text[max(0, m.start() - 14):m.end() + 14])
        if bad:
            res.failures.append(("2", f"{label}: {bad[0]!r}" + (f" (+{len(bad) - 1})" if len(bad) > 1 else "")))

    expected = take.expected_clean
    if not typed_keys:
        # 3. nothing happened to the field: exactly the cleaned text (the offline stream cleaner capitalizes
        #    every word and removes no fillers) or, if cleanup never landed, exactly the raw transcript.
        raw = norm_ws(take.transcript)
        if text == expected:
            res.cleaned = "clean"
        elif text == raw:
            res.cleaned = "raw"
            if not res.dropped:
                res.failures.append(("5", "cleanup never landed (raw transcript in the field) and the journal shows no `dropped`"))
        elif cursor_inputs and res.dropped:
            # The user moved the caret during the take: Legato edits nothing of it from then on (no swap), keeps it
            # as typed and says so (`dropped`: the cleaned take is in History).
            res.cleaned = "kept"
        else:
            res.cleaned = "wrong"
            res.failures.append(("3", ("(caret moved) " if cursor_moves else "") + "field != cleaned text: " + short_diff(expected, text)))
            if norm_ws(text) == text and text.lower() == expected.lower():
                res.notes.append("differs in letter case only")
    else:
        res.cleaned = "n/a"
    if user_acted:
        # 4. every user character survives, none duplicated or lost
        for c in set(typed_keys):
            want, have = typed_keys.count(c), text.lower().count(c)
            if have != want:
                res.failures.append(("4", f"user key {c!r}: typed {want}, field has {have}"))
        # A key the keyboard got before it typed anything of the take (its first words not heard yet) is text the take
        # follows, like text typed before the mic: the take's own edits do not come after it.
        first_live = next((i for i, e in enumerate(entries) if e.get("kind") == "sent" and e.get("lane") == "live"), None)
        during = [i for i in inputs if first_live is not None and i > first_live]
        first = during[0] if during else None
        if first is not None:
            stop = next((i for i, e in enumerate(entries) if e.get("kind") == "live" and e.get("snapshot", {}).get("complete")), len(entries))
            bad = []
            for i, e in enumerate(entries):
                if i <= first or e.get("kind") != "sent" or e.get("lane") == "user":
                    continue
                op = e.get("op") or {}
                if (op.get("delete") or 0) > 0 or (op.get("move") or 0) != 0:
                    bad.append((i, e.get("lane"), op, "after stop" if i >= stop else "while speaking"))
                elif "insert" in op and i >= stop and args.strict_inserts:
                    bad.append((i, e.get("lane"), op, "insert after stop"))
            if bad:
                res.failures.append(("4", f"{len(bad)} Legato delete/move after the user's first input: "
                                          + "; ".join(f"{l}:{o} {w}" for _, l, o, w in bad[:3])))
            # 6. the take goes on at the caret after the user acted: every word spoken after the user's last action
            #    reaches the field (a word whose provisional form differed may stay as first typed, so it is not counted)
            missing = words_missing_after(take, text, max(res.acted_at) if res.acted_at else None, args.speed)
            if missing:
                res.failures.append(("6", f"{len(missing)} word(s) spoken after the user's last action never reached the field: "
                                          + " ".join(missing[:8])))
            # informational: the text without the user's keys should still be the cleaned take
            rest = re.sub("[" + MARKERS + MARKERS.upper() + "]", "", text)
            if norm_ws(rest).lower() != expected.lower():
                res.notes.append("without the user's keys the field differs from the cleaned take (" + short_diff(expected.lower(), norm_ws(rest).lower())[:140] + ")")
    if res.dropped:
        res.notes.append("dropped: " + ", ".join(sorted({str(d.get("reason")) for d in res.dropped})))


# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", required=True)
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--takes", type=int, default=20)
    ap.add_argument("--only", type=int, action="append", help="run only this take index (repeatable)")
    ap.add_argument("--kinds", default="", help="comma list of " + ",".join(KINDS))
    ap.add_argument("--user", default="auto", help="auto | none | mid | post | cursor | mid+post | ... (forces the user action)")
    ap.add_argument("--user-rate", type=float, default=0.5, help="share of takes with user actions in auto mode")
    ap.add_argument("--speed", type=float, default=3.0)
    ap.add_argument("--chunk-ms", type=int, default=120, help="stream cleaner chunk interval (cleanup lands over len/6 chunks)")
    ap.add_argument("--no-launch", action="store_true")
    ap.add_argument("--strict-inserts", action="store_true", help="also fail on Legato inserts after stop once the user typed")
    ap.add_argument("--dry-run", action="store_true", help="print the generated takes, touch nothing")
    ap.add_argument("--out", default=str(Path.home() / "Library/Caches/legato/keyboard-stress"))
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    kinds = [k for k in args.kinds.split(",") if k]
    for k in kinds:
        if k not in KINDS:
            sys.exit(f"unknown kind {k}")
    takes: list[Take] = []
    for i in range(args.takes):
        if args.only and i not in args.only:
            continue
        rng = random.Random(args.seed * 7919 + i)
        take = gen_take(args.seed, i, rng.choice(kinds) if kinds else None)
        plan_user(rng, take, args.user_rate, None if args.user == "auto" else args.user)
        takes.append(take)

    if args.dry_run:
        for t in takes:
            print(f"take {t.index:02d} seed={t.seed} kind={t.kind} words={t.words} chars={len(t.transcript)} frames={len(t.frames)} "
                  f"user={t.user.get('mode')} {t.user.get('mid', '')}")
            print(f"    transcript: {t.transcript[:160]!r}")
            print(f"    cleaned   : {t.expected_clean[:160]!r}")
        return 0

    stamp = time.strftime("%Y%m%d-%H%M%S")
    outdir = Path(args.out) / f"{stamp}-seed{args.seed}"
    outdir.mkdir(parents=True, exist_ok=True)
    sim = Sim(args.udid, args.verbose)

    if not args.no_launch:
        try:
            sim.ctl("terminate")
        except RuntimeError:
            pass  # not running
        sim.ctl("launch", "-LegatoKeyboardHarness", "YES", timeout=90)
    # The stream cleaner is read when the keyboard session opens: set it before the keyboard comes up.
    sim.command("dictation-debug-mode", "live", wait=20)
    sim.command("dictation-debug-stream", str(args.chunk_ms), wait=20)
    # The cleanup pipeline is built when the keyboard session opens (the app warms it at launch with the real
    # cleaner, which would make paid Claude calls): closing and reopening the session rebuilds it with the stub.
    sim.command("harness-hidden", wait=20)
    time.sleep(1.0)
    sim.command("harness-visible", wait=20)
    sim.command("keyboard-tap", wait=20)
    if not sim.has_key("key.z"):
        print("tool error: the keyboard's letter keys are not on screen (is -LegatoKeyboardHarness active?)", file=sys.stderr)
        return 2
    print(f"keyboard-stress: seed={args.seed} takes={len(takes)} speed={args.speed} chunk-ms={args.chunk_ms} out={outdir}")

    results: list[Result] = []
    for t in takes:
        res = run_take(sim, t, args, outdir)
        check(res, args)
        results.append(res)
        report_take(res, outdir)
    return summarize(results, args, outdir)


def report_take(res: Result, outdir: Path) -> None:
    t = res.take
    if res.tool_errors:
        outcome = "TOOL-ERROR"
    elif res.failures:
        outcome = "FAIL " + ",".join(sorted({f[0] for f in res.failures}))
    elif res.contended:
        outcome = "CONTENDED"
    else:
        outcome = "PASS" + (f" ({res.cleaned})" if res.cleaned not in ("n/a", "") else " (user)")
    user = t.user.get("mode", "none")
    print(f"take {t.index:02d} seed={t.seed} kind={t.kind:<7} words={t.words:<3} chars={len(t.transcript):<3} user={user:<11} "
          f"dropped={len(res.dropped)} resync={res.resyncs} {res.wall:4.0f}s -> {outcome}")
    for _, msg in res.failures:
        print(f"      ! {msg}")
    for e in res.tool_errors:
        print(f"      ? {e}")
    for n in res.notes:
        print(f"      . {n}")
    if res.failures or res.tool_errors or res.contended:
        d = outdir / f"take-{t.index:02d}"
        d.mkdir(exist_ok=True)
        (d / "timeline.json").write_text(json.dumps({"responses": t.frames}))
        (d / "result.json").write_text(json.dumps({
            "seed": t.seed, "kind": t.kind, "user": t.user, "taps": res.taps, "transcript": t.transcript,
            "expected_clean": t.expected_clean, "field": res.text, "failures": res.failures, "notes": res.notes}, indent=1))
        (d / "journal.jsonl").write_text("\n".join(json.dumps(e) for e in res.entries))
        print(f"      artifacts: {d}")


def summarize(results: list[Result], args, outdir: Path) -> int:
    fails = [r for r in results if r.failures]
    errs = [r for r in results if r.tool_errors]
    cont = [r for r in results if r.contended and not r.failures and not r.tool_errors]
    passed = [r for r in results if not r.failures and not r.tool_errors and not r.contended]
    print("\nsummary")
    print(f"  takes {len(results)}   pass {len(passed)}   fail {len(fails)}   tool-error {len(errs)}   contended {len(cont)}")
    inv = collections.Counter(f[0] for r in fails for f in r.failures)
    names = {"1": "duplicated span", "2": "joint artefact", "3": "final text != cleaned", "4": "user input hurt", "5": "silent drop",
             "6": "words lost after the user acted"}
    print("  invariant failures: " + (", ".join(f"#{k} {names[k]} x{v}" for k, v in sorted(inv.items())) or "none"))
    by_kind: dict[str, list[Result]] = collections.defaultdict(list)
    for r in results:
        by_kind[r.take.kind].append(r)
    print(f"  {'kind':<8} {'takes':>5} {'fail':>5} {'tool':>5}")
    for k, rs in sorted(by_kind.items()):
        print(f"  {k:<8} {len(rs):>5} {sum(1 for r in rs if r.failures):>5} {sum(1 for r in rs if r.tool_errors):>5}")
    nouser = [r for r in results if r.cleaned in ("clean", "raw", "wrong")]
    print(f"  untouched takes {len(nouser)}: cleaned {sum(r.cleaned == 'clean' for r in nouser)}, raw {sum(r.cleaned == 'raw' for r in nouser)}, wrong {sum(r.cleaned == 'wrong' for r in nouser)}")
    reasons = collections.Counter(str(d.get('reason')) for r in results for d in r.dropped)
    print(f"  journal dropped: {sum(len(r.dropped) for r in results)} ({dict(reasons) or 'none'}), resync: {sum(r.resyncs for r in results)}")
    (outdir / "summary.json").write_text(json.dumps({
        "seed": args.seed, "takes": len(results), "pass": len(passed), "fail": len(fails), "tool_error": len(errs),
        "contended": len(cont), "invariants": inv}, indent=1))
    if fails:
        return 1
    if errs or cont:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
