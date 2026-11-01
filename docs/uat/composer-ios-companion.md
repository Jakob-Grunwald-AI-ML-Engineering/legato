# iOS companion and settings

The companion uses persistent Compose, History and Settings tabs. Compose has a compact empty card, distinct recording/copy/clear controls, correction guidance and a separate keyboard practice screen. Settings separates writing preferences, device-only provider keys, keyboard setup and microphone access.

Provider fields start empty and never display stored secrets. Each save affects one provider only; empty or whitespace-only input disables saving. Personal instructions save automatically. The Settings tab rejects custom keyboard extensions through UIKit's documented application delegate hook so ordinary text editing can use the system keyboard; other tabs still allow Legato.

Signed physical-device build and installation passed on 2026-10-30. Normal companion captures: [before](artifacts/ios-companion/before.png), [after](artifacts/ios-companion/after.png). The after capture includes the compact card and reachable practice button; the subsequent Settings keyboard gate also compiled and installed successfully. No microphone recording or provider call was needed.

Native `scripts/device/native-control.sh companion-settings` passed on the physical iPhone 17: one test, zero failures, 27.7 seconds. It tapped Settings, typed and restored personal instructions through the system keyboard, opened both provider editors, verified existing-key status and disabled blank/whitespace saves, and returned to Compose. Valid keys were preserved. The initial runner stalled while locked; explicitly selecting `platform=iOS,arch=arm64` resolved the ambiguous arm64e/arm64 destination. Artifacts: `.claude/tmp/native-control/run.WuwknL/result.xcresult`.

No live voice/provider quality check was performed for this UI change. A real provider replacement was deliberately not exercised against the valid installed keys. Dynamic Type extremes and model-picker persistence were not separately device-tested.
