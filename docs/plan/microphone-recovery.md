# Resilient microphone capture

Capture promptly, retain opening speech while recognition connects, combine built-in and compatible headset input on iOS 26.2+, preserve monitored capture between keyboard appearances, and attempt bounded recovery before requesting foreground activation. Keep the draft and History across failures.

## Implementation

1. Admit dual-route capture on supported iOS systems, explicitly map every physical input channel into the engine, and fold the clocked channels to normalized mono. Fall back to built-in capture when configuration is refused. Preserve existing macOS capture selection.
2. Install the stream before starting the engine, admit on first valid PCM rather than waiting for a fixed calibration window, and capture concurrently with composition setup. Retain post-tap speech during recognition startup; discard idle and abandoned-take speech.
3. Monitor PCM while detached, serialize recovery with admissions, and retry transient engine failures with a bounded budget. A release or newer admission wins over work already suspended. Reuse held session configuration in the background.
4. Keep the Live Activity through recovery, show reconnecting until capture is healthy, and end the ready lease on exhausted capture recovery. Provider failures do not revoke a healthy microphone lease.

## Proof and delivery

Run focused audio conversion/recovery, microphone admission/cancellation, keyboard reappearance, opening-audio buffering, and activity-planner tests. Compile the iOS app locally and let the protected merge queue run its required full gate.

A fresh UAT agent uses the installed phone app as a user, with AirPods connected, and returns observed behavior, friction, and retained evidence. The change should make microphone readiness and keyboard reuse reliable. The physical iPhone and capture-only controls are available; live validation is authorized for at most three short dictation takes totaling under one minute using saved provider keys; no other external writes are authorized. Simulator/unit results do not establish acoustic quality, real speech recognition, or Bluetooth timing. Retain device snapshots of actual ports, mapped channels, PCM freshness and foreground/background capture separately.

After findings are fixed, open a PR against main. Leave it open if material hardware evidence remains missing; otherwise wait through the full merge-group gate and verify MERGED. Do not promote live.

## Input preference

Phone microphone is the default, preserving other apps’ music. Combined phone/headset capture is optional because iOS dual-route capture does not support mixing other apps’ audio. Changes apply on the next fresh microphone admission; the settings expose Release microphone. Failed dual capture downgrades once to the phone input where iOS allows it.
