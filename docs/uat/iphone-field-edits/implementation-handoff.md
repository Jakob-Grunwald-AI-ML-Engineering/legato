# Implementation handoff

Branch: `feat/iphone-field-edits` in `/Users/work/Documents/legato-wt/iphone-field-edits`. Main base: `1007a83`. Latest iPhone source fix: `486d492`; subsequent iPhone commits contain evidence only. Parent owns the stress-validator port, final integrated checks, fresh UAT, PR and landing. No PR, merge or live promotion was performed by this implementer.

## Source and owners

- `FieldQueue` / `FieldEditCoordinator` own conditional minimal revisions, live-speech priority, user-input preservation and the shared 500 ms response target. Existing `SpanPlanner`, `FieldMerge`, `EditHistory` and Operations barriers remain the editing owners.
- `FieldReader` owns verified boundary reads and cancellation; the iPhone controller owns native callback provenance, draft epochs, read-lease acquisition and field adaptation. Unknown selection/context refuses before a production nudge.
- `FieldCleanupSession` and `InstructionLink` carry the optional draft epoch, reject cleared/replaced successors, rebase genuine intervening changes, and preserve original speech in History.
- `DictationActivity` remains the pause owner. `DictationStatusLink`, `KeyboardLinkHost` and the controller carry its run-scoped activity to the existing queue.
- Internal `FieldProbeLink` / `KeyboardProbe` provide primitive interactive reads and native deltas under an explicit lease. The maintained operator guide is `scripts/device/keyboard-probe.md`.
- Debug replay optionally accepts matching PCM through the actual activity owner on one original monotonic timeline. Token-only behavior is retained. No new provider endpoint or classifier was added.

## Built and installed state

Physical iPhone: iPhone 17, iOS 26.6.1 (23G83), UDID `00008150-000E60360245401C`. Installed app/extension: signed `d94be68`, identity `de.gruenwald.legato`, App Group `group.de.gruenwald.legato`, existing data preserved. App version is 0.1 (1).

Latest signed generic-device build includes `486d492` and its ancestors, including the coordinated Mac caret policy `cefb6d3`. Xcode 27.2 was used because pinned 26.6 is unavailable. Build passed at `/private/tmp/legato-iphone-cleanup-readiness-generic-build.log`. The physical-destination build failed only because the device was unavailable; the generic build has not been installed. Cached product: `/Users/work/Library/Caches/legato/derived/ios-device/Build/Products/Debug-iphoneos/Legato.app`.

| Cached signed binary | SHA256 |
| --- | --- |
| Legato | `541459382bc27c58dbc110fed3da5b157c4cd59a623332b9e318ed628fd2db3e` |
| Legato.debug.dylib | `fdc1bd557bd5c74726ff6ef86c4442d38fa16f0f69abd15e73e4e552999b1325` |
| LegatoKeyboard | `3fd590d065a400e8042549f8fa3b9172156e31730c9b6b919fdf168a1f97cffa` |

The full local gate passed on earlier `d94be68` at `/private/tmp/legato-iphone-field-final-gate-2.log`. Final source changes require the parent’s final check. Ordinary iOS Release exclusion passed on earlier `b6e77c0`; final PCM/History/controller changes need the parent’s ordinary Release recheck. Source/scanner-fixture checks alone are not a Release binary claim.

The original untouched simulator take 05 now passes on `486d492`, with its original validator and fixture, replay speed 1, exact expected title casing and zero loss/resync. Raw final acknowledgement precedes confirmed cleanup. See `cleanup-readiness-regression.json`. This is one focused regression, separate from two required full seeds or fresh UAT.

## Physical results and remaining work

The five host baselines, corrected native Select All preservation, native Paste and the actual pending-cleanup self-send/new-draft/History recovery are recorded in `README.md` with synthetic-only traces and limits. Raw physical observations do not establish universal host reliability or hardware-keyboard behavior.

Still required: install the latest candidate when the user confirms phone readiness; physical matching-PCM replay and pause-time corrections; longest added delay for manual typing, space-pan cursor movement and resumed speech during cleanup/read/recovery; emoji and automatic list continuation; two clean speed-1 stress seeds; and fresh integrated UAT. Target less than 500 ms; any observed interruption over 1 second fails. Do not substitute cleanup duration, provider latency, debug transfer time or deliberate probe delay for input interruption.

The user has authorized physical testing, microphone arming, short serial provider calls and sending only to verified self. The official WhatsApp Message yourself system label and (You) badge must still be checked before another send. No further phone attempts are authorized operationally until the pending readiness answer; the parent owns that question.

## Ready matching replay

The additional real Soniox request finished and closed: 28.0389375 seconds of synthetic PCM, 148 responses. No physical microphone or user speech was used. This is transport evidence; physical replay is still pending.

- Committed timeline: `docs/uat/iphone-field-edits/live-soniox-human-rate.json`.
- Matching private PCM: `/Users/work/Library/Caches/legato/iphone-field-edits/soniox/pcm/long-synthetic.pcm`.
- Source text, exact timing and PCM hash: `live-soniox-human-rate-summary.json`.
- First speech is 22.0319375 seconds; chosen silence is 2 seconds; resumption begins at 24.0319375 seconds and lasts 3.007 seconds, followed by 1 second of silence. TTS requested 180 words/minute; replay speed must be 1.
- Existing command after both files are put into the bridge directory: `dictation-debug-replay timeline.json 1 take.pcm`. Configure a bounded deterministic default capitalization cleaner for the functional edit/input measurement; real Claude instruction calls and real Soniox transport have separate evidence.
- Empty synthetic Safari surface prepared at the local server’s `/replay.html`, label `Replay human rate`. Server root is `/Users/work/Library/Caches/legato/iphone-field-edits/web`, port 8769. Recheck the Mac’s local address when reconnecting.

## Phone and tool handback

The last microphone release completed at 09:24:58.616 UTC: armed/warmInput/reserved false, route idle. Home action succeeded; transfer confirmation was recovered afterward. No later UI controls were attempted after the parent requested a readiness answer. CoreDevice reported no assertable trusted-connectivity state; locked versus off-network is unknown. Do not repeat connection attempts until readiness.

The last tunnel was `fdfb:d102:c5a3::1`; rediscover it rather than trusting this stale address. The owned fourth WDA runner exited destination-unavailable. Shared Appium PID 806 on port 4723 was preserved. Private WDA helper/cache: `/Users/work/Library/Caches/legato/iphone-field-edits/`; no mixed journal or private screenshot belongs in Git.

Own test data remains: WhatsApp unsent draft `New epoch safe 2785`, Messages unsent `Legato probe: Alpha beta gamma delta epsilon zeta.` in the My Card mobile conversation, own Notes note `Legato probe`, and one new Mail draft with synthetic body and no recipient. Verify each still contains only the fixture before removing it. Preserve pre-existing drafts and any user additions. Close only owned Safari test surfaces.

The user explicitly allowed replacing the unreadable clipboard with `Legato paste test: blue notebook.`; original contents were not restored. At final cleanup, remove the fixture only after a private exact comparison proves it is still ours. Never print clipboard contents or overwrite a newer user copy.

Every future pause/build/analysis handback must end any probe, stop/join replay or take, release and verify the microphone, then show Home. Visibly reopen the test surface before taking control again. Keep user preferences and the expanded keyboard state intact.
