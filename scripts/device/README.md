# Legato internal harness

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

Native validation used the available Xcode 27.2; the pinned Xcode 26.6 was unavailable locally. Toolchain pins were preserved. Full package suites remain the protected merge queue's gate; a green PR report alone does not establish that gate.

Ordinary iOS and Mac Release builds passed the internal endpoint/overlay/probe-adapter exclusion scan with valid source controls (three iOS Mach-O files, one Mac executable). The existing iOS fake/e2e exclusion gate also passed. Repeat these checks with `bash scripts/ci/release.sh check` and `bash scripts/ci/release.sh mac-release`; `mac-build` retains its separate Debug compilation role. The scanner fixture suite rejects leaked embedded endpoints, stale controls and empty/resource-only bundles.

### Composer transcriber bypass (Debug builds)

Use the real iPhone host/keyboard or Mac composer with synthetic **Soniox output**, while keeping the real word merger, segmenter, hint binder, alternatives, Claude agents, document and UI. This validates composer behavior; it does not validate ASR, microphone quality or audio timing. No Soniox credentials, socket, microphone or audio artifact is needed by default. A Claude key is required; finalized segments and mic-off can make real paid Claude requests.

Mac credential storage requires a development-signed build with its application-identifier entitlement. Build it with `LEGATO_MAC_SIGNED=1 LEGATO_BUNDLE=de.gruenwald.legato.mac.composer-debug scripts/device/ctl.sh --target mac build` (actual Mac destination allows Xcode's device registration/profile creation). Set `LEGATO_APP` to that build's `Debug/Legato.app` and an isolated `LEGATO_MAC_ROOT` when launching and controlling it. The ordinary unsigned Mac compile cannot access the Data Protection Keychain. Launch the isolated UAT app with `launch -LegatoDisableHotkeys YES` to prevent ambient global shortcuts from starting ordinary microphone sessions while agents use bridge controls. This launch-only flag is Debug-only.

Import credentials once without putting secrets in arguments, launch defaults or bridge logs:

```bash
scripts/device/ctl.sh --target mac import-keys /private/path/credentials.json
```

The local JSON file must be mode `0600` and contain `anthropic` and `soniox` strings. The tool copies it to the app's private bridge directory; the host saves the existing keychain services and deletes its copy, returning only storage booleans. The local source remains yours to remove. Import does not start any client. Use `--target device` for the phone. Only one build/instance per target should consume that bridge inbox.

Send commands sequentially and wait for each command ID before continuing:

```bash
ctl=scripts/device/ctl.sh
id=$($ctl --target mac send composer-debug-start message)
$ctl --target mac wait "$id"
id=$($ctl --target mac send composer-debug-text 'Guten Morgen' partial 0)
$ctl --target mac wait "$id"
id=$($ctl --target mac send composer-debug-frame '{"tokens":[{"text":"Guten","is_final":true,"start_ms":0,"end_ms":200,"confidence":0.4,"language":"de"},{"text":" Morgen","is_final":true,"start_ms":200,"end_ms":400,"confidence":0.98,"language":"de"},{"text":"<end>","is_final":true}]}')
$ctl --target mac wait "$id"
id=$($ctl --target mac send composer-state)
$ctl --target mac wait "$id"
```

For fixtures, pass the file content as the single JSON argument: `send composer-debug-frame "$(cat /path/frame.json)"`. These are transcript data, never credential files. Frame JSON uses Soniox's `tokens` array with `text`, `is_final`, optional `confidence`, `language`, `start_ms` and `end_ms`. Partial frames replace the speculative tail; final frames append final tokens. Use `<end>` to close a segment. `composer-stop` runs mic-off, final-token drain and the real final pass; `<fin>` and `finished` are reserved for that lifecycle. Text convenience accepts `<text> partial|final <start_ms>` and generates spaced word tokens with 200 ms duration, confidence 0.95 and language de. Use raw JSON for precise metadata.

ABC dictation route (iOS Debug builds only; the keyboard must be open on the ABC typing surface, see `keyboard-tap`): `dictation-debug-line "<text>"` delivers one finalized line to the dictation route where a Soniox segment would arrive (cleanup, link, keyboard typing and the field run for real), and `dictation-debug-tail "<partial>"` sets the live partial (empty clears it). Both fail with a clear error on any other surface.

Mac dictation hotkey (Debug builds only): `dictation-debug-line "<text>"` and `dictation-debug-tail "<partial>"` work like the iOS pair, but start a microphone-free dictation session on the field in front when none runs (no keys needed; the line is cleaned with Claude when a key exists, else typed raw with a key notice). `dictation-debug-stop` ends that session, `dictation-toggle` runs the real hotkey path, `dictation-state` reports phase, pending lines, outbox and fallbacks.

Whole-take dictation (the "Send dictation" setting: On stop, After a pause, Line by line; Mac and iOS; the iOS default is `As you speak`, see above, so set `dictation-debug-mode onStop` first). In the two take modes the lines of a take are held and cleaned in ONE call, then written once: on stop (`dictation-debug-stop`, or the hotkey / mic key) or, in After a pause, when the quiet timer runs out (the pill / word row rim fills toward it; a held Mac hotkey never auto-sends). Drive it: set the mode (`defaults write de.gruenwald.legato.mac dictation.send afterPause` and `defaults write de.gruenwald.legato.mac dictation.pause -float 3` on the Mac; the App Group defaults on iOS, or the Settings screen), then `dictation-debug-line "<text>"` several times, `dictation-state` (take phase `buffering|cleaning|failed`, `takeLength`, `takeLines`, `countdownDeadline`, `mode`; Mac also phase/outbox/delivered), then `dictation-debug-stop` (Mac: ends the session; iOS: ends the take like the mic key). `dictation-debug-fail-take [n]` makes the next n take cleanups fail twice (default 1), which leaves the failed state: nothing is typed until `dictation-retry` (cleans again, writes once) or `dictation-insert-raw` (writes the raw text once); these are the pill's / keyboard's Retry and Insert as-is buttons without a click. `dictation-debug-stream <chunkMs> [failAfterChunks]` (or `off`) replaces the provider with a scripted streaming cleaner for the next takes (no key needed): it yields the take capitalized in 6-character chunks, `chunkMs` apart; with `failAfterChunks` the first stream fails after that many chunks (the partial stays in the field until `dictation-retry` / `dictation-insert-raw` erases it), later streams succeed. `dictation-debug-stream <chunkMs> reply <text>` makes every take stream that text instead, so a result the guard rejects can be produced on cue: the streamed text is erased and the raw take is typed. New speech after a failure joins the held text into one take. Closing the keyboard (iOS) or a cancel chord (Mac; `dictation-cancel` without the hotkey) drops an unsent take.

Live dictation (the "Send dictation" setting `As you speak`, the iOS default: the keyboard types the words as they are spoken, corrects single words as they firm up, and puts in the cleaned sentences once, after the take ends). Every edit goes through the keyboard's edit queue: one op at a time, each confirmed by the field's context before the next; a snapshot that arrives meanwhile is diffed only once the queue is free (the newest one). Without a microphone, replay a recorded Soniox token timeline: `ctl.sh --target device put scripts/device/fixtures/dictation-replay-neutral.json replay.json` copies it into the bridge directory, then with the keyboard open on the ABC typing surface (see `keyboard-tap`) and a text field focused:

```bash
ctl=scripts/device/ctl.sh
$ctl send dictation-debug-model sonnet                   # cleanup model (App Group): haiku | sonnet
$ctl send dictation-debug-mode live                      # the setting (App Group); `onStop`, `afterPause`, `lineByLine` for the others
id=$($ctl send dictation-debug-replay replay.json 1)     # <file> [speed]; speed 2 replays twice as fast
$ctl wait "$id"                                          # accepted at once; `control.done` follows when the take is written
$ctl wait control.done 120
$ctl send dictation-state                                # mode, liveRun, liveVersion, liveSentences, liveComplete
$ctl send dictation-debug-replay-cancel                  # stops a running replay
```

The timeline goes through the provider decoder and segmenter (`SonioxClient.injectDebugFrame`), so segments, the live tail, cleanup per sentence (a Claude key is needed, else sentences stay raw) and the keyboard's typing run for real; the replay ends the take like the mic key. Input is the streaming spike's cache record (`{"responses":[{"t":<seconds>,"tokens":[{"text","is_final","start_ms","end_ms","confidence","language"}]}]}`), a bare array of those, or JSON lines; `<fin>` tokens and `finished` are dropped. The checked-in fixture is synthetic text (a garden to-do) with three flips behind the head, endpoints between five sentences, about 32 s. `dictation-replay-fragments.json` (synthetic, about 23 s) speaks one plan in pause-separated fragments with fillers ("Um.", "so, uh, the plan", "Yeah.") and a whether/weather flip: once the take ends the field holds the two cleaned sentences, fillers gone. `dictation-replay-corrections.json` (synthetic, 62 words, about 37 s) puts corrections in later fragments ("…moved to Tuesday." / "Uh," / "no sorry, Wednesday.", "cc Lina." / "Actually, no, cc Tom.") and a German "um" before a time: a take of at most 80 words is cleaned again whole at the stop (`live2.whole`; `live2.run.end` reports `units`, `whole` = `landed|fallback|none` and `stopMs`, the stop to the landed target), so only the corrected versions remain. `harness-clear` also lets the keyboard's last live run go, so nothing types into the cleared field again. Never commit a recording of real dictation. While it runs, tapping or typing in the field freezes what is typed so far (the rest still arrives at the cursor). Offline, `dictation-debug-stream <chunkMs>` set before the keyboard session's first sentence also stands in for the sentence cleanup (capitalizes every word, like a take), so the cleanup's one diff at the end can be seen without a key; in the in-app keyboard harness (`-LegatoKeyboardHarness YES`, simulator) `harness-cursor <utf16Offset>` is a tap in the field.

Diagnostics (internal builds): `live2.*` lines in `Library/Caches/audio-diag.jsonl` (`pull Library/Caches/audio-diag.jsonl`), counts, characters and milliseconds only, never text: `live2.run.start` / `live2.run.end`, `live2.publish` (the app wrote snapshot version `v`: segments, chars), `live2.cleanup` (one per cleanup unit: consecutive segments grouped up to a sentence end of 6+ words, a line break or 40 words, the rest flushed at the take's end; landed or left raw with `reason`, `rawChars`, `chars`, `ms`, `segments` (segments in the unit); `changed` when the cleaned unit differs from its raw words, `dropped` when cleanup removed it (all filler), `shown` when it changed the target at once, `held` while the take still runs) and `live2.ack` (the keyboard's counters: `applies` (ops sent), `rewrites`, `inserted`, `deleted`, `freezes` with `lastFreeze` = `keystroke|cursor|selection|drift|field`, `drifts`, `waits` (an op waited for the field to confirm it), `confirmTimeouts` (no confirmation within 800 ms: frozen), `coalesced` (snapshots dropped for a newer one while the queue was busy); `v` and `ms` when it applied a version in full, `ms` counting from the app's write). The older `live.*` lines belong to the Live Activity cleanup trace.

`composer-state` and action replies include `sessionID`, `inputSource`, `audioOrigin`, `microphoneLeaseActive`, `status`, `tail`, `pendingLineIDs`, and `document` with real line/word IDs, versions, confidence, language, pins and alternatives. Injection acknowledges the frame being decoded/published; Claude work continues asynchronously and must be polled through state. The session's `Documents/sessions/<sessionID>/room.jsonl` records `input.source` and every full injected frame with `inputSource: debug.transcriber`. No fake audio file is created.

Other controls use actual session actions: `composer-tap <lineID> <wordID> <offset_ms>`, `composer-pick <lineID> <wordID> <text>`, `composer-mode message|email|prompt|note`, `composer-undo`, `composer-cancel`, and `composer-insert-host`. Tap offsets use exactly `audioOrigin + offset_ms/1000`, sharing the injected token clock without sleeps. Query state for targets, tap, then inject correction speech at a matching offset. `composer-insert-host` immediately accepts the host document and cancels remaining work; it does **not** prove keyboard text-proxy delivery. On Mac, `composer-insert` uses the existing focused-field/paste delivery path. For actual phone keyboard Insert proof, launch the existing native field harness (`-LegatoKeyboardHarness YES -LegatoHarnessSystemField YES`) and tap the real keyboard button; `harness-status` is only the separate in-process keyboard harness.

Foreground is the default phone setup. For another app's keyboard, `composer-debug-start message microphone-lease` explicitly holds the existing real microphone lease for host liveness, without forwarding or recording audio. `microphoneLeaseActive` reports it. That path still requires microphone permission; do not describe it as audio-free background execution. Without a lease, iOS can suspend a background host. Normal mic starts still use Soniox and require its key. Controls and key import are unavailable in Release builds.
