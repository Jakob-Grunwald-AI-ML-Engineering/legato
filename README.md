# Legato

Open-source, on-device dictation and meeting notes for iOS and macOS.

- Streaming transcription, fully offline (Apple SpeechTranscriber, FluidAudio: Parakeet / Nemotron)
- Mixed German/English in one utterance
- Background audio keeps playing while you dictate
- iOS: Action Button / Control Center trigger, custom keyboard without the app hop
- macOS: menu-bar app, global hotkey, meeting notes from system audio + mic
- Summaries: Apple Foundation Models, local MLX, or Claude (opt-in)

Licensed under Apache-2.0.

## Build caches

`scripts/e2e/ios-sim.sh` keeps its builds under `~/Library/Caches/legato` (`LEGATO_CACHE_DIR`): SwiftPM clones shared by every worktree, DerivedData reused per worktree, and sweeps stale `legato-e2e.*` temp dirs of killed runs. `scripts/dev/prune-build-caches.sh` lists (dry run) or, with `--delete`, removes DerivedData and caches of deleted worktrees.

## Device debugging

`scripts/device/ctl.sh` drives a Debug build on a physical iPhone without taps (run it without arguments for the usage). A bridge in the app (`Apps/iOS/App/Debug/DebugBridge.swift`, `LEGATO_INTERNAL` builds; Debug starts it at launch, TestFlight-internal builds with `-LegatoDebugBridge YES`) polls `Library/Caches/debug-bridge/inbox/` every 0.5 s while the process lives, runs each `{id, command, args}` file on the main actor and appends `{ts, id, event, ...}` lines to `Library/Caches/debug-bridge/log.jsonl`.

```sh
scripts/device/ctl.sh build && scripts/device/ctl.sh install
scripts/device/ctl.sh launch -LegatoFakeEngine "hello world"   # the e2e launch flags work unchanged
id=$(scripts/device/ctl.sh send state) && scripts/device/ctl.sh wait "$id"
scripts/device/ctl.sh background; scripts/device/ctl.sh send toggle
```

Commands: `ping`, `commands`, `state`, `set-setting <key> <value>`, and in Debug builds every simulator e2e command (`E2E.commands`), routed through the same `runE2E`. Other code adds commands with `DebugBridge.register(_:handler:)`. Limits: the phone must be unlocked for launch and file copies; the real keyboard extension and locking the phone cannot be driven.
