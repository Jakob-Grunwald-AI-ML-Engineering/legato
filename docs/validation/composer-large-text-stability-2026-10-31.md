# Composer large-text stability

The reported iOS keyboard disappearance is not yet tied to a termination report. The current phone connection returned CoreDevice 4016, and no matching locally synced Legato/Jetsam report was available. This change removes confirmed unbounded costs; it does not establish the cause of the user's dismissal.

## Changes

- Long rewrites use exact longest-common-subsequence matching with linear-space rows instead of an old-word-count × new-word-count Int table. Ordinary edits retain the previous duplicate-word tie breaking, surviving words keep their records, and Undo restores the original words.
- Composer lines are created lazily. Long paragraphs use balanced Text composition instead of a deeply nested left fold. Word IDs and measured quote anchors remain unchanged.
- Particle removal and blur edits are limited to drafts of at most 240 words/24 lines and individual lines of at most 120 words. Large replacement and Insert removal use the inexpensive transition; the text remains complete.
- Dictation partials and newly validated sentences scroll to the current tail. Agent-only rewrites do not request scrolling, and active quote selections suppress following.

## Measured synthetic rewrite

Before: `47092bc`. After: this change's `WordDiff.swift`. macOS, optimized Swift executable, identical 5,000 unique old words and reversed proposed words, no provider or microphone. Both outputs retained the required exact LCS of one word and exactly the proposed text.

| Measurement | Before | After |
| --- | ---: | ---: |
| Maximum resident set size | 254,836,736 bytes | 8,323,072 bytes |
| Peak memory footprint | 250,626,624 bytes | 3,965,288 bytes |
| Wall time | 0.42 s | 0.45 s |

Measured with `/usr/bin/time -l`; this is the document reconciliation process, not keyboard-extension memory. The source table alone previously needed roughly 200 MB for this case. Runtime evidence files are `/tmp/legato-large-text-benchmark/{before,after}.txt`; the synthetic probe source is `main.swift` in that directory.

## Acceptance limits

Focused document regressions cover the 5,000-word reorder, a long paragraph edit with a pinned word and exact Undo, and duplicate-word identity. Link and session checks cover dictation progress and rewrite-only scroll suppression. Native combined-bundle build and actual UI acceptance are owned by the central UAT session.

Still required: long single-paragraph rendering, whole-draft replacement, large Insert into a real iOS target field, continued keyboard availability, scrolling and quote anchoring on the physical phone. No physical crash fix, microphone behavior, or release-build performance is claimed from the macOS probe.
