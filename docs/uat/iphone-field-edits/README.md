# iPhone field editing measurements

## Physical baseline

Measured on 2026-11-16 with signed main `1007a83` installed over the existing `de.gruenwald.legato` identity, on iPhone 17 / iOS 26.6.1 (23G83), controlled over Wi-Fi with a persistent WDA helper. Build toolchain: local Xcode 27.2 (pin 26.6 unavailable). The user authorized phone/microphone control, test-sized real Soniox/API calls, and messages only to their own verified account. No speech or sound from the user is required.

The first measurement is one Safari plain textarea on a local synthetic fixture. Its initial value was `Alpha beta gamma delta epsilon zeta.` and Magic was instructed to replace only `gamma` with `GAMMA`. The real Claude instruction completed successfully. WDA readback afterward showed `Alpha beta GAMMA delta epsilon zeta.`; the other characters were preserved. This was a directed baseline measurement, not independent agent UAT or recognition-quality evidence. Soniox recognition was not exercised.

The edit journal uses the phone's monotonic uptime clock. Paired each issued operation with its next queue confirmation. The two moves were confirmed in 48.043 and 49.979 ms; five one-grapheme deletes took 115.771–120.794 ms each. Five insert acknowledgements took 6.725–7.138 ms each, but proxy insert reports can be optimistic: these are queue acknowledgement times, not independent per-character host-truth measurements. Whole first-move to return confirmation was 809.613 ms. The final host value was checked independently after completion. One observed edit and 2/2 reported moves do not establish a host reliability rate or worst-case latency.

Only the synthetic field's journal is committed in `safari-textarea-baseline.jsonl`; the raw mixed historical journal remains private in the machine cache. The summarized operation pairs are in `safari-textarea-baseline-summary.json`.

## Physical raw-proxy exploration

The durable internal probe was used one primitive action at a time in the real extension, with the next action chosen from the preceding observations. The [raw baseline subset](phone-raw-baselines.jsonl) contains only synthetic field text. Later probe builds include instrumentation and the draft guard on the same main base; these raw observations precede the production reader and scheduling fixes. An intentionally chosen delayed read is an observation time, not a measured confirmation latency or recommended settling constant.

| Host / field | Observed result | Evidence and limit |
| --- | --- | --- |
| Safari textarea | A real Claude `gamma` → `GAMMA` instruction preserved all other characters. | One directed edit; 2/2 cursor reports confirmed in about 48–50 ms. No reliability-rate inference. |
| Safari div paragraphs | Empty `after` at the first paragraph end hid another paragraph. Native `+1` initially echoed the old position; a chosen read about 103 ms later exposed the newline and second paragraph. From the stable final paragraph end, ordinary Magic successfully changed only `beta` → `BETA`. | [Individually chosen operations](safari-div-raw-probe.jsonl), followed by raw baseline commands 47–49. Location and boundary state matter; div editors are not uniformly unreadable. |
| Safari Select All | Visible full-field selection and a collapsed end caret produced identical raw values: full `before`, empty `after`, nil selection and `hasText = true`. No cursor move was issued to distinguish them. | Raw baseline commands 52–53; the conductor independently inspected the private native screenshot showing full selection. Raw read-only values cannot prove the selection absent. The screenshot stays private because it also contains local network UI. |
| Notes | Native `-10` and `+10` reported the expected text split and return, both immediately and in chosen reads about 102–103 ms later. Only the current paragraph appeared in this sample. | Commands 55–58. This does not establish complete-note reading or independent per-operation host confirmation. |
| WhatsApp, official Message Yourself | The visible synthetic draft was complete while the proxy reported only `Le` for at least 36.9 seconds between reads. Native zero-offset movement did not refresh it. A deliberately chosen raw `-1` first echoed `L` / `e`, then exposed the full draft split in the chosen 106.9 ms observation. | Commands 61–66. External WDA text entry, not hardware keyboard or native Paste proof. The raw move is exploratory, not a justified automatic recovery. |
| Messages, verified own contact | External WDA text entry likewise left `Le` in the proxy. A deliberate raw `-1` exposed the complete synthetic draft split at the chosen 106.9 ms observation; `+1` reported the final caret again. | Commands 67–70. Recipient was verified through Contacts My Card before typing. No send is claimed by these records. |
| Mail, new unsent draft | The complete synthetic body was reported; native `-10` produced the expected split both immediately and in the chosen 105.8 ms observation. | Commands 71–73. No recipient or send is part of this baseline. |

The indistinguishable Select All state and stale nonempty prefixes require conservative provenance handling; repeated identical windows and `hasText` alone do not prove a safe cursor or complete field. The raw command interface deliberately exposes these ambiguities without applying a production interpretation.

## Validation still required

Native Paste, emoji and automatic list continuation; pending-cleanup self-send with History recovery; candidate pause-time corrections and measured resumed speech/manual input; two clean stress seeds; and fresh independent UAT remain separate from the baseline above. Physical hardware-keyboard behavior is not established by WDA input. The package and app checks also do not establish these runtime outcomes.

An unexpected pre-existing messaging draft was left untouched. Subsequent touches check the expected foreground bundle. Test-sized real Soniox requests are authorized but are not proven by the real Claude instruction results. No real-ASR quality claim follows from injected text or deterministic cleanup.

## Visible device handback

Between test blocks, the physical phone was explicitly returned to Home after `probe end` reported inactive/no lease and microphone release reported `armed = false`, `warmInput = false`, `reserved = false` and route idle. Candidate builds run without foreground device control. Mac test windows and the isolated test copy were closed while the installed app and pre-existing work remained. This follows the repository's durable [handback instructions](../../../CLAUDE.md#interactive-testing-and-visible-handback).

## Mac evidence

The [Mac handoff report](mac-handoff.md) documents the reproduced cursor delay, incorrect-position typing and the native input handoff fix, including exact source and binary provenance. Completed fixed runtime samples in TextEdit and Safari preserved the input position and observed typing/cursor responses below 100 ms. These are synthetic fixture observations with the real input observer, not physical microphone or provider results.

The older `mac-resumption-summary.json` records file-publication-to-observation times of 460–567 ms for partial text, including the debug bridge's 500 ms polling cycle. The [same-process monotonic journal](mac-monotonic-resumption.json) separately measures admitted speech to verified first character at 16–28 ms and the complete marker at 172–206 ms across TextEdit, Safari textarea and div contenteditable. Keep both transport and production-admission measurements visible; neither is acoustic-onset latency or a universal worst-case bound. See the Mac report for limits and the integrated candidate's remaining gate/UAT obligations.

## Live div exploration

The synthetic-only `safari-div-raw-probe.jsonl` records six individually chosen raw operations by the parent operator on the physical real extension. At the first div paragraph's end, `after` was empty even though another paragraph followed. One native `+1` move initially echoed the old report; an explicitly chosen ~103 ms later observation showed `before = "First paragraph alpha.\n"` and `after = "Second paragraph beta."`. A later native `+23` from the first paragraph end reached the complete second paragraph end. These are chosen observations, not a recommended settlement policy or guaranteed maximum. A subsequent ordinary Magic operation from the stable end of the second paragraph successfully replaced only `beta` with `BETA`, so the earlier refusal is not a blanket inability to read div editors at all positions. Initial field focus and block-boundary state remain part of the failure investigation.
