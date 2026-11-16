# Live keyboard proxy exploration

The internal iPhone build exposes a live, single-operation interface to the real keyboard extension's `UITextDocumentProxy`. Use it to discover what a host reports before choosing a reading strategy. It is not the in-app keyboard harness, a model instruction or a predefined walk. Ordinary Release builds exclude the endpoint.

Open a synthetic test field in the host app, select the installed Legato keyboard and keep the internal host app available. Background host liveness may require microphone arming; release the microphone when finished. Use the existing [device control](README.md) setup and identity variables. The default target is the physical phone; `--target sim` uses the real simulator extension when it is installed and visible, not the in-app harness.

Stop the current take and let pending field edits finish first; `begin` refuses an active take or unfinished field work rather than dropping spoken text. The app-scoped probe client identity survives a host relaunch, so the same operator can still end their existing lease.

Call `bash scripts/device/keyboard-probe.sh begin` to bind the current field and acquire exclusive queue ownership. Then choose one command at a time from its returned observations:

| Command after `keyboard-probe.sh` | Effect |
| --- | --- |
| `read` | One exact proxy observation, without moving. |
| `move -1` | One native negative cursor delta and immediate observation. |
| `move 12 200` | One native delta, immediate observation and another after the explicitly chosen 200 ms. |
| `pause 300` | Wait the chosen 300 ms and observe again, without moving. |
| `status` | Inspect the current probe lease and field. |
| `end` | Release queue ownership and reseed at the actual cursor, without returning it elsewhere. |

These are independent examples, not a sequence to replay. Inspect each result before deciding the next move. Deltas are passed unchanged to the native proxy; do not assume their units are graphemes or UTF-16. In particular, measure emoji and paragraph-boundary behavior in the actual host. The sample waits above are chosen examples, not measured recommendations.

Replies contain the probe session and field identities, queue ownership, and observations with elapsed and monotonic timestamps, exact `before`/`after` windows, selection when reported, `hasText` and secure-field status. An immediate matching window may be an optimistic echo: request a later read and compare it with the visible field. A missing selection does not prove no selection exists. The endpoint refuses secure or unavailable fields and invalidates an exploration when its reported document identity changes or the keyboard session ends. Safari can reuse that identity for multiple fields on one page; raw proxy data cannot reliably detect every such switch. End the probe before switching fields and begin a new exploration afterward. The idle lease expires after 120 seconds as an operational safety policy, not a measured host limit. End explicitly when finished; the cursor stays where the exploration left it.

The thin shell wrapper forwards arguments to the extension, which owns validation. The same operation is available through `ctl.sh send keyboard-probe <action> [args...]` followed by `ctl.sh wait <command-id>`. `LEGATO_PROBE_TIMEOUT` controls the wrapper's reply budget, default 45 seconds. No model requests, text writes or deletes are part of the probe interface. Cursor movements can still collapse a host selection, so use controlled test text and deliberate actions.

Output and bridge logs contain full field text. Keep raw explorations in the private cache, never capture passwords or private drafts, and commit only synthetic examples or redacted aggregate measurements. Test-message sending is a separate native action and requires session authorization; this probe never sends messages.

## Visible handback between test blocks

Follow the repo's [interactive testing instructions](../../CLAUDE.md#interactive-testing-and-visible-handback), including short gaps for builds or analysis. End the probe explicitly, stop the test take, release the test microphone/provider stream and verify idle/unarmed, then put the phone on Home. Home is the visible free-device signal. Do not call `ctl.sh background` for this purpose: it opens Settings rather than Home. On resumption, visibly reopen the controlled test surface before sending input. Preserve existing drafts, clipboard and preferences. At the end, leave no exploratory lease active.

## Clipboard-safe paste fixtures

Internal host commands `clipboard-preserve`, `clipboard-fixture <synthetic text>` and `clipboard-restore` support native Paste exploration without discarding the previous clipboard. Invoke them through the existing device control bridge while Legato is foreground. The original complete `UIPasteboard.items` must round-trip exactly through a private, file-protected backup before any mutation. Unsupported representations, an apparently empty or unreadable clipboard, an existing backup or changed clipboard ownership cause refusal. No original clipboard contents appear in command replies. Empty is refused because denied access can also appear empty.

Install only synthetic fixture text, use the host's actual native Paste action, then restore the original clipboard before visible device handback. The restore refuses to overwrite a newer clipboard copied outside this fixture session. If any operation refuses or restoration fails, retain the private backup and report the gap; do not declare clipboard restoration or the paste check passed. The helper is internal-only and is not a production clipboard feature.

The helper preserves exposed item representations, not inaccessible pasteboard options such as the original expiration. Fixture writes and restoration are local-only so private restored contents are not newly exported through Universal Clipboard. Report that limitation; do not claim every original clipboard attribute was restored.

`clipboard-status` returns only item count and type-presence flags while the internal host is foreground. It does not return original contents or mutate the clipboard. Use this to distinguish observed metadata from the preservation helper's generic refusal; it is not a substitute for a successful preservation result.
