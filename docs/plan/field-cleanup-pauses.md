# Field cleanup and Mac pause corrections

## Scope

Implement #292 on both platforms, followed by the Mac portion of #293. iPhone pause-time jump edits remain dependent on #294. Work starts from `6459943`, after #291 established shared field and dictation owners. The streaming-dictation spike is a separate checkout and is preserved.

## Owners and behavior

Cleanup reads the current field through the same conditional read/edit contract as Magic. One shared cleanup coordinator owns chunk coverage, response generation, conflict handling and confirmed outcomes. The keyboard supplies iPhone reads from its confirmed document; Mac supplies its field document. Results may tidy typed and dictated text but do not change meaning. Changes made after a read win over a pending result. Raw speech remains recoverable in History, whose cleanup outcome reflects field confirmation rather than provider success.

Use larger overlapping chunks and retain a final whole-take pass. The candidate window is 60 words with 12 words of overlap; coverage and request-count comparisons are recorded in [measurements](field-cleanup-measurements.md). Semantic overlap adequacy remains unverified. Buffered On stop and After a pause modes must include pending speech and current field context.

The shared speech route distinguishes take lifetime from current activity. Mac releases held revisions and cleanup during eligible pauses through its existing queue and span planner. Resumed speech takes priority behind only the edit unit already underway. Endpoint signals alone are insufficient: the recorded corpus contains endpoints delivered after resumed speech. A conservative endpoint plus acoustic-quiet candidate is calibrated in the measurement document; it is not a general VAD guarantee.

## Delivery order

1. Measure existing recordings without provider requests or publishing private text.
2. Implement shared field cleanup and both platform adapters, preserving Magic ownership and user edits.
3. Add shared activity state and Mac pause scheduling; keep iPhone application at stop.
4. Run focused contract checks and the repository's full local `scripts/ci/test.sh` on the completed candidate, including both unsigned app builds.
5. Run fresh-agent runtime acceptance, fix findings and recheck affected behavior; open one PR to main. Queue-only squash merge requires required checks and acceptance evidence. No live promotion is included.

## Runtime acceptance brief

Dictation cleanup now considers the actual text field, including typing mixed with speech. On Mac, corrections can appear during natural pauses while a take remains open. Speech and manual input should remain responsive, and History should accurately describe what reached the field. Explore the built app with offline synthetic speech and cleanup controls, preserving the installed app, existing processes and preferences. Return observed behavior, friction, reproduction steps and evidence. Synthetic controls and simulator evidence do not establish microphone, provider or physical-phone behavior.

## Boundaries

No paid provider calls, deployment, promotion, global permission changes or destructive cleanup are authorized by this bundle. Preserve the installed Mac application's original identity and existing running processes; use isolated data and bridge roots for test copies. Do not stop other sessions' simulators. Missing runtime access or measurement evidence is reported as untested, never passed.
