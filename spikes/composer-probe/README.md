# Composer physical-device probe — 2026-10-30

Verdict: keyboard layout accepts heights larger than the display on the real iPhone. Composer animation, transport and provider feasibility remain unproven. This is a bounded preliminary report; #110 stays open. Continue implementation, then repeat the missing checks against the actual composer UI rather than expanding the disposable harness.

## Results

| Check | Observed result | Verdict |
| --- | --- | --- |
| (a) Maximum keyboard height | Requests of 600, 1200 and 2000 pt each produced that actual view and extension-window height, at 402 pt width. The screen is 874 pt high. Largest tested layout: 2000 pt. | Layout supports screen-sized requests; usable visible maximum, clipping and touch routing not established. |
| (b) Animated-pane memory, 60 lines / 10 Hz; ≥20 MB | Unloaded keyboard baseline: 163331224 / 155253912 / 143686808 available bytes at the three heights (155.76 / 148.06 / 137.03 MiB). | Pending: these are not animated-pane measurements. |
| (c) Blur-morph FPS; p50 ≥55 | No Instruments capture. | Pending actual composer UI. |
| (d) Link RTT p50/p95, 10 Hz | Not measured. The functioning CoreDevice diagnostic bridge is not the App Group + Darwin link RTT. | Pending extension/host echo probe. |
| (e) Soniox, three minutes of Jakob's mixed speech | No API call; no credentials accessible in this probe. Existing developer replay is only 129.28 seconds and has no new listening verdict. | Pending keys, requested recording and Jakob's ear verdict. |
| (f) Phone Claude cold/warm TTFT and first tool call | No API call; no credentials accessible. No real SSE fixtures captured. | Pending keys and host client. |
| (g) Soniox WebSocket / Claude SSE background survival with active mic | Not exercised; no provider connections started. | Pending host integration and keys. |

No provider assumption failed empirically: provider checks were not run. Do not interpret missing measurements as threshold passes. No paid calls were made. No simulator was started.

## Physical evidence and method

Base: `17cd8056b98ae5818892ab7563ad1b41b8d7ed26` on `epic/composer`. Device: `00008150-000E60360245401C`, real installed extension `de.gruenwald.legato.keyboard`, Full Access true. Xcode 27.2 was available; pinned 26.6 was unavailable.

A throwaway Debug build reused the existing `LegatoHarnessSystemField` host, which focuses a real text field and selects the enabled Legato keyboard extension. The extension's existing priority-999 height constraint was stepped through 600, 1200 and 2000 pt at three-second intervals. One second after each step it sampled `view.bounds`, `window.bounds`, `windowScene.screen.bounds` and `os_proc_available_memory()`. It wrote JSON into its App Group; a temporary host diagnostic read those records through `scripts/device/ctl.sh`. This was the extension process, not the in-app SwiftUI keyboard replica. No Pow/TextRenderer workload was added.

Final samples from bridge command `c1793379220-00000004-54539`, received `2026-10-30T16:53:42.290Z`, completed `2026-10-30T16:53:42.297Z`:

```json
[
  {"date":"2026-10-30T16:53:35Z","requestedHeight":600,"actualHeight":600,"windowHeight":600,"width":402,"screenHeight":874,"availableBytes":163331224,"fullAccess":true},
  {"date":"2026-10-30T16:53:38Z","requestedHeight":1200,"actualHeight":1200,"windowHeight":1200,"width":402,"screenHeight":874,"availableBytes":155253912,"fullAccess":true},
  {"date":"2026-10-30T16:53:41Z","requestedHeight":2000,"actualHeight":2000,"windowHeight":2000,"width":402,"screenHeight":874,"availableBytes":143686808,"fullAccess":true}
]
```

The view's conversion to `nil` gives window coordinates, so it does not establish the window's physical placement or visible intersection. The 1200/2000 pt bounds exceeding the 874 pt display are specifically why layout height is not claimed as usable height. Three memory snapshots are baseline observations, not distributions or sustained-load evidence.

Direct CoreDevice access to the App Group root sample file returned access-policy error 11007; host readback succeeded. Signed builds, installation, extension startup and bridge readback all succeeded. The known signed shell app was restored from `device-derived/ff595a8532bb/Build/Products/Debug-iphoneos/Legato.app` and launched with harness flags disabled. Phone ownership was released for subsequent work.

## Replay and fixtures

The pre-shell checkout retains developer replay `Tests/LegatoFluidAudioTests/Fixtures/mixed-long.m4a`, duration 129.28 seconds, SHA-256 `a46d2a6d62d838b96bcebfe2cc925d1bd11fa5fe585f3e06667ae42b94db4125`. It is not a newly requested three-minute recording and is not present on the stripped epic branch. No audio was copied or uploaded.

SSE fixture list: none. Synthetic or reconstructed events would not satisfy the requested real Claude captures. Once credentials are available, record normal text and streamed tool input (`input_json_delta`), with a one-line request/provenance note for each; keep a mid-stream error only if genuinely observed. Never store request authorization or API keys.

## Follow-up checks

Use the actual #116 pane for the 60-line / 10 Hz run; measure extension headroom and Instruments FPS, plus visible height and touch routing in another app. Add a timestamped host/extension echo using the App Group + Darwin notification transport for RTT. Use the #113/#114 clients for phone provider timing and active-mic background survival, preserving raw SSE and recording provenance. Keep cold and warm cache timing separate and confirm warm requests through usage cache counters.

Validation for this report: successful signed throwaway device build/install/launch and final bridge sample retrieval above; Markdown whitespace and report-only staged diff checks. The full package gate was not rerun for this documentation-only result. Throwaway app modifications are excluded from the PR.
