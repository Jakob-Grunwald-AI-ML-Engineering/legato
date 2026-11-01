# Auto writing mode — 2026-10-30

Auto is an optional fifth mode in both native apps. Message remains the default; the four manual modes retain their existing prompts and tools. Auto asks the model to select a writing skill through `load_writing_guidance`, whose closed schema permits Message, Email, Prompt or Note. The tool returns the existing bundled mode prompt as conversation context without editing the document, changing UI mode or replacing the system prefix. Both live and restructure participants have the same skill capability.

## Real Claude checks

Two synthetic finalized-transcript scenarios ran through the signed native Mac ComposerSession and real Claude clients, using existing Keychain credentials. Both participants independently selected the correct guidance in both scenarios. Actual streamed tool calls and results are recorded in [sanitized evidence](artifacts/auto-mode/provider-tools.json); full private provider traces remain in `/Users/work/Documents/sessions/<sessionID>/room.jsonl` and are not committed.

| Scenario | Observed skill calls | Authored result |
| --- | --- | --- |
| Email to Morgan about Project Atlas staging rollout Tuesday at 14:30; ask whether it works | Live and restructure loaded Email; successful results at room seq 38 and 118. Live document write succeeded at seq 136. | Hi Morgan, / The Project Atlas staging rollout is scheduled for Tuesday at 14:30. / Does that time work for you? / Best regards |
| Coding prompt for CSV import preview, field mapping, every-row validation, staging-only dry run, no production writes | Live and restructure loaded Prompt; successful results at seq 37 and 244. Live document writes succeeded at seq 311 and 314. | Build a CSV import preview for a coding assistant to implement. Let users map CSV fields to target fields, validate every row, and run a dry run in staging only. Never write to production. |

Email session: `7B610FB9-5EDE-4A58-880B-9D99638FAFCB`. Prompt session: `134DD82C-91B6-4129-8EF0-C711228B2AE4`. Both observations ended with mode Auto, `busy:false,error:"",microphoneLeaseActive:false`. These were two bounded scenarios without quality retries. Version checks rejected obsolete restructure transactions after concurrent live edits; the agents refreshed the document instead of overwriting it. The Prompt live participant also recovered from one invalid document transaction. These outcomes establish this bounded skill-loading behavior, not universal writing quality.

## Checks and scope

The loader contract first failed against the old executor, then passed after implementation. `swift test --filter LegatoAgentTests` passed all 10 tests, covering read-only exact resource loading, rejection of Auto/unknown/path-like skill names, closed schema, unchanged manual tool inventory, both participants, real runner tool-result continuation and a stable system prefix during specialization. Signed iOS and Mac builds passed on the final source; existing Swift concurrency/orientation warnings remain. Root owns the epic integration gate.

The Mac development app used identity `de.gruenwald.legato.mac.composer-debug`, bridge `/Users/work/Library/Caches/Legato/composer-debug-bridge`, and `-LegatoDisableHotkeys YES`. Build: `/Users/work/Library/Caches/legato/device-derived/eb3d9c1eaece/Build/Products/Debug/Legato.app`. Build/test logs remain in `.claude/tmp/auto-mode/` of the implementation worktree. The fifth iOS choice uses the existing scrollable key popup; its native test helper can scroll to Auto. No phone install or native fifth-row selection was performed in this leg because the phone was assigned to independent speech UAT.

Input used `composer-debug-start auto` and `composer-debug-text`, through production transcript acceptance and agent document tools. No microphone capture or Soniox request, host insertion or Stop/final-pass assertion was exercised. After both cases, cancellation and mode selection left the Mac app `idle,Message,busy:false,dictating:false,microphoneLeaseActive:false,error:""`.
