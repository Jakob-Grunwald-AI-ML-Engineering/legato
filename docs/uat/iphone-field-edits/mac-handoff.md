# Mac input during pause cleanup

Native cleanup now reserves a short keyboard handoff while its queue borrows the host selection. A real key arriving inside that unit reaches the confirmed user caret after the unit returns home. Ordinary keys in idle apps and other processes pass through. Clicks pass immediately and keep their observed caret. No field writer or global keyboard filter was added.

## Measured result

On the existing signed #297 fixture, a Left key during TextEdit cleanup did not reach the expected caret until 1,204 ms; the queue journal kept restoring its stale return position. A simple input-generation guard did not solve the underlying race: a real `z` could replace a selected `w` inside the cleanup passage. That intermediate build failed acceptance and was replaced.

The process-scoped handoff then preserved the complete synthetic baseline, apart from intended capitalization, and placed `z` at the original end in both measured hosts. Cursor timing requires the exact one-character-left range, rather than any transient cleanup caret movement.

| Signed fixture | Host | Typed character observed at original end | Exact Left result observed | Actual captured/replayed events |
| --- | --- | ---: | ---: | ---: |
| Initial handoff | TextEdit | 80 ms | 75 ms | 2 / 2 |
| Initial handoff | Safari textarea | 56 ms | 54 ms | cumulative 4 / 4 |
| Final source | TextEdit | 86 ms | 74 ms | 2 / 2 |

Timings include System Events dispatch and AX observation. Dispatch itself took 3.8 ms for typing and 7.3 ms for Left in the final run. All completed probes reported zero held events and zero handoff failures. The final reported native unit was 37.3 ms. These observations meet the requested 500 ms target; they are not a general worst-case bound.

Earlier resumed-speech probes included the debug inbox's 500 ms poll. The retained same-process monotonic journal gives tighter production-admission evidence: a resumed snapshot reached its first verified character in 16.3 ms in TextEdit, 28.3 ms in Safari textarea and 22.7 ms in Safari div contenteditable. The complete first marker verified in 187.1, 205.6 and 172.4 ms respectively. These exclude ASR/network delay and do not validate physical speech onset. The [journal subset](mac-monotonic-resumption.json) retains the correlated synthetic entries.

## Ownership and limits

The existing `MacFieldQueue` admits one native unit, restores and verifies its user caret, then releases the original keyboard events in order. The adapter uses an active tap scoped to the host process; the existing global hotkey listener remains passive. Original down/up/repeat/modifier events are retained, and their original event metadata is restored before delivery. Legato's synthetic events bypass the handoff. This follows Apple's [active-filter callback contract](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback) and [process-directed event posting](https://developer.apple.com/documentation/coregraphics/cgevent).

The 500 ms unit budget comes from the user responsiveness requirement. Half is reserved for native work and half for returning home; AX request timeouts are capped by the remaining phase budget. Unavailable admission starts no selection or write. An unconfirmed home retains only already-held events and disables further unsafe native edits. Failed/blocked and idle states never capture new input, including keys in another or password field in the same host process. Idle tap disable also never starts capture. The notice offers explicit recovery: click the original nonsecure field. The adapter verifies the original field token, a fresh click within that field's frame, continued focus and two matching caret reads before releasing held-but-never-posted events there. Native editing remains disabled for the current target. Previously posted but unacknowledged events are uncertain and are never posted again; late acknowledgements cannot restart a failed replay. Such a failure remains a responsiveness failure, even though the event objects are retained. Hung-host recovery, permission loss during a unit, failed homing, sustained shortcut/repeat streams and clicking while keys are held were not runtime-validated here. They must not be reported as passed or as a universal bounded guarantee.

## Provenance and checks

The initial baseline artifact was the previously accepted `/private/tmp/legato-field-cleanup-uat/Legato.app`; its accepted revision `9080e7854dca7b1b15794cdbd8c78741fc5ee1e2` has an identical tree to merged main `1007a83235dc705679449f528d4ab188dea72761`. Its debug dylib SHA-256 was `3d42206977283da0ee3f19a9ac0c1419ba0241aeb6585d4336942447f86ab56f`. It was copied, not rebuilt for the baseline probes.

The fixed apps were built from this bundle's working tree using `scripts/ci/release.sh mac-build`, then signed as isolated copies using the installed application's existing development identity and provisioning profile. The [manifest](mac-handoff-stats.json) records the source base, exact Mac source hashes, both fixed dylib hashes, environment and minimal handoff statistics. The final TextEdit probe used the final Mac source, including the admission-race guard and failure notice. Other bundle work was concurrent; the parent owns final integrated validation.

Four additional focused failure-policy tests passed (five cases), covering empty/nonempty failed homing, idle disable, interrupted replay and explicit verified recovery. These exercise the exact lease policy used by the callback; failure/recovery UI was not foreground-tested after the user requested the Mac be free. The prior normal-path runtime evidence predates this failure-policy correction and must not be presented as runtime acceptance of the correction.

Three focused core contracts passed: an observed user caret wins over native restoration, a deferred key lands at the confirmed user caret, and unavailable handoff admission performs no move or write. The final Mac build and strict signature verification passed. Existing warnings remain. The parent still runs the full repository gate and fresh agent UAT on the integrated final revision.

This is offline synthetic runtime measurement, not independent UAT, microphone/provider validation, global-hotkey acceptance, physical iPhone evidence or live promotion. No settings, permissions or installed app processes were changed. Only the measurement's own fixture process was restarted. At handoff it was cancelled to idle and exited; its ten synthetic TextEdit documents and two local Safari test tabs were closed, preserving pre-existing windows. All committed text fixtures are synthetic; raw account state and personal content are excluded.
