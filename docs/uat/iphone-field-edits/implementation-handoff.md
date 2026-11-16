# Implementation handoff

Branch: `feat/iphone-field-edits` in `/Users/work/Documents/legato-wt/iphone-field-edits`. Main base: `1007a83`. Current installed candidate: `7838631`; directed physical tail/key/cursor checks and native list continuation pass. Full stress and fresh UAT remain with the parent. Parent owns the stress-validator port, final integrated checks, fresh UAT, PR and landing. No PR, merge or live promotion was performed by this implementer.

## Source and owners

- `FieldQueue` / `FieldEditCoordinator` own conditional minimal revisions, live-speech priority, user-input preservation and the shared 500 ms response target. Existing `SpanPlanner`, `FieldMerge`, `EditHistory` and Operations barriers remain the editing owners.
- `FieldReader` owns verified boundary reads and cancellation; the iPhone controller owns native callback provenance, draft epochs, read-lease acquisition and field adaptation. Unknown selection/context refuses before a production nudge.
- `FieldCleanupSession` and `InstructionLink` carry the optional draft epoch, reject cleared/replaced successors, rebase genuine intervening changes, and preserve original speech in History.
- `DictationActivity` remains the pause owner. `DictationStatusLink`, `KeyboardLinkHost` and the controller carry its run-scoped activity to the existing queue.
- Internal `FieldProbeLink` / `KeyboardProbe` provide primitive interactive reads and native deltas under an explicit lease. The maintained operator guide is `scripts/device/keyboard-probe.md`.
- Debug replay optionally accepts matching PCM through the actual activity owner on one original monotonic timeline. Token-only behavior is retained. No new provider endpoint or classifier was added.

## Built and installed state

Physical iPhone: iPhone 17, iOS 26.6.1 (23G83). Installed app/extension: signed `7838631`, identity `de.gruenwald.legato`, App Group `group.de.gruenwald.legato`, existing data preserved. App version is 0.1 (1).

The installed signed build includes `7838631` (confirmed-empty admission, exact successful delivery receipts and shared background delivery budget) and the earlier controller/readiness and Mac caret fixes. Xcode 27.2 was used because pinned 26.6 is unavailable. The signed physical-device build passed. The parent owns final candidate hashes and gate/UAT state.

Earlier full-gate evidence on `d94be68` and ordinary iOS Release evidence on `b6e77c0` are historical checkpoints. The parent maintains the final candidate’s current gate, Release, full-stress and UAT results. Source/scanner-fixture checks alone are not a Release binary claim.

The original untouched simulator take 05 now passes on `486d492`, with its original validator and fixture, replay speed 1, exact expected title casing and zero loss/resync. Raw final acknowledgement precedes confirmed cleanup. See `cleanup-readiness-regression.json`. This is one focused regression, separate from two required full seeds or fresh UAT.

## Physical results and remaining work

The five host baselines, corrected native Select All preservation, native Paste and the actual pending-cleanup self-send/new-draft/History recovery are recorded in `README.md` with synthetic-only traces and limits. Raw physical observations do not establish universal host reliability or hardware-keyboard behavior.

Physical matching-PCM replay, pause correction and the quiet-tail fix are confirmed. The final period confirmed in 158.123 ms, Space in 95.613 ms, q in 178.716 ms, and the longest of six cursor responses in 455.377 ms. Unicode raw movement and native list continuation are measured. Still required: both full original stress seeds, fresh integrated UAT, and final cleanup of unchanged owned fixtures; the parent owns current gate/acceptance state. Target less than 500 ms; any observed interruption over 1 second fails. Do not substitute cleanup duration, provider latency, debug transfer time or deliberate probe delay for input interruption.

The user has authorized physical testing, microphone arming, short serial provider calls and sending only to verified self. The official WhatsApp Message yourself system label and (You) badge must still be checked before another send. The user subsequently paused phone testing after the verified handback. Do not resume phone foreground, bridge, install, retry or input actions without explicit resumption. Mac foreground work remains paused.

## Ready matching replay

The additional real Soniox request finished and closed: 28.0389375 seconds of synthetic PCM, 148 responses. No physical microphone or user speech was used. Physical replay also confirmed natural empty-field insertion and pause cleanup, and the later quiet-tail fix is physically rechecked; its earlier failure remains preserved in the report.

- Committed timeline: `docs/uat/iphone-field-edits/live-soniox-human-rate.json`.
- Matching PCM is kept in the private operator cache; its exact location is in the private access handoff.
- Source text, exact timing and PCM hash: `live-soniox-human-rate-summary.json`.
- First speech is 22.0319375 seconds; chosen silence is 2 seconds; resumption begins at 24.0319375 seconds and lasts 3.007 seconds, followed by 1 second of silence. TTS requested 180 words/minute; replay speed must be 1.
- Existing command after both files are put into the bridge directory: `dictation-debug-replay timeline.json 1 take.pcm`. Configure a bounded deterministic default capitalization cleaner for the functional edit/input measurement; real Claude instruction calls and real Soniox transport have separate evidence.
- Empty synthetic Safari surface prepared at the local server’s `/replay.html`, label `Replay human rate`. Server root is `/Users/work/Library/Caches/legato/iphone-field-edits/web`, port 8769. Recheck the Mac’s local address when reconnecting.

## Phone and tool handback

Connectivity is restored. The latest release completed at 11:06:45.012 UTC: armed/warmInput/reserved false, route idle; Home was then independently confirmed. The phone is visibly free during verification and documentation. Current connection/session/discovery details are in the private operator handoff, not this tracked document. Shared Appium and other projects’ processes were preserved.

Own test data remains: WhatsApp unsent draft `New epoch safe 2785`, Messages unsent `Legato probe: Alpha beta gamma delta epsilon zeta.` in the My Card mobile conversation, own Notes note `Legato probe`, and one new Mail draft with synthetic body and no recipient. Verify each still contains only the fixture before removing it. Preserve pre-existing drafts and any user additions. Close only owned Safari test surfaces.

The user explicitly allowed replacing the unreadable clipboard with `Legato paste test: blue notebook.`; original contents were not restored. At final cleanup, remove the fixture only after a private exact comparison proves it is still ours. Never print clipboard contents or overwrite a newer user copy.

Every future pause/build/analysis handback must end any probe, stop/join replay or take, release and verify the microphone, then show Home. Visibly reopen the test surface before taking control again. Keep user preferences and the expanded keyboard state intact.

The settled replay fixture now also contains a later native l addition whose actor is unknown. Preserve it; do not treat that addition as disposable owned input. Production reader/recovery interruption and Unicode Magic acceptance are not established by the cleanup timing/raw traversal samples alone.
