# Pre-run evaluation contracts

Fixtures and intent annotations are frozen before either evaluation runs. They may not be retuned to improve utility. Fixture versions are authored contextual examples, not captured recognition results. No audio groundtruth exists for these local cases.

Production baseline whole-text equality follows Swift canonical equivalence; raw unchanged suffix bytes are checked independently. Canonically equivalent P05 may leave the original decomposed bytes untouched. The experimental byte-aware Character patch must land the declared new bytes and preserve raw suffix bytes.

Alternative usefulness uses predeclared contextual acceptable outcomes, accepts multiple paraphrases where appropriate, and imposes no lexical or phonetic similarity threshold. This bounded annotation set can miss other defensible wording: unannotated proposals are semantic misses/unassessed, not automatically harmful. Explicit harmful labels take precedence over acceptable labels: split-token proposals that leave a duplicate neighbouring token are not useful single-span repairs. Ambiguous cases require choice. Nonempty proposals for already-correct cases count as unnecessary offers, not automatic edits. No candidate is actually accepted into a host.

Quality is reported per opportunity/arm, using repetition 0 and stopped context once; all 3 repetitions and both active/stopped disconnected rank calls remain in JSONL. First invocation versus later timings are separately reported. Active-run state suppression is the expected production behavior. Scratch guard assertions are policy evidence only.

Every baseline and scratch record carries real assertions or explicitly unsupported API scope. FieldWriter failure paths exercise its own verified write and subsequent-event behavior. Proxy planner has no write-result interface; fault cases are explicitly unsupported there rather than credited with scratch verification. Fault boundaries for the experimental variant are modeled move/delete/insert/restore plus preflight. Stopping after uncertainty is mandatory, with no blind destructive retry.
