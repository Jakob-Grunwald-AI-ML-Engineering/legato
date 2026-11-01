# macOS companion settings

Native settings now separate Overview, Writing, API Keys and Shortcut in a sidebar. The overview shows saved-key presence, the existing shortcut, and actual microphone, Accessibility and Input Monitoring permission state. Writing keeps the existing single `composer.liveModel` and `composer.personalPrompt` preferences. Provider fields never load saved key values, and blank or whitespace-only entries preserve existing keys. The companion menu has a distinct composer action and settings entry.

## Native verification — 2026-10-30

Signed Debug build from `composer/mac-companion-settings`, based on `847b1a4`, using the existing isolated identity `de.gruenwald.legato.mac.composer-debug` and bridge `/Users/work/Library/Caches/Legato/composer-debug-bridge`:

- `LEGATO_MAC_SIGNED=1 LEGATO_BUNDLE=de.gruenwald.legato.mac.composer-debug LEGATO_MAC_ROOT=/Users/work/Library/Caches/Legato/composer-debug-bridge bash scripts/device/ctl.sh --target mac build` passed. Local Xcode 27.2 substituted for the unavailable pinned Xcode 26.6; existing shared-source deprecation warnings remain.
- `codesign --verify --deep --strict` passed for the resulting app.
- Actual menu → Settings, all four sidebar pages, native model picker and text editor were driven through macOS Accessibility controls. The settings window reported `AXMain` and `AXFocused` true.
- Selected Sonnet and entered a harmless temporary personal instruction. Both survived process restart in the actual native controls and preferences. Restored the original Haiku and empty prompt afterward.
- Saved with both secure fields blank. Both providers still showed Saved, and the notice read “Saved keys kept unchanged.” No provider key was displayed or changed and no provider request ran.
- A bounded normal-hotkey launch enabled Change shortcut. Starting recording showed “Press a key…” and Cancel; Cancel returned to the existing Right ⌘ shortcut. No replacement key was pressed. Leaving the page or closing the view also cancels capture.
- Microphone, Accessibility and Input Monitoring displayed Allowed based on actual permission APIs. Input Monitoring remains Allowed under the safety launch with global hotkeys disabled; event-tap availability is shown separately by the recorder.
- Final bridge state: `idle`, `busy=false`, `dictating=false`, empty document/session, `microphoneLeaseActive=false`. Returned the owned app to `-LegatoDisableHotkeys YES`.

Settings and setup scenes use `contentMinSize`, an initial 820×640 size and scrollable detail content. Native resize attempts through this host's System Events and synthetic mouse route were ineffective; actual physical resizing remains unverified. No full test suite or paid-provider probes ran for this visual change.

## App-only evidence

All captures target an exact Legato window ID and contain blank secure fields. Overview/Writing/Keys captures precede the final scene-size adjustment; the recording capture is from the final signed build.

[Previous settings](composer-mac-settings/before.png) · [Overview](composer-mac-settings/overview.png) · [Writing](composer-mac-settings/writing.png) · [API Keys, blank Save](composer-mac-settings/keys.png) · [Shortcut capture](composer-mac-settings/recording.png)
