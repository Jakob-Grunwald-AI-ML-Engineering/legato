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

Run `bash scripts/device/tests/ctl-test.sh` for CLI fixtures and `LEGATO_STUB_DEPS=1 swift test --filter LegatoDevHarnessTests` for the shared contract. Fixtures substitute external tool boundaries; they do not prove physical device behavior. `scripts/e2e/ios-sim.sh` now sends triggers through this CLI and retains its existing scenario assertions.

`LEGATO_SIMULATOR=<booted-test-UDID> bash scripts/device/tests/sim-smoke.sh` drives an already installed internal build: held preparation/release/cancellation, probe refusal, native AX message dismissal/reply/queued timeout, overlay hit testing, clear and probe terminal routing. It uses a scripted engine for dictation. It snapshots and restores the three preferences changed by fake-engine launch flags, including on failure. Its output directory preserves command IDs, native accessibility trees, actual app logs and completion records. Mac overlay verification is `scripts/device/tests/mac-overlay-smoke.sh`; it is a native-app check, separate from fixtures.

The pre-fix installed simulator reproduced both the held-toggle FIFO deadlock and a queued card failing to emit `shown`/start its timer. Fresh-build verification and physical/Mac proof must be reported separately: simulator model availability does not establish on-phone performance, and a fake microphone does not establish real ASR. No maintained paid-provider test or model download is implied.

On 2026-10-30, the fresh simulator drive passed held-toggle/cancellation, native AX queued presentation/reply, hit testing and clear. Its Foundation Models measurements ran, but the final probe outcome was `restorationFailed`; the CLI correctly propagated nonzero status for both command ID and historical probe UUID. This is a simulator restoration gap, not a successful restoration claim. Existing scenarios `a`, `m`, `n2` and `n3` subsequently passed all 53 assertions using Xcode's ad-hoc simulator signing and real App Group storage. Manual re-signing of an unsigned build did not establish that storage fixture and produced two history failures; those failed observations were retained separately.

The final isolated iPhone drive on 2026-10-30 passed Foundation Models foreground, background and background-audio probes, followed by a real microphone start/release after each. Both background modes reported actual background app state. Sending an ordinary keyboard-arm request during the audio probe did not replace its owned microphone: diagnostics recorded one acquisition, teardown before restoration, the expected teardown input-loss event rejected for cancellation, and terminal `ok`. No Core ML weights were installed in the isolated phone app, so this establishes phone Foundation Models and microphone lifecycle behavior.

The final physical cold launch completed its fresh-generation handshake in 7.66 seconds. Ping send→wait completed in 3.83 seconds; the host observed its matching `done` 1.74 seconds after the device timestamp. The historical #94 cause remains unconfirmed; fixtures prove bounded transfers, preserved snapshots and readiness ordering independently of this device result.

Native Mac verification passed Foundation Models and installed Core ML measurements, model restoration and subsequent normal dictation. The retained Core ML second turn prefilled 64 tokens versus 905 for its fresh comparison, with equal replies. Live typed settings, busy hotkey/meeting admission during a probe, native ask reply and queued timeout, status focus, app-window blocking and clear were driven in the app. LaunchServices launch survived the CLI tool ending, and a later invocation received pong. All 11 common commands were present on phone, simulator and Mac. The original installed Mac bundle was restored afterward, with its signature and original executable hash verified; the original phone app was untouched.

Native validation used the available Xcode 27.2; the pinned Xcode 26.6 was unavailable locally. Toolchain pins were preserved. Full package suites remain the protected merge queue's gate; a green PR report alone does not establish that gate.

Ordinary iOS and Mac Release builds passed the internal endpoint/overlay/probe-adapter exclusion scan with valid source controls (three iOS Mach-O files, one Mac executable). The existing iOS fake/e2e exclusion gate also passed. Repeat these checks with `bash scripts/ci/release.sh check` and `bash scripts/ci/release.sh mac-release`; `mac-build` retains its separate Debug compilation role. The scanner fixture suite rejects leaked embedded endpoints, stale controls and empty/resource-only bundles.
