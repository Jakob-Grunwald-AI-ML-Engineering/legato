# Field cleanup runtime acceptance

Accepted on 2026-11-16 through independent interactive exploration of the built Mac app in TextEdit and the built iOS app's keyboard harness in an isolated iOS 26.5 simulator. The tester used one or two actions at a time and reacted to displayed field content, screenshots and persisted History; this was not a scripted scenario suite. Both builds used offline synthetic speech and deterministic title-casing cleanup.

Mac cleanup included manually typed prefixes and intervening text. A roughly 77-word field was cleaned at a synthetic pause while the take remained open. Further manual input and speech remained possible. History recorded the read field, confirmed result and cleaned outcome. The short-take stop completed in 610 ms in this setup.

On the simulator, manual keyboard input survived between spoken passages, and subsequent speech followed it. Initial 39-character and 32-character publications landed in 360 ms and 350 ms respectively. A manual key command returned in 4 ms; this is bridge-command handling, not physical touch latency. Final cleanup was confirmed 3.927 seconds after stop. These observations are not a worst-case bound for speech resuming inside a Mac edit unit.

The tester found a real status defect: successful cleanup and History said cleaned while the keyboard retained an earlier kept-as-typed notice. The shared typed cleanup outcome now reaches the keyboard with run, field and timestamp checks. Rebuilt-app acceptance repeated the failing interaction, verified the corrected field and absence of the old banner, then used Return and another take successfully. The conductor independently queried the final field and empty status. [After-fix screenshot](simulator-fixed.png).

The tester also encountered `harness-type`, which runs a fixed fixture rather than typing its argument; the command documentation now distinguishes it from `harness-key`. A Mac ordering observation without explicit cursor movement occurred with the global event tap intentionally disabled for isolation, so it cannot establish production key-origin behavior. Moving the caret explicitly before manual typing preserved order.

## Evidence boundaries

No paid calls, real microphone/ASR, provider cleanup quality, physical iPhone, real keyboard-extension host, production deployment or Mac hotkey handling were tested. History was verified in persisted storage rather than through its UI. The Mac event-tap limitation above remains explicit. The larger sequential-overlap contract is covered by focused tests; runtime exploration used an approximately 77-word take rather than a long multi-pause corpus. Acoustic calibration and chunk workload measurements are documented separately in [recording evidence](../../plan/field-cleanup-measurements.md).

The repository gate compiles both applications and runs package/shell checks using local Xcode 27.2; pinned Xcode 26.6 was not installed. Simulator acceptance additionally used Xcode ad-hoc signing to grant its App Group. Mac acceptance used an isolated copy with the installed app's development identity and provisioning profile. Installed apps, other sessions and permissions were preserved. No promotion to live is included.

## Supplemental Mac timing probe

A separate offline timing probe observed the beginning of a cleanup edit, then supplied new synthetic speech while that edit was still changing the TextEdit field. The first sampled partial new text appeared within 497 ms of the send invocation; the complete first word was observed by 724 ms. Later cleanup remained pending while the new text appended. This demonstrates observed preemption and responsiveness in that run, not an exact first-character latency or general worst-case bound: field polling itself took approximately 230 ms per sample. The [timestamped observations](mac-resumption-timing.json) contain only the synthetic fixture text. This probe is a measurement, not an additional claim of unscripted UAT or live microphone behavior.
