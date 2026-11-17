# Legato internal harness

For guest-only Mac field acceptance, use the [native macOS VM workflow](mac-vm.md).

`scripts/device/ctl.sh [--target device|sim|mac] <command>` drives internal builds through one file inbox, registry and JSONL protocol. Device remains the default. Ordinary Release builds exclude the endpoint, overlays and session-probe entry points.

```bash
ctl=scripts/device/ctl.sh
LEGATO_SIMULATOR=92445A7A-9AF7-49BA-B61B-94C679A3F2E4 bash "$ctl" --target sim launch -LegatoFakeEngine 'A simulator fixture.'
id="$(bash "$ctl" --target mac send ping)"
bash "$ctl" --target mac wait "$id" 10
```

Use the same target and identity environment for every command. State is isolated by target, device/simulator or Mac root, and bundle identity, even when `LEGATO_STATE` points at one shared scratch parent. IDs include the sending process to avoid collisions between simultaneous clients.

| Configuration | Meaning |
| --- | --- |
| `LEGATO_DEVICE` | Physical identifier; existing project iPhone by default. |
| `LEGATO_SIMULATOR` / `LEGATO_SIM_UDID` | Simulator UDID; defaults to `booted`. Multiple booted simulators require an explicit UDID. |
| `LEGATO_BUNDLE` / `LEGATO_BUNDLE_ID` | Target bundle; iOS `de.gruenwald.legato`, Mac `de.gruenwald.legato.mac` by default. |
| `LEGATO_GROUP` / `LEGATO_GROUP_ID` | App Group identifier; defaults to `group.de.gruenwald.legato`. |
| `LEGATO_APP` | App bundle path for install/launch. Mac defaults to `~/Applications/Legato.app`; iOS install defaults to the corresponding device/simulator Debug build. |
| `LEGATO_MAC_ROOT` | Absolute shared Mac bridge root; defaults to `~/Library/Caches/Legato/debug-bridge`. Pass the same environment when starting the app. |
| `LEGATO_MAC_DATA_ROOT`, `LEGATO_MAC_GROUP_ROOT` | Mac roots for general data/group pulls; group pulls require an explicit group root. |
| `LEGATO_STATE` / `LEGATO_DEVICE_STATE` | Scratch parent for target-specific cache, counters, captured PID and diagnostics. |
| `LEGATO_DEVICE_TIMEOUT` | Per-operation host cap, default 10 seconds. |
| `LEGATO_DEVICE_INSTALL_TIMEOUT` | Install cap, default 120 seconds. |
| `LEGATO_DEVICE_LAUNCH_TIMEOUT`, `LEGATO_DEVICE_SEND_TIMEOUT` | Total launch/send budgets, default 30 seconds. |

Bundle/group overrides route the CLI; they do not rewrite signing, entitlements, URL schemes or runtime identity. An isolated physical test composition must configure all app/keyboard/widget identities consistently. This session's isolated composition uses bundle `de.gruenwald.legato.reliable-harness`, group `group.de.gruenwald.legato.reliable-harness` and URL scheme `legatoharness94`.

## Device logs

