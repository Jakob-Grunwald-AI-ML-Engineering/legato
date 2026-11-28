# Legato

Open-source on-device dictation app for iOS and macOS (Swift).

## Branches and CI

- `main` lands only through the merge queue (squash): `gh pr merge <n>` enqueues; never push to `main` or bypass the queue.
- Before enqueueing, run the full `scripts/ci/test.sh` locally on the final candidate: shell checks, all package tests, and unsigned iOS and macOS app builds. Record the tested revision, toolchain and result. Revalidate affected work if the candidate changes; do not enqueue a failing candidate.
- The required `gate` check runs on Ubuntu for PRs and merge groups and reports this policy; it does not run or attest to local validation. Wait for the protected queue to finish and verify `MERGED`. The merge-group revision is not independently build-tested remotely.
- `main` pushes do not re-test. Release checks and shipping on `live` keep their existing workflows and permissions.
- Deploy: `git fetch origin && git push origin origin/main:live`. Never force-push `live`. Every push to `live` ships (`.github/workflows/release.yml`).
- CI entry points are `scripts/ci/test.sh` and `scripts/ci/release.sh check|mac-build|ship`. Wire builds there, not in YAML.

## Meetings

- Measure speaker changes on real saved meetings with `legato meetings speakers --replay <id>` (read-only, counts only; [how](Sources/LegatoMeetingsCLI/speakers-replay.md)).

## Build output

- Session start and wrap-up: `scripts/dev/prune-build-caches.sh --delete` removes all Legato build output except the one fixed DerivedData per target (`derived/{gate,mac,ios-sim,ios-device}`) and `SourcePackages`, skipping anything in use. `--report` shows disk use per directory (`scripts/dev/build-caches.md`).

## Interactive testing and visible handback

- During human-like dictation, typing and cursor testing, target less than 500 ms of interruption caused by Legato. Any keyboard or dictation lock longer than one second fails acceptance. Measure the longest observed delay, not only averages; distinguish host/input latency from automation transport and recognizer latency. Deliberate delays in the raw exploration tool are not product responsiveness evidence.
- Headless iOS simulators share host audio resources. Prefer physical-phone or verified audio-isolated tests during normal Mac dictation; headlessness alone is not isolation. Stop owned simulators and VMs when the block ends. If host audio becomes choppy, stop owned tests first and obtain approval before stopping older or unrelated sessions. VM audio stays disabled; CPU and memory are still shared.
- Release the physical devices visibly whenever an interactive test block ends, including temporary gaps for builds, analysis or waiting. A chat update alone is insufficient: Jakob may not be reading the chat. Do not keep controlling the foreground after signaling handback.
- iPhone handback: end the raw probe, stop the test take, release the test microphone/provider stream, verify idle and unarmed, then navigate to Home. Preserve existing user drafts and preferences. Do not leave a test field or Settings open as the free-device signal.
- Mac handback: stop interactive automation, finish or cancel the test take, release its capture/input leases, close the test dictation panel and only the windows, tabs and isolated app copies created by this test block. Keep ownership identifiers when creating them. Preserve the installed app and pre-existing user windows, tabs, documents and drafts; never close all Safari/TextEdit windows or terminate unrelated processes.
- Resume by visibly reopening the test surface before sending input. The user yields when automation becomes visible; no repeated permission is needed within an already authorized testing session. Honor any explicit pause immediately. Finish with the same visible handback and record what remains running.
- Keep the internal [live keyboard probe](scripts/device/keyboard-probe.md) available for future exploration. Choose one primitive action, inspect its raw observation, then choose the next; a predefined walk or scripted driver is not interactive exploration or agent UAT.
