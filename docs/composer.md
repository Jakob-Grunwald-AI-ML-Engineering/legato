# Composer offshoot

Composer is a developer spike on `epic/composer` (#108), separate from `main` and `live`. One microphone activation creates one Room, a mutable document, one writing conversation and a session log. Soniox supplies speech; the same selected writing model makes quick corrections, authors completed sentences during speech, consolidates during quiet pauses, and completes a final pass. There is no on-device transcription fallback.

## Architecture

`LegatoComposerDoc` is Foundation-only. Its lines have stable IDs, a kind (`p`, `li`, `oli`, `h1`–`h3`, `quote`), a version and identified words. Words carry optional confidence, language, alternatives and a pinned flag. ASR appends lines and retains a separate append-only raw transcript; the writer revises through document operations. Word diffs preserve surviving IDs and confidence; newly written words have no ASR confidence. Edits check only the versions of touched lines. Replacing a pinned word fails; Undo fails if the affected lines changed afterward. Transactions contain `txnId`, `origin`, `ops`, `inverse`, `groupID`, revision and animation hunks.

`LegatoRoom.Room` is the host actor that orders envelopes and applies document mutations. Only publications minted by `ComposerDocument` can enter `doc.*`; arbitrary `publish` calls to those channels fail. Subscribers receive independent streams: UI defaults to newest-only, other participants to unbounded. The host session explicitly uses an unbounded UI stream to process all transactions before publishing keyboard values.

| Channel | Contents |
| --- | --- |
| `asr.tail` | Uncommitted display text; never agent input. |
| `asr.segment` | Final words and segment timing/boundary metadata. |
| `user.intent`, `hint` | Mode changes, taps, picks and bound spoken corrections. |
| `correction.draft` | Captured correction preview and host countdown timestamps; not writer context. |
| `doc.ops`, `doc.snapshot` | Applied transaction and resulting document. |
| `agent.status` | Busy state, pending targets and agent diagnostics. |
| `alternatives` | Candidate alternatives. |
| `session` | Lifecycle, transcription status and errors. |

`ComposerSession` in `LegatoAppServices` owns the microphone, Room, Soniox client, writing agent, alternatives and hint binder. Its intercepted segment routing lets the binder consume a short correction instead of appending it as content. Lifecycle is `listening → trailing → finalPass → done`: mic-off drains transcription and current agent work, then requests a final turn from the same writer and model. Insert takes the surface's current rendered text immediately and cancels remaining work. The main Cancel/X ends the session and clears the composition, selection and captured correction without insertion; the correction popup X only discards its instruction. Session logs are retained.

## Speech, agents and corrections

`LegatoSoniox` connects to `wss://stt-rt.soniox.com/transcribe-websocket` with bearer authentication, model `stt-rt-v5`, mono 16 kHz PCM16, German/English hints, language identification and endpoint detection. Context includes up to 100 vocabulary terms plus a bounded mode/personal-prompt summary. Final subword tokens merge into words using their minimum confidence. Segments close on an endpoint, final punctuation, a gap of 0.7 s, 25 words or 8 s. The grey tail also includes finalized words awaiting a segment boundary. Stop sends `finalize`, waits for `<fin>`, sends an empty frame and waits for `finished`; idle transport sends keepalive after 10 s without audio.

`LegatoAgent.AgentRunner` owns one provider task and one conversation. Only binder-accepted ASR append transactions, structured targeted hints, user edits or user intents admit immediate work. Completed sentence punctuation admits a composing turn; two accepted chunks provide bounded progress when punctuation is absent. Pending chunks coalesce behind the current turn. Sentence turns may author the entire captured draft while newer speech continues, with mutation tools restricted to captured line IDs and their own replacements; newer ASR lines stay queued and untouched. Ordinary quick turns make small local spelling/punctuation corrections. A clear revision directive in any language may call `request_compose` once to escalate immediately through the same writer, without waiting for quiet or adding an acknowledgement request. Explicit word/quote corrections retain full tools, scoped to their target. New partial or final speech resets a 1-second quiet-period timer; partial/raw ASR is activity only and never model context. Queued ordinary content folds directly into a pause turn if that clock already elapsed, avoiding an extra quick roundtrip. A pause turn proactively authors rough speech, including general Auto prose, and may restructure; new speech cancels it and retires its stream before another turn begins. Stop drains pending quick input and completes a final turn through the same writer. Agent-authored document operations do not trigger new turns, and no second structure worker remains. Targeted instructions, direct user edits and UI mode changes preempt the current writer; streams retire before replacement requests start.

Prompt layers are bundled base → mode (Auto, Message, Email, Prompt, Note) → personal prompt → vocabulary. Auto loads existing specialized guidance through `load_writing_guidance` while staying in Auto. The current quick/sentence/targeted/pause/final instruction is appended to the user turn, keeping the phase-independent system/tool catalog stable. The conversation requests ephemeral caching and reseeds beyond 50,000 input/cache tokens or five minutes idle. The existing `composer.liveModel` preference selects the sole writing model; its saved choice is preserved, with Haiku as the unset default. Haiku disables thinking, Sonnet uses `between_tools` with low effort, and Opus uses `adaptive` with low effort. All phases use that same selection.

Tools are `view`, `replace_lines`, `insert_lines`, `delete_lines`, `replace_in_line`, `move_lines`, `set_kind`, `set_mode`, `request_compose` and `note`; Auto replaces `set_mode` with `load_writing_guidance`. There is no agent-delegation tool. Ordinary quick turns defer broad line replacement/insertion/deletion, moving and kind changes until a sentence, quiet-pause or final turn; targeted corrections can use them immediately. A deferral explicitly says to wait, instead of asking the model to refresh/retry. Schemas remain strict, with automatic tool choice and eager input streaming. The wire `versions` value is an array such as `[{"line":"L…","version":3}]`; the document API uses a dictionary internally. Genuine stale versions, unknown IDs, ambiguous replacements or pinned-word changes require a fresh view before retrying. Presented lines look like `L… v3 [li] text`, with confidence markup such as `⟨word|0.42⟩` stripped from edits.

Words below 0.6 confidence receive up to three ranked alternatives from vocabulary, platform spellchecking and learned correction pairs with bigram scoring. Tint is neutral from 0.9 upward. A pick directly replaces and pins the word. Tapping a word or selecting a quote captures subsequent speech as a correction draft instead of general dictation. The popup previews that draft; after 500 ms of quiet the host starts a one-second autosend countdown, interrupted by new speech. The wand sends immediately, with transcription drained at the existing boundary before the structured quote-targeted hint reaches the writer. Popup X discards captured and still-in-flight correction speech without editing the document. Choices feed `VocabularyLearner`; repeated agent corrections can promote pairs for later sessions. See [targeted correction and native evidence](uat/composer-quote-correction.md).

## Surfaces and setup

`LegatoComposerUI` is shared SwiftUI code for the keyboard and Mac panel, without `LegatoCore`. Stable line IDs animate moves; Pow supplies line disappearance, and line insertion/replacement uses blur/opacity. One `WordFX` clock per line caps blurred runs at twelve. Pow 1.0.5 is vendored at its pinned upstream revision with explicit `CGFloat` constants and typed rotation expressions for Swift 6.2 compatibility (see `Vendor/Pow/UPSTREAM.md`). Pending streamed tool targets highlight lines. The shared `WordFX` TextRenderer reports measured glyph bounds for hit testing, highlights and popup anchors; pinned words are underlined. A tap selects one word; deliberate native iOS press-and-slide or Mac press-and-drag selects a quote through the same range contract. Popup placement avoids the full visible marked extent, points to the first or last selected glyph row, and reserves text-free space when neither side fits. See [native quote selection and popup evidence](uat/composer-quote-correction.md). Performance on the real animated keyboard remains an acceptance check.

On iOS, the composer pane uses two remembered Medium/Full heights above the compact action strip, with native keyboard colors and no QWERTY grid. Height changes happen on release; smooth animation remains unresolved ([motion report](uat/composer-height-motion.md)). `link.composer` carries a full snapshot and accumulated hunks since the acknowledged revision at a minimum 0.1 s publish interval. History retains 100 revisions; a gap requests snapshot recovery. Per-intent keys `link.composer.intent.<uuid>` carry timestamped actions. A composer lease keeps host heartbeats alive. Insert calls `textDocumentProxy.insertText` in the extension. The extension receives values and sends intents; provider connections and keys remain in the host app.

On Mac, the hotkey starts/stops the same host session (Right Command by default, with tap-to-latch and hold-to-talk behavior). Opening the nonactivating `NSPanel` preserves the captured editor; clicking it enables panel-scoped keyboard shortcuts while retaining the insertion target. The panel chooses the target application's screen and appears below its notch, or top-centre on a display without one. Its action strip contains mode, Undo, disabled Redo, paper-plane Insert, Cancel, Mute and Dictate/Stop, with visible shortcuts. Insert uses the captured `FieldWriter` target with paste fallback.

Enter Claude and Soniox keys in each platform's Settings; they are local Keychain entries (`de.gruenwald.legato.claude` and `de.gruenwald.legato.soniox`, account `api-key`). Settings provide one writing-model selector and a personal prompt. The iOS companion has Compose/History/Settings tabs and a Settings-only system-keyboard gate for ordinary text entry. Its provider editors never display saved keys; each saves only its own nonblank replacement, preserving the other key. Mac Settings uses Overview, Writing, API Keys and Shortcut sidebar pages, with actual permission status in Overview and blank entries preserving saved keys. See [physical iOS settings checks](uat/composer-ios-companion.md) and [Mac settings checks](uat/composer-mac-settings.md). Preferences use `composer.liveModel`, `composer.personalPrompt` and `composer.mode`; old restructure-model preferences are no longer used. Logs have no enable/disable setting. Missing keys produce a visible error and retain the session log.

## Reading and pulling sessions

The host writes `sessions/<UUID>/` beneath its Documents directory:

- `room.jsonl`: one JSON envelope per line, ordered by host `seq`.
- `final.md`: the last document's plain line text at completion, Insert or Cancel; line-kind formatting applied by a surface is not included.
- `audio.m4a`: mono 16 kHz AAC from the same microphone chunks forwarded to Soniox. A session failing before capture can have no audio file.

Each envelope has `seq`, `id`, `channel`, `participant`, `tMono`, `tOrigin`, optional `baseRev`/`causedBy`, and `payload`. `tMono` is host system uptime at publication, not a wall-clock date. `tOrigin` preserves origin timing; follow `causedBy` to connect a segment, hint or transaction. `baseRev` identifies the document revision attached to a publication.

Agent diagnostics include `turn.phase` (`quick`, `sentence`, `targeted`, `pause`, `final`) and `turn.cancel` with its phase and are `agent.status` envelopes distinguished by `payload.event`: `conversation.seed` records system prompt and tools; `request` records a full-request SHA-256 hash and the latest appended message; `response.delta` preserves each SSE event type and data string; `ttft` records seconds to the first SSE event; `usage` contains merged provider counters including cache tokens; `tool.result` contains the result and `is_error`. `pending.edit` names targets before application; `error` records failures. TTFT here includes any first provider SSE event, so it does not necessarily mean first visible text or first complete tool input.

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

Package implementation and compiled apps establish different evidence from real speech acceptance. Real provider, device and native microphone evidence is recorded in [the phone report](uat/composer-phone.md), [Mac report](uat/composer-mac.md), and [native voice report](uat/composer-native-voice.md). Current one-writer validation is recorded in [the single-writer report](uat/composer-single-writer.md). Joint review, sustained background behavior and performance acceptance remain distinct from these bounded checks. No threshold change is justified yet. Issue #118 remains open; merging this document does not complete its sessions, findings or epic checklist.

The [physical probe report](../spikes/composer-probe/README.md) establishes only requested keyboard layout heights of 600/1200/2000 pt on a 402×874 pt screen and idle available-memory samples around 156/148/137 MiB. It does not prove visible height/clipping, touch routing, animated memory headroom, blur FPS, host/keyboard RTT, Soniox quality, phone Claude timing or provider background survival. Harness/fixture success is separate from built-app and paid-provider proof.

Review the six real sessions for content retention, pinned corrections, mode behavior, Insert during an agent pass, stale-edit recovery, latency/cache use and microphone/provider shutdown. Record evidence before recommending changes to segmentation, confidence, alternatives or restructure thresholds. Extend existing findings where possible (#119–#124 are already reserved follow-ups); the return of this offshoot to `main` is a later decision.
