# Scheduler load investigation — issue #61

The 2026-10-29 controls did not reproduce the earlier parallel timeout hang. Both parallel variants passed under ten CPU workers; the variant with `.timeLimit` finished faster in this sample. Probes below establish that background-QoS work, not disk throttling, slows 20-100x under CPU load; that starved writers pin cooperative-pool threads into the observed hang shape is inferred from the samples, not reproduced. Production cannot fan out like the suite, but forced jobs run slower under load; the original hang itself remains unreproduced. No production priority or cancellation behavior changed.

The timeout's inability to enforce a hard stop is established independently: the bundled Testing implementation uses a structured task-group race, while `ProcessingScheduler.tick()` awaits an unstructured background job through a continuation. Cancelling the test body neither cancels that job nor interrupts its synchronous filesystem calls.

## Measured controls

Source: `82a6bc8213434bf95fed897c2a5a8b80b7a350b4`, exported with `git archive` into `/tmp/legato-scheduler-61`. The working checkout and its build directory were untouched. The only experimental source changes were the scheduling suite's annotation; every assertion and production source stayed intact.

Machine: macOS 26.6.2 (25G83), ten logical/physical CPUs, 32 GiB memory; Xcode 27.1 (27A9275), Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`), bundled Testing 2084. Dependencies used `LEGATO_STUB_DEPS=1`; models and microphone hardware were not exercised.

| Control | CPU workers | Tests / suites | Test-run duration | Runner wall time | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| Serialized, one-minute trait | 0 | 31 / 3 | 0.601 s | Includes cold build; excluded | Passed |
| Serialized, one-minute trait | 10 | 31 / 3 | 29.710 s | 33.951 s | Passed |
| Single file-backed lane, one-minute trait | 10 | 1 / 1 | 2.071 s | 5.541 s | Passed |
| Parallel, one-minute trait | 0 | 31 / 3 | 0.251 s | Includes incremental build; excluded | Passed |
| Parallel, one-minute trait | 10 | 31 / 3 | 5.367 s | 9.085 s | Passed |
| Parallel, no trait | 0 | 31 / 3 | 0.237 s | Includes incremental build; excluded | Passed |
| Parallel, no trait | 10 | 31 / 3 | 11.549 s | 14.948 s | Passed |

Each loaded cell started ten owned `yes` processes, ran a prebuilt test selection with a 90-second outer bound, and joined all workers in cleanup. All forty workers exited. No outer bound fired. Builds used two jobs and ran without this CPU load. No full suite was run.

The single-lane control is the existing `atStopTheAudioRunsAtOnceAndTheRestWaitsForIdle` scenario: real `MeetingServices`, `ProcessingScheduler`, `MeetingPipeline`, and file-backed `MeetingStore`, with fake model/audio services. It establishes progress for one pipeline under this load, not real-device performance or a cancellation-latency guarantee. The 31-test selection also includes the existing assertion that deferred work observes `.background` priority.

The loaded serialized sample at approximately 15 seconds shows an idle main actor and one active `com.apple.root.background-qos.cooperative` worker. Its stacks traverse the meeting pipeline/store and Foundation file creation, permission changes, atomic writes, `fsync`, `open`, and `rename`. This establishes filesystem work on a background worker during the slowdown; a sample alone cannot separate kernel I/O throttling, CPU scheduling delay, and filesystem contention.

## Confirmed timeout and production boundaries

- Bundled `Testing.framework` reports build 2084. Its `withTimeLimit` binary calls `withThrowingTaskGroup`, waits for a child result, calls `cancelAll`, and tears down the group. This directly verifies the race shape in the installed library; its commit getter returns no source revision. The public [Swift Testing implementation](https://github.com/swiftlang/swift-testing/blob/main/Sources/Testing/Traits/TimeLimitTrait.swift) has the same structure, but that mutable source is not claimed as the exact bundled revision.
- `ProcessingScheduler.tick()` explicitly launches deferred work with `Task(priority: .background)` and resumes a `withCheckedContinuation` when it finishes. Its comment explains why it avoids awaiting the task's value: that would raise the worker's priority. The unstructured task is owned by the scheduler, not by the caller of `tick()`.
- Cancelling a timeout's test-body task does not propagate into that scheduler-owned task. The body can therefore keep awaiting the continuation beyond one minute. Even an explicit `cancelRunning()` cannot preempt an already executing synchronous Foundation operation; cancellation is cooperative.
- Production requests cancellation separately: a recording transition calls `scheduler.cancelRunning()` in `MeetingServices.setRecording`, and both iOS background-expiration paths call it in `MeetingController`. The caller's cancellation of `tick()` is not the production stop contract. No missing production cancellation path was demonstrated here.
- Background I/O can also delay production processing: production uses the same synchronous file-backed stores at background priority. The local SDK's `dispatch/queue.h:654–659` explicitly documents throttled disk I/O for background-priority threads and maps that priority to `QOS_CLASS_BACKGROUND` at line 696. [Apple's documentation](https://developer.apple.com/documentation/dispatch/dispatch_queue_priority_background) describes this scheduling policy. These facts do not establish an indefinite production hang.
- One production scheduler admits one heavy job at a time. Parallel test scenarios instantiate independent schedulers and stores, multiplying background workers. `.serialized` removes that suite-level fan-out while retaining each scenario's explicit internal concurrency. It remains a defensible contention mitigation, not a guarantee of faster execution: today's serialized loaded control was slower than either parallel control.

## Mechanism and production verdict

Standalone probes (4 concurrent writers, 100 iterations each of a 4 KiB atomic write plus append plus `fsync`, the same operations `JSONLFile`/`MeetingStore` use), ten owned `yes` workers, ten-core Mac. Probe sources and runner: `docs/research/scheduler-load-61/run.sh [load]` (compiles `io`/`tk`/`dq.swift`, about 20 lines each).

| Probe | Unloaded | 10 CPU workers |
| --- | ---: | ---: |
| `Task` children awaited by a user-initiated task (priority escalated) | 0.06-0.10 s | 0.10-0.19 s |
| `Task.detached(priority: .background)`, awaited through a continuation (the scheduler's pattern) | not run | 4.40 s |
| `DispatchQueue.global(qos: .background)` / `.userInitiated` | not run | 4.30 s / 0.06 s |
| Whole process under `taskpolicy -b` | 0.39-0.60 s | 37.3 s (1 writer: 14.1 s) |
| Whole process under `taskpolicy -d throttle` (disk only) | 0.06 s | 0.06 s |

Conclusions:

- The slowdown is background QoS under CPU saturation (20-100x), not disk throttling alone: `-d throttle` is unaffected, `-b` and background-QoS threads are not. A background task that is awaited by a higher-priority task is escalated and shows no slowdown, which is why the scheduler avoids awaiting its job and why the effect appears only when nothing escalates it.
- The test suite explains the hang shape. Each parallel scenario owns a scheduler plus file-backed stores, so many background workers sit in synchronous `fsync`/`rename`, each pinning a cooperative-pool thread (pool size = core count). With the pool pinned by starved background threads, the test body, the timeout's sleep and the main actor wait for a free thread. Prior samples (8-10 blocked `background-qos.cooperative` workers) match this. It is consistent with, but was not reproduced as, the original persistent hang.
- Scheduler defects ruled out by code reading: the scheduler actor is suspended on a continuation while a job runs and holds no lock across I/O; `JSONLFile` actors hold only their own file across synchronous I/O (one instance per file); `append` writes whole lines, so a cancelled or timed-out caller cannot leave a half-written line (a crashed writer's partial line is repaired on the next append, and rewrites are atomic).
- Production cannot hit the suite's fan-out: one scheduler admits one heavy job, so at most one cooperative thread is pinned, and `cancelRunning()` is requested separately on recording and suspension. Deferred work is intentionally `.background`; enqueued jobs are gated by `IdlePredicate` (load under 0.30 for 30 s, or 60 s without input), so they rarely meet a saturated CPU. Only `perform` manual jobs run at `.userInitiated`. Forced and immediate jobs (`processNow`, and every meeting when idle processing is off, `MeetingServices.queueDeferred`) skip the idle gate yet still run at `.background` in `tick()`, so under heavy foreground load they can run 20-100x slower (one writer under `taskpolicy -b`: 14.1 s for 400 writes). That is slowness, not a stall; whether user-forced processing should run at a higher priority is a product decision, not a correctness fix.
- `.serialized` is sufficient for the tests: it removes the fan-out of simultaneous background workers (the 40-100x multiplier is per concurrently starved writer) while each scenario keeps its explicit internal concurrency. `.timeLimit` stays as a backstop only; it cannot interrupt a synchronous filesystem call.

Targeted suites with this tree (`LEGATO_STUB_DEPS=1 swift test --skip-build --filter 'MeetingServicesSchedulingTests|ProcessingSchedulerTests'`, 31 tests / 3 suites): unloaded 0.639 s; ten workers 9.843 s; under `taskpolicy -b` 1.626 s unloaded and 6.091 s loaded (119 s wall, since process start-up itself is starved). All passed; every owned worker exited.

Not established: the exact original trait-specific persistent hang (still unreproduced) and the original run-to-run difference between the trait and no-trait parallel variants.

## Reproduction and retained evidence

Build a fresh exported tree with `LEGATO_STUB_DEPS=1 swift test --jobs 2 --filter 'MeetingServicesSchedulingTests|ProcessingSchedulerTests'`; the unmodified suite uses `.serialized` and `.timeLimit(.minutes(1))`. For the parallel controls, change only that suite annotation in the exported tree, rebuild without load, and preserve every test assertion. Run each loaded cell through an independent process timeout and clean up only its own CPU workers.

Prebuilt selection:

```sh
LEGATO_STUB_DEPS=1 swift test --skip-build --filter 'MeetingServicesSchedulingTests|ProcessingSchedulerTests'
```

Single-lane selection:

```sh
LEGATO_STUB_DEPS=1 swift test --skip-build --filter atStopTheAudioRunsAtOnceAndTheRestWaitsForIdle
```

Local artifacts, which are temporary and not release dependencies:

- `/tmp/legato-scheduler-61-baseline.log`: cold build and unmodified baseline.
- `/tmp/legato-scheduler-61-matrix.py`: bounded runner with owned process-group cleanup and sampling at 15/65 seconds when a cell remains active.
- `/tmp/legato-scheduler-61-evidence/results.jsonl`: cell times, exit statuses, worker PIDs, and cleanup results.
- `/tmp/legato-scheduler-61-evidence/{serial-trait-load,one-lane-load,parallel-trait-load,parallel-no-trait-load}.log`: loaded test results.
- `/tmp/legato-scheduler-61-evidence/{parallel-trait-baseline,parallel-no-trait-baseline}.log`: annotation-only unloaded controls.
- `/tmp/legato-scheduler-61-evidence/serial-trait-load-15-94611.sample.txt`: background filesystem sample.
- `/tmp/legato-scheduler-61-evidence/bundled-timeout-disassembly.txt`: installed timeout implementation, including group wait/cancellation calls.

## Remaining acceptance

Explained: background-QoS starvation under CPU load (probes), why a structured timeout cannot stop scheduler-owned synchronous I/O, and why `.serialized` removes the suite's fan-out. Unexplained: the original hang's persistence after load was removed, and the trait/no-trait throughput difference; no probe exhausts the cooperative pool. No correctness fix is justified; forced-job priority under load is an open product question.
