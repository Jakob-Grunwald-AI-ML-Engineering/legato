# Scheduler load investigation — issue #61

The 2026-10-29 controls did not reproduce the earlier parallel timeout hang. Both parallel variants passed under ten CPU workers; the variant with `.timeLimit` finished faster in this sample. The specific trait/load throughput interaction remains unresolved, and #61 remains open. No production priority or cancellation behavior changed.

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

The earlier trait-specific hang and its persistence after CPU load was removed still need a reproducible causal explanation. These controls establish progress in the current one-lane fixture and confirm why a structured timeout cannot forcibly terminate this scheduler-owned work. They do not exclude intermittent production delays or settle the original throughput difference. Retain the suite mitigation and keep the unresolved acceptance criteria open; no production fix is justified by today's evidence alone.
