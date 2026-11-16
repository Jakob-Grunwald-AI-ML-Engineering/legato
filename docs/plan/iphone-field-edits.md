# iPhone field editing and pause corrections

## Goal and scope

Implement #294 verified iPhone edits around typing, #260 Safari field reads, #278 stale paste/hardware context detection, and remaining #293 pause correction and resumption evidence. Start at main `1007a83`; preserve the streaming spike checkout. One worktree, one PR to main, queue-only squash merge; no live promotion.

## Decisions and constraints

Measure physical Messages, WhatsApp, Mail, Safari and Notes before changing edit behavior. Use synthetic text and recorded speech; the user need not speak. Phone and microphone control plus test-sized real Soniox/API requests are authorized for this session. Messages may be sent only to the user's own verified account. Exercise send clearing the field while cleanup is pending, followed by a new draft: a late result must neither repopulate the cleared draft nor edit its successor. Preserve the original speech in History. Keep raw personal captures private. Hardware keyboard evidence requires actual available hardware and remains separate from paste or WDA input.

## Responsiveness acceptance

Manual typing, cursor movement and resumed speech target less than 500 ms of observed interruption during cleanup. Any observed block longer than 1,000 ms is an acceptance failure. Report the longest observed delay and sampling resolution, not just averages; total cleanup duration is a separate metric. Explicit operator-chosen probe delays are exempt. Existing 8-second key-hold policy is not accepted as evidence; measure actual human-rate input and change the shared admission/preemption owner when it breaches this constraint.

## Owners and measurements

`FieldQueue` owns writes and cursor operations; `FieldEditCoordinator.Operations` owns their barrier. Reuse `SpanPlanner`, `ShadowEditPlanner`, `FieldMerge`, `FieldRecovery`, `FieldReader`, `EditHistory`, `FieldInsertion` and `SpeechDelivery`. `FieldCleanupSession` owns cleanup against `InstructionField`; `DictationActivity` owns acoustic/semantic admission. Expand existing owners, not parallel per-platform policies. The iPhone bounded proxy and Mac absolute ranges remain distinct adapters.

Record jump confirmation success, issued operation to independent readback latency and edit/return unit time, with host, method and confidence. Include emoji, paragraph boundaries, paste and list continuation. Confirm draft identity beyond reusable document IDs when fields clear. Existing 200 ms / -55 dBFS pause calibration is from one speaker's recordings, not broad validation. Measure resumption responsiveness without claiming a worst-case bound from sparse samples.

## Implementation tasks

1. Build/install current signed baseline, capture physical host measurements and identify reliable capabilities. Debug instrumentation may precede measurements; behavior changes follow them.
2. Extend the shared document reader/recovery for measured Safari and stale-context failures. Preserve hidden Select All before a destructive move; unknown text remains unknown.
3. Replace permanent take freeze with conditional minimal edits through the existing lane. Preserve intervening user changes. Unverified jumps may use a verified stop-time block fallback, otherwise keep as typed with recovery notice. Preserve all unchanged characters.
4. Connect iPhone pause admission to shared activity/scheduling after verified edits work. Speech resumes ahead of further cleanup; any in-flight operation must settle safely.
5. Guard cleared/replaced drafts against late cleanup and keep accurate History outcomes.

## Checks and environment

Run focused core-contract checks, two clean seeds of `scripts/e2e/keyboard-stress.sh`, and the final candidate's full local `scripts/ci/test.sh` including both app builds. Record exact revision and Xcode (local 27.2; pin 26.6 absent). Physical extension behavior, simulator stress, scripted integration probes and real-provider evidence are separate claims.

## What to tell the UAT agent

Dictation now continues correcting around manual typing on the iPhone, including during natural pauses; Magic reads common web editors more reliably. Explore the built real keyboard in available host apps with mixed input, and sending to the verified own account. The phone is authorized for control and short real-provider tests, with no user speech required. Preserve private data and preferences; return observed behavior, friction and evidence. No messaging anyone else or live promotion. Fresh UAT is conducted by the parent after implementation, then fixes, PR and merge.
