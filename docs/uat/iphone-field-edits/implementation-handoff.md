# Validation handoff

Draft [PR #298](https://github.com/Jakob-Grunwald-AI-ML-Engineering/legato/pull/298), branch `feat/iphone-field-edits`, worktree `/Users/work/Documents/legato-wt/iphone-field-edits`, base `1007a83`. Product source is frozen at `7838631`; subsequent changes are operator documentation, evidence and the stress checker. [Current validation status](validation-status.json) owns the result summary. Do not merge while fresh acceptance is blocked.

The user chose to finish current validation and stop further repair cycles: any new failure or access blocker is a recorded handoff for a fresh session. A new product fix requires fresh diagnosis and alignment rather than another automatic patch iteration.

## Verified work

The full local `scripts/ci/test.sh` passed on `7838631` with Xcode 27.2 (27B52), including package tests and both unsigned apps. Ordinary iOS/Mac Release builds passed internal-tool exclusion. Current tracked Apps, Sources and Swift Tests trees are identical to that tested revision; the later Python checker has nine passing pure contracts. Full logs and hashes are retained outside temporary/cache storage under `~/Library/Application Support/LegatoTestVM/artifacts/final-validation`.

The [physical report](README.md) records five host baselines, native Select All/Paste safety, the pending-cleanup self-send/new-draft race and persisted speech recovery, Unicode raw movement, native list continuation and the fixed quiet-tail response. The longest of six observed cursor confirmations was 455.377 ms; the speech suffix confirmed in 158.123 ms. These are directed samples, not independent acceptance, microphone quality or a universal latency guarantee.

Both original speed-1 stress seeds passed: 40/40 takes, zero invariant/tool/contended failures, and all 20 untouched cases exactly clean. All 40 results were independently checked against their retained journals and archived durably. Per-seed results, checker/binary fingerprints and artifact directories are recorded in `validation-status.json`. This is the in-app simulator harness, not real-extension UAT.

## Acceptance blockers

- Physical iPhone: the fresh tester's existing WDA LAN endpoint timed out after 40 seconds, although device discovery reported a paired phone. The tester performed zero mutations. Do not equate paired discovery with a reachable native-control session. Exact access and prior runner details remain in the private operator handoff; rediscover them before another authorized test.
- Mac guest: the separate test copy launches, AX is trusted and offline mode is active, but the actual observer reports `hotkeysEnabled=false`. Native input acceptance did not begin. The user stop condition ended permission repair at this point.

The [VM guide](../../../scripts/device/mac-vm.md) describes durable controls, pinned image/tool and guest-only setup. The VM is stopped and retained at `~/Library/Application Support/LegatoTestVM`. Read `artifacts/mac-uat-access.md`, `guest-readiness.json`, `guest-signature-changes.json` and `vm-final-state.json` there before resuming. The original development profile rejected the VM's device identity; this was a confirmed provisioning limitation. A separate ad-hoc guest copy removes restricted identifiers/profile and permits its debug library. It is behavioral test infrastructure, not proof that the original development-signed app launches in a new guest. SIP/AMFI and host privacy settings were preserved.

## Counterexamples and refuted leads

- The original untouched cleanup failures were real ordering problems. Exact successful raw-delivery receipts order both cleanup reads; a statistics-only acknowledgement is not delivery. The shared playback budget is a background wait, never a user-input hold.
- The speech-tail stall of 19.6 seconds was real: quiet audio admitted old cleanup before the last heard letters. `7838631` prioritizes actual pending raw appends while keeping revisions in the pause lane. Preserve confirmed-operation and return-to-user-caret barriers.
- Stress take08's `jA`→`Ja` report was a checker false positive. Both changed letters temporarily disappear inside one legitimate hunk, then return at their original slots. Checker `8a28a0e` tracks that transient mapping; wrong-slot, lost and unchanged-marker corruption still fail. Do not change the product to satisfy the retired blanket no-edits-after-input policy.
- Cleanup duration, bridge/VNC transport and total word throughput are distinct from added input interruption. The 500 ms target and 1 second failure boundary remain unchanged.

## Source owners

`FieldQueue` and `FieldEditCoordinator` own conditional revisions, raw priority, user-input preservation and operation barriers. `FieldReader` owns verified reads/cancellation; the iPhone controller owns native callback provenance, draft epochs and adaptation. `FieldCleanupSession`/`InstructionLink` own draft lifetime and History outcomes. `DictationActivity` owns pause admission. Mac field/caret and native-input adapters build on the shared policy; no second writer or blind recovery probe should be introduced.

The internal primitive explorer is maintained in [keyboard-probe.md](../../../scripts/device/keyboard-probe.md). It deliberately exposes unknown raw proxy state and permits one chosen action/read at a time. A scripted walk is not agent UAT.

## Device state and remaining fixture cleanup

Phone source `7838631` remains installed. Last owned handback verified idle/unarmed/no probe or replay and Home at 11:06:45.012 UTC. No known fake/harness/fixture launch or provider override remains. The user later resumed phone testing; the fresh tester's read-only access attempt made no device changes. Host Mac foreground work remains paused and its installed app/windows were preserved.

Private phone access is `/Users/work/Library/Caches/legato/iphone-field-edits/physical-uat-access.md`, with exact owned draft cleanup notes beside it. Preserve the older replay tab's later native `l` of unknown origin. Own WhatsApp/Messages/Notes/Mail fixtures remain; remove only exact unchanged owned content after access is restored. The original clipboard could not be preserved and was replaced with the explicitly approved synthetic fixture; it was not restored. Never overwrite a newer user copy. These cleanup gaps do not authorize another connection-repair loop now.

Every future block ends with take/probe cancellation, microphone/provider release, verified idle/unarmed state and visible Home; reopen visibly before resuming. On Mac, close only test-owned surfaces. The reusable VM and private evidence are retained; no live promotion occurred.

## Host audio incident and final cleanup

The user reported choppy normal Mac dictation during testing. The VM had audio disabled and was already stopped; the current stress simulator was also shut down. Read-only checks found the built-in microphone still selected at 48 kHz and no recent Core Audio overload messages, but the older `legato-e2e` simulator remained booted. With explicit approval, only that older simulator was shut down, preserving its data and the running normal Legato process. The user immediately confirmed improvement. Simulator interference is likely; its exact audio/resource mechanism was not measured.

All iOS simulators and the VM are now stopped. No usual-app restart, microphone route change or host audio-setting change occurred. No host process held the owned seventh WDA runner log and no test server listened on the owned fixture port at closeout; future access must bootstrap and verify actual current services rather than reuse stale endpoints. Another approximately 3.4 GiB of stale capture data was identified by dry-run housekeeping and left untouched.
