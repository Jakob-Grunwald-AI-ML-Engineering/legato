# Legato

Open-source on-device dictation app for iOS and macOS (Swift).

## Branches and CI

- `main` is PR-only, squash merges, with strict up-to-date protection. The required check is `gate`.
- Tests run once, on the PR, never on push. Nothing re-tests on main or live.
- Deploy: `git fetch origin && git push origin origin/main:live`. Never force-push `live`.
- Every push to `live` ships (`.github/workflows/release.yml`).
- CI entry points are `scripts/ci/test.sh` and `scripts/ci/release.sh`. Wire builds there, not in YAML.
