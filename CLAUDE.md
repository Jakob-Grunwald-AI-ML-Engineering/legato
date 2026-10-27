# Legato

Open-source on-device dictation app for iOS and macOS (Swift).

## Branches and CI

- `main` lands only through the merge queue (squash): `gh pr merge <n>` enqueues; never push to `main` or bypass the queue.
- The queue runs the full gate (`gate` check) on main + the PRs ahead + this one, so the landed commit is the tested commit. No branch updates or re-runs by hand.
- PRs build nothing (`gate` just reports); the queue runs the package tests once (≤10 min cold, no caches). The apps are compiled on `live` pushes (`release-checks.yml`) and by local work. Nothing re-tests on `main`.
- Deploy: `git fetch origin && git push origin origin/main:live`. Never force-push `live`. Every push to `live` ships (`.github/workflows/release.yml`).
- CI entry points are `scripts/ci/test.sh` and `scripts/ci/release.sh check|mac-build|ship`. Wire builds there, not in YAML.
