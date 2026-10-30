# Composer offshoot

Composer is a developer spike on `epic/composer` (#108), separate from `main` and `live`. One microphone activation creates one Room, a mutable document, two Claude conversations and a session log. Soniox supplies speech; the live agent composes incrementally and the restructure agent revisits the whole document. There is no on-device transcription fallback.

## Architecture

`LegatoComposerDoc` is Foundation-only. Its lines have stable IDs, a kind (`p`, `li`, `oli`, `h1`–`h3`, `quote`), a version and identified words. Words carry optional confidence, language, alternatives and a pinned flag. ASR appends lines and retains a separate append-only raw transcript; agents rewrite through document operations. Word diffs preserve surviving IDs and confidence; newly written words have no ASR confidence. Edits check only the versions of touched lines. Replacing a pinned word fails; Undo fails if the affected lines changed afterward. Transactions contain `txnId`, `origin`, `ops`, `inverse`, `groupID`, revision and animation hunks.

`LegatoRoom.Room` is the host actor that orders envelopes and applies document mutations. Only publications minted by `ComposerDocument` can enter `doc.*`; arbitrary `publish` calls to those channels fail. Subscribers receive independent streams: UI defaults to newest-only, other participants to unbounded. The host session explicitly uses an unbounded UI stream to process all transactions before publishing keyboard values.

| Channel | Contents |
| --- | --- |
| `asr.tail` | Uncommitted display text; never agent input. |
| `asr.segment` | Final words and segment timing/boundary metadata. |
| `user.intent`, `hint` | Mode changes, taps, picks and bound spoken corrections. |
| `doc.ops`, `doc.snapshot` | Applied transaction and resulting document. |
| `agent.status` | Busy state, pending targets and agent diagnostics. |
| `alternatives` | Candidate alternatives. |
| `session` | Lifecycle, transcription status and errors. |

`ComposerSession` in `LegatoAppServices` owns the microphone, Room, Soniox client, agents, alternatives and hint binder. Its intercepted segment routing lets the binder consume a short correction instead of appending it as content. Lifecycle is `listening → trailing → finalPass → done`: mic-off drains transcription and current agent work, then requests the final restructure pass. Insert takes the surface's current rendered text immediately and cancels remaining work; Cancel ends the session without insertion. Both retain logs.

## Speech, agents and corrections

`LegatoSoniox` connects to `wss://stt-rt.soniox.com/transcribe-websocket` with bearer authentication, model `stt-rt-v5`, mono 16 kHz PCM16, German/English hints, language identification and endpoint detection. Context includes up to 100 vocabulary terms plus a bounded mode/personal-prompt summary. Final subword tokens merge into words using their minimum confidence. Segments close on an endpoint, final punctuation, a gap of 0.7 s, 25 words or 8 s. The grey tail also includes finalized words awaiting a segment boundary. Stop sends `finalize`, waits for `<fin>`, sends an empty frame and waits for `finished`; idle transport sends keepalive after 10 s without audio.

`LegatoAgent.AgentRunner` shares document/event context between two independent conversations. Raw ASR segments remain context; only binder-accepted ASR append transactions, bound hints or user intents admit a live turn. Events arriving during a turn queue together. A hint overlapping a pending edit cancels and restarts that turn. Restructure starts after four accepted appended segments, a 2.5 s pause after at least two, an explicit request, or final-pass admission. It never overlaps another restructure pass. These rules do not create idle turns.

Prompt layers are bundled base → mode (Message, Email, Prompt, Note) → personal prompt → vocabulary. Conversations append messages and request ephemeral caching; they reseed beyond 50,000 input/cache tokens or five minutes idle. Defaults are `claude-haiku-5-5` for live and `claude-sonnet-5-5` for restructure; both can use `claude-opus-5-5`. Haiku disables thinking, Sonnet uses `between_tools` with low effort, Opus uses `adaptive` with low effort. The Opus setting corrects the original epic's shared Sonnet/Opus description.

Tools are `view`, `replace_lines`, `insert_lines`, `delete_lines`, `replace_in_line`, `move_lines`, `set_kind`, `set_mode`, `note`, plus live-only `request_restructure`. Schemas are strict, with automatic tool choice and eager input streaming. The wire `versions` value is an array such as `[{"line":"L…","version":3}]`; the document API uses a dictionary internally. Stale versions, unknown IDs, ambiguous replacements or pinned-word changes return `is_error`; the agent must view and retry. Presented lines look like `L… v3 [li] text`, with low-confidence markup such as `⟨word|0.42⟩` stripped from edits.

Words below 0.6 confidence receive up to three ranked alternatives from vocabulary, platform spellchecking and learned correction pairs with bigram scoring. Tint is neutral from 0.9 upward. A pick directly replaces and pins the word. A tap arms a window from 0.6 s before to 4 s after its timestamp; the first completed overlapping segment closes it. A segment starting after the tap, within four seconds and containing one to three words becomes a pinned correction and a hint. Other speech remains content. Choices feed `VocabularyLearner`; repeated agent corrections can promote pairs for later sessions.

## Surfaces and setup

`LegatoComposerUI` is shared SwiftUI code for the keyboard and Mac panel, without `LegatoCore`. Stable line IDs animate moves; Pow supplies line disappearance, and line insertion/replacement uses blur/opacity. One `WordFX` clock per line caps blurred runs at twelve. Pow 1.0.5 is vendored at its pinned upstream revision with explicit `CGFloat` constants and typed rotation expressions for Swift 6.2 compatibility (see `Vendor/Pow/UPSTREAM.md`). Pending streamed tool targets highlight lines; links make words tappable for alternatives, and pinned words are underlined. Performance on the real animated keyboard remains an acceptance check.

On iOS, the composer pane sits above the keyboard controls. `link.composer` carries a full snapshot and accumulated hunks since the acknowledged revision at a minimum 0.1 s publish interval. History retains 100 revisions; a gap requests snapshot recovery. Per-intent keys `link.composer.intent.<uuid>` carry timestamped actions. A composer lease keeps host heartbeats alive. Insert calls `textDocumentProxy.insertText` in the extension. The extension receives values and sends intents; provider connections and keys remain in the host app.

On Mac, the hotkey starts/stops the same host session (Right Command by default, with tap-to-latch and hold-to-talk behavior). A nonactivating `NSPanel` cannot become key or main, preserving the captured editor's focus. The panel chooses the target application's screen and appears below its notch, or top-centre on a display without one. It contains mode, Stop, Undo, Insert and Cancel controls. Insert uses the captured `FieldWriter` target with paste fallback.

Enter Claude and Soniox keys in each platform's Settings; they are local Keychain entries (`de.gruenwald.legato.claude` and `de.gruenwald.legato.soniox`, account `api-key`). Settings also provide each agent's model and a personal prompt. Preferences use `composer.liveModel`, `composer.restructureModel`, `composer.personalPrompt` and `composer.mode`. Logs have no enable/disable setting. Missing keys produce a visible error and retain the session log.

## Reading and pulling sessions

The host writes `sessions/<UUID>/` beneath its Documents directory:

- `room.jsonl`: one JSON envelope per line, ordered by host `seq`.
- `final.md`: the last document's plain line text at completion, Insert or Cancel; line-kind formatting applied by a surface is not included.
- `audio.m4a`: mono 16 kHz AAC from the same microphone chunks forwarded to Soniox. A session failing before capture can have no audio file.

Each envelope has `seq`, `id`, `channel`, `participant`, `tMono`, `tOrigin`, optional `baseRev`/`causedBy`, and `payload`. `tMono` is host system uptime at publication, not a wall-clock date. `tOrigin` preserves origin timing; follow `causedBy` to connect a segment, hint or transaction. `baseRev` identifies the document revision attached to a publication.

Agent diagnostics are `agent.status` envelopes distinguished by `payload.event`: `conversation.seed` records system prompt and tools; `request` records a full-request SHA-256 hash and the latest appended message; `response.delta` preserves each SSE event type and data string; `ttft` records seconds to the first SSE event; `usage` contains merged provider counters including cache tokens; `tool.result` contains the result and `is_error`. `pending.edit` names targets before application; `error` records failures. TTFT here includes any first provider SSE event, so it does not necessarily mean first visible text or first complete tool input.

For an internal iPhone build, pull one session or all sessions with the device harness:

```bash
bash scripts/device/ctl.sh --target device pull-sessions Documents/sessions
bash scripts/device/ctl.sh --target device pull-sessions "Documents/sessions/<UUID>"
```

`pull-sessions` is an alias of `pull`, requiring a container-relative path; files land in the target-specific `$LEGATO_STATE` scratch tree under `pulled/`. Keep the same target, bundle identity and device environment between commands. For Mac, set `LEGATO_MAC_DATA_ROOT` to the host's actual Documents directory and pull relative to that root:

```bash
LEGATO_MAC_DATA_ROOT="$HOME/Documents" bash scripts/device/ctl.sh --target mac pull-sessions "sessions/<UUID>"
```

Check the app's actual Documents location if sandbox/container configuration differs. See [the harness guide](../scripts/device/README.md) for transport and root overrides. Inspect a copied session locally:

```bash
jq -c 'select(.channel == "session") | {seq, tMono, payload}' room.jsonl
jq -c 'select(.channel == "agent.status") | {seq, participant, payload}' room.jsonl
jq -c 'select(.channel == "doc.ops") | {seq, causedBy, payload}' room.jsonl
```

Read audio and segment events alongside document edits before judging lost content or correction quality. Compare cache counters and cold/warm TTFT separately. `SessionLog` redacts supplied secrets, sensitive field names and bearer/key patterns; this does not remove spoken personal content, prompts or audio. Logs are detailed session artifacts.

## Acceptance still pending

Package implementation and compiled apps establish different evidence from real speech acceptance. No paid Composer sessions were run for this documentation leg: accessible Claude/Soniox credentials were unavailable. Message, Email and Prompt still need one real session on each platform, retained log paths, and joint review with Jakob. No threshold change is justified yet. Issue #118 remains open; merging this document does not complete its sessions, findings or epic checklist.

The [physical probe report](../spikes/composer-probe/README.md) establishes only requested keyboard layout heights of 600/1200/2000 pt on a 402×874 pt screen and idle available-memory samples around 156/148/137 MiB. It does not prove visible height/clipping, touch routing, animated memory headroom, blur FPS, host/keyboard RTT, Soniox quality, phone Claude timing or provider background survival. Harness/fixture success is separate from built-app and paid-provider proof.

Review the six real sessions for content retention, pinned corrections, mode behavior, Insert during an agent pass, stale-edit recovery, latency/cache use and microphone/provider shutdown. Record evidence before recommending changes to segmentation, confidence, alternatives or restructure thresholds. Extend existing findings where possible (#119–#124 are already reserved follow-ups); the return of this offshoot to `main` is a later decision.

The iPhone composer always uses a large composer pane above the compact prediction/tool strip. Idle, listening and error states share this layout; the composer surface does not show a QWERTY grid.
