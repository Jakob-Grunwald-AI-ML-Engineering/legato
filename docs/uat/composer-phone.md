# Physical iPhone Composer UAT

Status: blocked on a reproducible Claude streaming failure. Partial transcript handling passed. Native Composer UI and keyboard delivery remain unverified.

Tested 2026-10-30 on physical iPhone 17, device `00008150-000E60360245401C`, bundle `de.gruenwald.legato`. The signed Debug app used injected Soniox-shaped transcripts and its real Claude transport/keychain configuration. No Soniox socket or audio input was used; `microphoneLeaseActive` was false. This establishes foreground host behavior only. The control script was switched to this worktree's committed `b4d69a0` copy after a transient parsing error from an actively edited sibling script.

## Observed sessions

| Session | Mode | Result | Evidence |
| --- | --- | --- | --- |
| `94E85C10-2F21-401D-AC2E-5AD21E723013` | Message | Partial-only pass; final and rewrite returned `incomplete` | [Room log](artifacts/phone/message-room.jsonl) |
| `1A696D20-6B5D-494D-8FEC-A3E1B7A05F77` | Email | Interrupted by overlapping setup install/launch; no provider verdict | [Room log](artifacts/phone/email-interrupted-room.jsonl) |
| `7BC04367-4B37-48EB-8FA6-070B273FC84F` | Message, clean retry after exclusive handoff | Failed: `incomplete`, document unchanged | [Room log](artifacts/phone/message-clean-room.jsonl) |

Prompt was deferred after the clean failure reproduced, to avoid repeating paid requests against the same transport defect. Email and Prompt acceptance remain open.

## Partial-only acceptance

In the first Message session, `composer-debug-text 'Alex ich komme zehn Minuten später' partial 0` returned an empty document at revision 0, `busy:false`, and a speculative tail containing that phrase. The immediately pulled room log contained only `input.source`, `asr.started`, the injected frame and `asr.tail`: no `asr.segment`, document operation or Claude request.

## Clean paid-provider failure

After setup explicitly released the phone at 17:37:31 UTC, a fresh session started with an empty document. The only final utterance was:

> Schreib Alex: Ich komme zehn Minuten später, fangt bitte ohne mich an.

The expected semantic result was a short personal message preserving Alex, ten minutes late and starting without the sender, with the instruction excluded from the message. Instead the document remained exactly the raw sentence including “Schreib Alex”.

Reproduction, with sequential command-ID waits:

```bash
id=$(bash scripts/device/ctl.sh send composer-debug-start message)
bash scripts/device/ctl.sh wait "$id" 20
id=$(bash scripts/device/ctl.sh send composer-debug-text 'Schreib Alex: Ich komme zehn Minuten später, fangt bitte ohne mich an.' final 0)
bash scripts/device/ctl.sh wait "$id" 20
id=$(bash scripts/device/ctl.sh send composer-state)
bash scripts/device/ctl.sh wait "$id" 20
```

The clean room log records `agent.status` request at sequence 10, `tMono:532721.8387186667`, then sequence 11 at `532725.6267680001`:

```json
{"event":"error","message":"incomplete"}
```

This is 3.788 seconds after the request. The following records contain `pending.edit` with no lines and `busy:false`. No response, tool operation or provider usage record was logged. The request seed contains a Message-specific system prompt and ten tools; the request contains one user message with current document and observed events. Model, thinking configuration, HTTP response body and billed usage are not present in this retained log. No HTTP 400 or signed-thinking mode-change failure was observed.

The earlier session also failed at 21.735 seconds after its first request. A natural follow-up, “Mach die Nachricht bitte freundlicher und bedanke dich fürs Warten.”, remained verbatim in the document. Its log records two further requests, each ending `incomplete`; this was observed behavior rather than an intentional idle-call loop. Because a later setup operation overlapped testing, the clean retry is the primary failure evidence.

## UI and delivery boundary

The native full-screen [capture](artifacts/phone/native-field-apple-keyboard.png), supplied by the device-visual agent and independently inspected, shows the native field harness with Apple's QWERTY keyboard. It does not show the Legato Composer pane. The runtime injection commands operate the real host Composer session, but this capture does not prove that its document was visible or interactive in the keyboard extension.

No keyboard text-proxy Insert, tap-through word picker, undo, spoken correction, mode transition, final-pass stop or immediate host acceptance passed in this blocked round. An Email low-confidence Morgan token (`confidence:0.35`, language `en`) was admitted before interruption, but its word-tap attempt failed at device availability. That is not an alternatives or pinning pass.

No source changes, rebuild, simulator run, key read/export or production deployment was performed by this UAT agent. The clean session was cancelled and the phone released at the end of this round.