`bash scripts/device/ctl.sh device-logs [--since 10m]` (`<num>m|h|d`) runs `log collect --device-udid "$LEGATO_DEVICE" --last <dur>` and filters the archive with `log show --archive … --info --debug --predicate 'subsystem == "de.gruenwald.legato"'` (app, keyboard and widget share the subsystem). The text lands in `$STATE/pulled/device-logs.txt`; the command prints its path, the line count and the latest `composer.view blank` / `composer.poll stale|start|stop` lines (#225). Needs the phone unlocked and paired, and sudo: `log collect` reads an attached device only as root, so the command prompts once (`sudo -v`) before collecting; run it from your own terminal. Device target only. Messages carry counts and flags, never draft text. `LEGATO_DEVICE_LOGS_TIMEOUT` caps collect and filter (300 s).

## Keyboard edit journal

Internal and debug keyboards write every field-queue event with full text to the App Group (`Library/Caches/edit-journal.jsonl`, rotated at about 2 MB into `edit-journal.1.jsonl`). Pull it with `xcrun devicectl device copy from --device "$LEGATO_DEVICE" --domain-type appGroupDataContainer --domain-identifier group.de.gruenwald.legato --source Library/Caches/edit-journal.jsonl --destination /tmp/edit-journal.jsonl` (or `bash scripts/device/ctl.sh pull --group Library/Caches/edit-journal.jsonl`), then replay it in a test with `JournalReplay` (`Tests/LegatoKeyboardCoreTests/EditJournalTests.swift`). It holds what was typed: share it only with Jakob's consent.


For iOS dictation regressions, replay the reported takes and several nearby completed takes before changing the queue. Use `JournalReplay.run` to compare issued operations with the phone recording. Use `JournalReplay.simulate` or a synthetic reproduction of the recorded host behavior to check the final field against the intended cleanup and complete recognition revisions. A matching bad operation sequence reproduces the defect. A candidate passes when the final field text matches the expected text, including untouched text and user edits. Confirm host-dependent outcomes in an isolated field on the iPhone. Keep original journals local and commit only synthetic fixtures. Use the existing audio diagnostics for capture or timing questions before asking for a short, explicitly approved audio sample.

## Physical-device screenshots

`bash scripts/device/native-control.sh screenshot /tmp/phone.png` captures the entire physical display, including the foreground host, actual system/custom keyboard and safe areas. `bash scripts/device/native-control.sh record /tmp/phone.mp4 10` records a bounded screen video. Both use `LEGATO_DEVICE` and never launch, install or activate an app or simulator. Coordinate the visible state with anyone using the phone before capture; avoid key/settings screens.

These commands wrap Apple’s `devicectl device capture` service, verified with Xcode 27.2 and a wireless physical iPhone (1206 × 2622 PNG). The project toolchain pin stays unchanged; an older selected Xcode without this command produces a clear capability error. Use the selected Xcode’s `xcrun devicectl device capture screenshot --help` for its native options. Native touch controls use a separate signed `LegatoNativeControl` XCTest runner: `tree`, `tap X Y`, `hold X Y SECONDS`, `swipe X1 Y1 X2 Y2` and `label "Accessibility label"`. Coordinates are screen points, not screenshot pixels (the current iPhone is 402 × 874 points, screenshot scale 3). `keyboard` long-presses the globe at (42, 820) and chooses the native “Legato” menu item on that iPhone. Every invocation activates the already running `LEGATO_BUNDLE` (default `de.gruenwald.legato`), performs one action and exports the real accessibility tree plus an `XCUIScreen` screenshot beneath `.claude/tmp/native-control` (override `LEGATO_NATIVE_OUTPUT`).

The runner has no target-app dependency, never reinstalls or launches Legato, and refuses a stopped target app. Xcode may briefly foreground its runner; coordinate exclusive phone ownership for touch commands and restore the desired field/keyboard before visual acceptance. `LEGATO_NATIVE_BUILD` selects its incremental build directory. Only the standalone test runner is provisioned/installed. These are manual UAT controls, outside the CI suite.

## Commands and lifecycle

`send`, `wait`, `log`, `say`, `ask`, `status`, `block`, `clear` and `pull` use the same protocol on all targets. `commands` lists the running registry; platform-specific operations may return an explicit error. `pull --group <relative-path>` selects the App Group. Absolute paths and parent traversal are rejected.

`build` selects the matching app platform. `install` uses CoreDevice or simctl. Mac installation is explicitly unavailable: point `LEGATO_APP` at the desired app and run that build directly. Mac `launch` uses LaunchServices with an explicit bridge-root environment and captures the PID from a fresh bridge handshake, so the app remains running after the invoking terminal/tool exits. Mac termination only targets a captured PID whose executable still belongs to that app; device termination similarly requires a PID captured by this CLI. Simulator termination selects its bundle and UDID. `foreground`/`background` bring the target forward or background it without restarting; Mac uses the harness for these actions.

Launch waits for a new bridge generation with the launched PID, after stale inbox cleanup. Process creation alone is insufficient. Simulator/Mac inbox publication is atomic; device delivery retains same-ID retries and read-back reconciliation for ambiguous CoreDevice failures. Failed log pulls preserve the last complete snapshot and report their transport cause. CoreDevice's native timeout is at least five seconds; a separate owned-process host deadline preserves shorter CLI budgets and reaps timed-out tool children.

## Acceptance and completion

A regular `done` record completes a short command. Long controls return `{accepted:true,waitFor:"control.done"}` first, then emit `control.done` with the same ID after their owned work settles. Admission remains FIFO; an accepted operation reserves ownership synchronously and runs outside the command pump, allowing ping/state/release/cancel commands to proceed. A second pending toggle cancels/joins the original start before stopping it. Probe admission sees pending controls before their tasks start.

`wait <command-id> [seconds]` follows `done.waitFor`, including `reply` for asks. A probe acknowledgement additionally contains a different `probeID`; waiting on the command ID follows that UUID to `session.probe.done`. Waiting directly on the probe UUID also finds an already-recorded terminal event. Error records, `ok:false` and non-`ok` control/probe outcomes return nonzero. A reply choice of `timeout` remains a successful reported answer.

`wait <command-id> [seconds] --ack` returns only the immediate `done`/error acknowledgement. This is useful for held-preparation tests:

```bash
id="$(bash "$ctl" --target sim send toggle)"
bash "$ctl" --target sim wait "$id" 5 --ack
release="$(bash "$ctl" --target sim send preparation-release)"
bash "$ctl" --target sim wait "$release" 5
bash "$ctl" --target sim wait "$id" 15
```

Event-name waits observe events added after their initial snapshot. Prefer command IDs or probe UUIDs when completion may already exist. `ask --timeout <integer-seconds>` begins its reply deadline after actual presentation; queued cards do not spend their timeout while hidden.

## Checks and evidence

Run `bash scripts/device/tests/ctl-test.sh` for CLI fixtures and `swift test --filter LegatoDevHarnessTests` for the shared contract. Fixtures substitute external tool boundaries; they do not prove physical device behavior. `scripts/e2e/ios-sim.sh` now sends triggers through this CLI and retains its existing scenario assertions.

`LEGATO_SIMULATOR=<booted-test-UDID> bash scripts/device/tests/sim-smoke.sh` drives an already installed internal build: held preparation/release/cancellation, probe refusal, native AX message dismissal/reply/queued timeout, overlay hit testing, clear and probe terminal routing. It uses a scripted engine for dictation. It snapshots and restores the three preferences changed by fake-engine launch flags, including on failure. Its output directory preserves command IDs, native accessibility trees, actual app logs and completion records. Mac overlay verification is `scripts/device/tests/mac-overlay-smoke.sh`; it is a native-app check, separate from fixtures.

The pre-fix installed simulator reproduced both the held-toggle FIFO deadlock and a queued card failing to emit `shown`/start its timer. Fresh-build verification and physical/Mac proof must be reported separately: simulator model availability does not establish on-phone performance, and a fake microphone does not establish real ASR. No maintained paid-provider test or model download is implied.

On 2026-10-30, the fresh simulator drive passed held-toggle/cancellation, native AX queued presentation/reply, hit testing and clear. Its Foundation Models measurements ran, but the final probe outcome was `restorationFailed`; the CLI correctly propagated nonzero status for both command ID and historical probe UUID. This is a simulator restoration gap, not a successful restoration claim. Existing scenarios `a`, `m`, `n2` and `n3` subsequently passed all 53 assertions using Xcode's ad-hoc simulator signing and real App Group storage. Manual re-signing of an unsigned build did not establish that storage fixture and produced two history failures; those failed observations were retained separately.

The final isolated iPhone drive on 2026-10-30 passed Foundation Models foreground, background and background-audio probes, followed by a real microphone start/release after each. Both background modes reported actual background app state. Sending an ordinary keyboard-arm request during the audio probe did not replace its owned microphone: diagnostics recorded one acquisition, teardown before restoration, the expected teardown input-loss event rejected for cancellation, and terminal `ok`. No Core ML weights were installed in the isolated phone app, so this establishes phone Foundation Models and microphone lifecycle behavior.

The final physical cold launch completed its fresh-generation handshake in 7.66 seconds. Ping send→wait completed in 3.83 seconds; the host observed its matching `done` 1.74 seconds after the device timestamp. The historical #94 cause remains unconfirmed; fixtures prove bounded transfers, preserved snapshots and readiness ordering independently of this device result.

Native Mac verification passed Foundation Models and installed Core ML measurements, model restoration and subsequent normal dictation. The retained Core ML second turn prefilled 64 tokens versus 905 for its fresh comparison, with equal replies. Live typed settings, busy hotkey/meeting admission during a probe, native ask reply and queued timeout, status focus, app-window blocking and clear were driven in the app. LaunchServices launch survived the CLI tool ending, and a later invocation received pong. All 11 common commands were present on phone, simulator and Mac. The original installed Mac bundle was restored afterward, with its signature and original executable hash verified; the original phone app was untouched.

Native validation used the available Xcode 27.2; the pinned Xcode 26.6 was unavailable locally. Toolchain pins were preserved. Full package suites and both unsigned app builds now run locally through `scripts/ci/test.sh` before enqueueing; the protected queue's Ubuntu `gate` reports that policy without verifying local results.

Ordinary iOS and Mac Release builds passed the internal endpoint/overlay/probe-adapter exclusion scan with valid source controls (three iOS Mach-O files, one Mac executable). The existing iOS fake/e2e exclusion gate also passed. Repeat these checks with `bash scripts/ci/release.sh check` and `bash scripts/ci/release.sh mac-release`; `mac-build` retains its separate Debug compilation role. The scanner fixture suite rejects leaked embedded endpoints, stale controls and empty/resource-only bundles.

### Dictation and Magic offline controls

For interactive simulator input, `harness-text <text>` seeds the field, `harness-key <character>|space|delete|return` presses a keyboard key, and `harness-cursor <UTF-16 offset>` moves the caret. `harness-type` ignores arguments and runs its fixed typing fixture; it does not type supplied text. On Mac, `dictation-debug-pause` supplies a synthetic eligible pause for offline delivery checks, not microphone-detector validation.

Use a Debug internal build with `-LegatoOfflineFixture YES` for provider-free dictation cleanup and Magic. Open the in-app keyboard harness with `-LegatoKeyboardHarness YES`. Synthetic speech uses `dictation-debug-line`, `dictation-debug-tail`, `dictation-debug-stop`, or `dictation-debug-replay`; these do not prove microphone or physical background capture behavior. A line is a final segment with no endpoint after it: a line without a sentence end gets no sentence pass, no pause pass and no long-pause whole pass, and is cleaned at `dictation-debug-stop`. The mic key or a replay ends a line's take still open first, as its stop would. `microphone-arm`, `microphone-release` and `microphone-interrupt` address the microphone host directly.

Whole-take dictation (the "Send dictation" setting: On stop, After a pause, As you speak; Mac and iOS; the iOS default is `As you speak`, see above, so set `dictation-debug-mode onStop` first). In the two take modes the lines of a take are held and cleaned in ONE call, then written once: on stop (`dictation-debug-stop`, or the hotkey / mic key) or, in After a pause, when the quiet timer runs out (the pill / word row rim fills toward it; a held Mac hotkey never auto-sends). Drive it: set the mode (`defaults write de.gruenwald.legato.mac dictation.send afterPause` and `defaults write de.gruenwald.legato.mac dictation.pause -float 3` on the Mac; the App Group defaults on iOS, or the Settings screen), then `dictation-debug-line "<text>"` several times, `dictation-state` (take phase `buffering|cleaning|failed`, `takeLength`, `takeLines`, `countdownDeadline`, `mode`; Mac also phase/outbox/delivered), then `dictation-debug-stop` (Mac: ends the session; iOS: ends the take like the mic key). `dictation-debug-fail-take [n]` makes the next n take cleanups fail twice (default 1), which leaves the failed state: nothing is typed until `dictation-retry` (cleans again, writes once) or `dictation-insert-raw` (writes the raw text once); these are the pill's / keyboard's Retry and Insert as-is buttons without a click. `dictation-debug-stream <chunkMs> [failAfterChunks]` (or `off`) replaces the provider with a scripted streaming cleaner for the next takes (no key needed): it yields the take capitalized in 6-character chunks, `chunkMs` apart; with `failAfterChunks` the first stream fails after that many chunks (the partial stays in the field until `dictation-retry` / `dictation-insert-raw` erases it), later streams succeed. `dictation-debug-stream <chunkMs> reply <text>` makes every take stream that text instead, so a result the guard rejects can be produced on cue: the streamed text is erased and the raw take is typed. New speech after a failure joins the held text into one take. Closing the keyboard (iOS) or a cancel chord (Mac; `dictation-cancel` without the hotkey) drops an unsent take.

Live dictation (`As you speak`) appends speech at the user caret. Revisions and field cleanup use minimal character edits during admitted pauses or at stop (on iPhone each sentence is also cleaned as soon as it ends, and lands in the next gap between words); typing or moving the caret no longer permanently freezes the whole take. Intervening user changes win, and a cleared draft cannot receive its old result. Unknown selection or external context refuses automatic cursor movement and destructive edits while manual input remains available. A failed jump can use only a separately verified safe block fallback; otherwise text stays recoverable in History with its confirmed outcome. All writers share one queue; on iPhone it edits in chunks (hops within sight, one delete run, one insert, the hop back) checked once, `docs/field-editing.md`. Without a microphone, replay a recorded Soniox token timeline: `ctl.sh --target device put scripts/device/fixtures/dictation-replay-neutral.json replay.json` copies it into the bridge directory, then with the keyboard open on the ABC typing surface (see `keyboard-tap`) and a text field focused:

```bash
ctl=scripts/device/ctl.sh
$ctl send dictation-debug-model sonnet                   # cleanup model (App Group): haiku | sonnet
$ctl send dictation-debug-mode live                      # the setting (App Group); `onStop`, `afterPause` for the others
id=$($ctl send dictation-debug-replay replay.json 1)     # <file> [speed] [pcm-file]; speed 2 replays twice as fast
$ctl wait "$id"                                          # accepted at once; `control.done` follows when the take is written
$ctl wait control.done 120
$ctl send dictation-state                                # mode, liveRun, liveVersion, liveSentences, liveComplete
$ctl send dictation-debug-replay-cancel                  # stops a running replay
```

A token-only replay (no PCM) takes its recorded endpoints as pauses (the microphone's audio does not count meanwhile), so revisions and per-sentence cleanup land in its gaps. For activity-gate and pause-admission testing, put the matching original audio in the bridge directory too, then send `dictation-debug-replay replay.json 1 take.pcm`. Audio must be raw 16 kHz mono signed little-endian PCM16 from the same time origin as the recorded responses. One monotonic clock feeds 20 ms PCM frames through the actual `DictationActivity` before responses at the same timestamp, retaining the provider's endpoint delay; audio never goes to a provider. Use speed 1 for human acceptance. Input names must be plain basenames of regular files (no symlinks); timeline files are limited to 16 MB and PCM to 10 minutes / 19,200,000 bytes as operational safety bounds, not measured user thresholds. Cancel and stop join the replay clock before returning. Synthetic PCM with recorded real provider responses can prove functional gate behavior on the phone; it does not prove microphone capture or general voice/noise detection quality.

The timeline goes through the provider decoder and segmenter (`SonioxClient.injectDebugFrame`), so segments, the live tail, cleanup per sentence (a Claude key is needed, else sentences stay raw) and the keyboard's typing run for real; the replay ends the take like the mic key. Input is the streaming spike's cache record (`{"responses":[{"t":<seconds>,"tokens":[{"text","is_final","start_ms","end_ms","confidence","language"}]}]}`), a bare array of those, or JSON lines; `<fin>` tokens and `finished` are dropped. The checked-in fixture is synthetic text (a garden to-do) with three flips behind the head, endpoints between five sentences, about 32 s. `dictation-replay-fragments.json` (synthetic, about 23 s) speaks one plan in pause-separated fragments with fillers ("Um.", "so, uh, the plan", "Yeah.") and a whether/weather flip: once the take ends the field holds the two cleaned sentences, fillers gone. `dictation-replay-corrections.json` (synthetic, 62 words, about 37 s) puts corrections in later fragments ("…moved to Tuesday." / "Uh," / "no sorry, Wednesday.", "cc Lina." / "Actually, no, cc Tom.") and a German "um" before a time: a take of at most 80 words is cleaned again whole at the stop (`live2.whole`; `live2.run.end` reports `units`, `whole` = `landed|fallback|none` and `stopMs`, the stop to the landed target), so only the corrected versions remain. `harness-clear` also lets the keyboard's last live run go, so nothing types into the cleared field again. Never commit a recording of real dictation. While it runs, typing or moving the caret rebases later edits around user changes; it does not authorize deleting user text or replaying unchanged characters. Incoming speech and manual input take priority over background corrections. Offline, `dictation-debug-stream <chunkMs>` set before the keyboard session's first sentence also stands in for the sentence cleanup (capitalizes every word, like a take), so the cleanup's one diff at the end can be seen without a key; in the in-app keyboard harness (`-LegatoKeyboardHarness YES`, simulator) `harness-cursor <utf16Offset>` is a tap in the field, `harness-text <text>` sets the field's text at once (`\n` is a line break; synthetic text only), `harness-key <character>|space|delete|return` presses one of the keyboard's keys, and `-LegatoHarnessWindow <n>` at launch cuts the windows around the cursor to n characters like a host's, so instruction reads walk.

Instruction mode (the keyboard's magic key; iOS Debug builds): with the toggle on, speech is an instruction about the field's text, and turning it off runs it; nothing runs on its own. Without the key, set the toggle from the bridge as the keyboard would (`instruction-mode latched|held|off`; a later change of the real key overrides it). Speech comes from a replay of a synthetic instruction (`scripts/device/fixtures/instruction-replay-{formal,bullets,shorter}.json`, put like the dictation fixture) or `dictation-debug-line`; `instruction-debug "<text>"` runs a typed instruction in one step. A Claude key is needed (the model uses the retained setting, `composer.liveModel`, default Haiku). With the keyboard open on the ABC surface and a field holding some text:

```bash
$ctl put scripts/device/fixtures/instruction-replay-formal.json formal.json
$ctl send instruction-mode latched                       # speech is now an instruction
$ctl send dictation-debug-replay formal.json 1; sleep 5  # a 3 s instruction; instruction-state then shows transcriptChars
$ctl send instruction-mode off                           # runs it: reads the field, asks the model, lands the edit
$ctl send instruction-state                              # phase listening|reading|running|result|undone|failed, scope, message, canUndo
$ctl send instruction-intent undo                        # the strip's taps: run | undo | accept | dismiss
```

The keyboard reads what it knows without moving the cursor (the selection, the text dictated in this keyboard session, the windows around the cursor) and walks the field upward only when no session text exists and the field shows more (`Reading the text…` in the word row while the cursor moves; keys are held back meanwhile). A walk accepts a window only after two identical reads that stitch onto what was read, stops at the field's start, a quote header or quoted lines, a signature `-- ` or 3,000 characters, and fails loudly rather than return wrong text. The result lands as minimal character edits of exactly the text the model was shown, only while the field still shows it; unchanged letters, spaces and punctuation stay in place. On iPhone the edit goes in chunks, one place at a time (`docs/field-editing.md`), including cleanup and Undo. A host that will not keep the verified cursor position stops the edit with recovery instead of retyping unchanged tails. Diagnostics: `instruction.run` lines (`ok`, `scope`, `reads`, `chars`, `newChars`, `reason`, `ms`) in `audio-diag.jsonl`; the keyboard's trace has `instruction read|walk|edit` lines (counts only).

Diagnostics (internal builds): `live2.*` lines in `Library/Caches/audio-diag.jsonl` (`pull Library/Caches/audio-diag.jsonl`), counts, characters and milliseconds only, never text: `live2.run.start` / `live2.run.end`, `live2.publish` (the app wrote snapshot version `v`: segments, chars), `live2.cleanup` (one per cleanup unit: consecutive segments grouped up to a sentence end of 6+ words, a line break or 40 words, the rest flushed at the take's end; landed or left raw with `reason`, `rawChars`, `chars`, `ms`, `segments` (segments in the unit); `changed` when the cleaned unit differs from its raw words, `dropped` when cleanup removed it (all filler), `shown` when it changed the target at once, `held` while the take still runs) and `live2.ack` (the keyboard's counters: `applies` (ops sent), `rewrites`, `inserted`, `deleted`, `freezes` with `lastFreeze` = `keystroke|cursor|selection|drift|field`, `drifts`, `waits` (an op waited for the field to confirm it), `confirmTimeouts` (no confirmation within 800 ms: frozen), `coalesced` (snapshots dropped for a newer one while the queue was busy); `v` and `ms` when it applied a version in full, `ms` counting from the app's write). The older `live.*` lines belong to the Live Activity cleanup trace.

## Interactive raw keyboard probe

Development builds expose one operator-chosen raw proxy action at a time through [`keyboard-probe.sh`](keyboard-probe.md), with an exclusive queue lease. This is a measurement tool, not a production reader or a predefined test walk.

## Exact persisted History lookup

Internal builds support `ctl.sh send history-entry <run-UUID>` followed by `ctl.sh wait <command-id>`. The existing History store reads the persisted file and returns only that exact entry, or `found: false`; there is no list operation. Use known synthetic run IDs to verify raw-text recovery and confirmed cleanup status after sending or clearing a field. Replies and bridge logs contain that entry's full text: keep raw output private unless the entry and all field context are synthetic. Ordinary Release builds exclude this endpoint.

## Conditional-edit stress validation

Run `scripts/e2e/keyboard-stress.sh` on an explicitly owned simulator with two recorded seeds. Use `--speed 1` for human-rate timing evidence; accelerated runs are separately labeled race stress. The in-app keyboard harness exercises the real queue and UIKit field but does not establish real-extension host behavior, microphone quality or physical-phone latency.

The validator preserves duplicate/joint checks, exact untouched-result checks, user-character counts and future-word checks. After manual input it now verifies character preservation rather than the retired prohibition on every subsequent cursor move or deletion. Reserved synthetic user letters must survive in order; unchanged user text cannot be deleted and retyped. For an explicitly recorded case-only field cleanup, only characters that the target actually changes may be removed, and a user-letter case change must return at its exact verified slot. This preserves the field-cleanup contract for manually typed text while detecting corruption hidden by a matching final character count. `--strict-inserts` remains an optional legacy diagnostic, not the conditional-edit acceptance rule.

Pure preservation-oracle checks: `uv run --python 3.14.5 python -m unittest discover -s scripts/e2e/keyboard-stress -p test_preservation.py`. They include a delete/retype corruption whose final field matches, reordered user input, and an unchanged character deleted by a case-only edit. No simulator, API or paid call is involved.

## Persistent physical XCTest runner

For a long-lived owned WDA measurement runner, set both `-default-test-execution-time-allowance 7200` and `-maximum-test-execution-time-allowance 7200` with `-test-timeouts-enabled YES`. Setting only the maximum left an observed runner ending after about ten minutes; Xcode exposes the default and maximum as separate settings. The two-hour allowance is test-tool lifecycle policy, not a product latency claim. Restart only the runner/session owned by the current test, preserve shared Appium, and keep endpoints/session identifiers in private operator notes. Verify microphone release before showing Home at every handback.
