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
