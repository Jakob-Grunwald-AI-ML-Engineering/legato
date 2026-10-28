# Isolated Legato #70/#71 evaluations

Read reports/summary.md for conclusions, measured failures and native gaps. Evidence is deterministic harness + SDK compile only. The package links the actual Legato products from a local `source/` snapshot at 9e113ed85b1d24449028ac200ef71a464d1ee3e0 with LEGATO_STUB_DEPS=1. No models, live LLM, phone or native experimental UI are used.

The compact payload intentionally omits the source archive, binaries and build caches. Run `bash reproduce.sh /path/to/legato-repository` from this payload on macOS 26+ with the installed Swift 6.2+ toolchain. It creates a fresh temporary workspace, archives the pinned revision from that provided repository, preserves Package.resolved before stub SwiftPM, and checks every exit. It prints and retains its new workspace. It does not write the supplied repository. Reproduction of platform suggestions/timings may vary by OS/dictionaries.

Original full scratch verification (run from /tmp/legato-followup-evaluations):

```bash
python3 check_validator.py
python3 validate_reports.py --root /tmp/legato-followup-evaluations
```

Exact original commands, environments, exits and logs remain in reports/*-process.json and corresponding logs in the original scratch root. source-manifest.json inventories all original inputs; provenance/Package.resolved preserves the expected-deleted lockfile. provenance/artifact-sha256.json includes the actual original runner binaries and all original outputs. Final validation JSON/log are excluded from self-hashing. The export retains initial failed patch output and process receipts plus compact failure reasons; complete original compiler/test logs remain in the scratch root.

All baseline runs are targeted. Fixtures were frozen before first execution; no result-driven tuning. Useful candidate scoring is against authored contextual intent, not real audio or universal correctness. VersionWordsSource .engine tags mean authored version differences, not recognizer n-best/confidence. Canonical no-ops, unsupported cases, safely declined edits and uncertain landings are distinct outcomes. Experimental cursor movement/readback is scratch policy, not a native capability. See prospective native gaps in the report; neither issue is completed by these evaluations.

The included original manifests and validation receipt describe the original scratch run (109 artifact hashes verified). Original binaries and full logs remain outside this compact payload; reproduce.sh generates fresh results and source/output hash receipts, including the SDK typecheck. No production app source is changed.

The packaged reproduction script was also run end to end in a fresh workspace: all six process exits and the SDK typecheck passed; source/fixture inventories were unchanged. See reports/portable-reproduction.json. That run reproduced 164 patch records, 288 ranking records and nine useful repair cases per arm, with zero failed safety/state assertions.
