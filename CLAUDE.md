# Legato

Open-source on-device dictation app for iOS and macOS (Swift).

## Branches and CI

- `main` lands only through the merge queue (squash): `gh pr merge <n>` enqueues; never push to `main` or bypass the queue.
- Before enqueueing, run the full `scripts/ci/test.sh` locally on the final candidate: shell checks, all package tests, and unsigned iOS and macOS app builds. Record the tested revision, toolchain and result. Revalidate affected work if the candidate changes; do not enqueue a failing candidate.
- The required `gate` check runs on Ubuntu for PRs and merge groups and reports this policy; it does not run or attest to local validation. Wait for the protected queue to finish and verify `MERGED`. The merge-group revision is not independently build-tested remotely.
- `main` pushes do not re-test. Release checks and shipping on `live` keep their existing workflows and permissions.
- Deploy: `git fetch origin && git push origin origin/main:live`. Never force-push `live`. Every push to `live` ships (`.github/workflows/release.yml`).
- CI entry points are `scripts/ci/test.sh` and `scripts/ci/release.sh check|mac-build|ship`. Wire builds there, not in YAML.

## Build output

- Session start and wrap-up: `scripts/dev/prune-build-caches.sh --delete` removes all Legato build output except the one fixed DerivedData per target (`derived/{gate,mac,ios-sim,ios-device}`) and `SourcePackages`, skipping anything in use. `--report` shows disk use per directory (`scripts/dev/build-caches.md`).
