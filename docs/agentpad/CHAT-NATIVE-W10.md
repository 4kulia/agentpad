# W10 full regression and scroll continuity

Owner decision, 2026-11-08: W10 accepts functional continuity at any recorded
load. The four native workloads must contain exactly 1,360 valid moving events
and zero jumps at the unchanged 0.75-point threshold. Supplemental workloads,
full Chat media-order and AX regressions, and the applicable repository gate
must pass, allowing only documented baseline failures. There is no timing
benchmark gate, load wait, three-repetition requirement or 16 ms outlier verdict.
This supersedes the historical controlled protocol in the specification and the
W09 document's reference to that performance gate.

The production timeline remains legacy. The native renderer uses the existing
test-only opt-in seam. W10 adds no product rendering or feature flags.

`scripts/bench-chat-scroll.py` uses the W00 fixture manifest and the shared
`ChatScrollMounted.event` driver. The default is one complete functional run of
SwiftUI reference → hosted reference → native product. Optional additional
diagnostic repetitions retain the historical renderer rotation; every repetition
is checked independently and event samples are never pooled across repetitions.
The hosted control is test-only AppKit table infrastructure with SwiftUI rows,
derived from the archived hosted experiment; it is never called native.

Each renderer/repetition has separate fresh processes for first mount, primary
events, dense reactions and decoded images. All use `scripts/test-quiet.py` with
isolated state and invisible, silent containment. The primary process executes
the four unchanged cases: 480 mixed channel, 480 mixed thread, 200 media channel
and 200 media thread events. The supplemental workloads each contain 400 events.
Async image preparation completes before the synchronous gesture driver.
Descriptor construction generates attachment UUIDs; benchmark children replay
those two identities from the frozen W00 fixture and assert every other
descriptor field already matches. The report compares complete fixture values
without stripping identities or changing the archived hashes.

Example (supply existing absolute evidence paths):

```sh
python3 scripts/bench-chat-scroll.py --run-root "$RUN_ROOT" \
  --reference-manifest "$REFERENCE_MANIFEST" --prepare-only
python3 scripts/bench-chat-scroll.py --run-root "$RUN_ROOT" \
  --reference-manifest "$REFERENCE_MANIFEST" --resume --wait-only
python3 scripts/bench-chat-scroll.py --run-root "$RUN_ROOT" \
  --reference-manifest "$REFERENCE_MANIFEST" --resume --wait-seconds 0
python3 scripts/bench-chat-scroll.py --run-root "$RUN_ROOT" \
  --reference-manifest "$REFERENCE_MANIFEST" --report-only \
  --report-output "$NEW_REPORT_PATH"
```

The first command requires a new root outside the checkout, freezes sources,
reference files and machine details, and builds once. Resume verifies source and
binary hashes. Wait-only uses one foreground command with 120-second console/disk
polls and at most 480 seconds of waiting per invocation; repeat exit 75. It never
waits for lower load. Console waiting is recorded cumulatively across resumes.
A failed data/continuity batch requires a fresh run root; a console/disk rejection
can be resumed and remains in the ledger. The acceptance-contract marker prevents
resuming or declaring historical controlled roots accepted under the new rule.
Keep their wait history and rejected attempts as historical evidence.
Interrupted attempts are retained as rejected. Termination drains the private
session created for the fixed quiet Python → Swift → XCTest command chain,
including additional process groups in that session. Real session IDs and
microsecond process-start identities are checked; each signal target and result
is retained. Observed session escapes, premature root exit, surviving-child
parent loss and uncertain identity reject cleanup verification. Resume requires
that verification and empty recorded groups; it never signals a recovered PID.
Polling does not prove the absence of an unobserved, fully detached process;
verification is limited to the private-session contract. Scoped
limits that omit any required batch cannot produce a workload PASS.

Every launch checks disk space and explicitly unlocked console state. Benchmark
preflight, five-second samples and the final observation record all three load
averages and require an explicitly unlocked console and at least 3 GiB free.
Missing or nonfinite load records fail validation; high recorded load does not.
Functional builds/tests require an unlocked console. Only owned process
groups may be stopped. The runner never changes owner settings or other jobs.

`chat_scroll_report.py` recomputes verdicts from raw records. It checks test
identities/counts, active quiet evidence, observation coverage, exact signatures,
fixture/settings equality, finite values, anchor arithmetic, native reuse/cache
bounds and source/binary identity. Each native primary repetition must have
exactly 1,360 valid moving events and zero errors strictly above 0.75 points.
Each native supplemental workload must contain 400 valid moving events and zero
jumps. Controls retain their measured diagnostics; data/environment validity is
required for every renderer. Reports require a new output path and label timing
statistics as diagnostics. A workload PASS is separate from the full Chat and
repository regression results retained with the evidence package.

Mount time/RSS and separate supplemental timing statistics are diagnostics. The
percentile algorithm remains `sorted(values)[floor((n - 1) * p)]`; phase-end
records stay in raw JSON and are excluded only from moving-event statistics.
No timing outlier is removed. This measures main-thread busy wall and thread CPU
under normalized quiet scrolling. Sampled load, synthetic decaying events and
quiet AX tests do not prove continuous load, frame presentation, GPU cost,
hardware momentum or a VoiceOver walkthrough. Hardware/VoiceOver validation is
required before release and W11 switch-over remains separate.

Guard tests: `TMPDIR="$GUARD_EVIDENCE" python3 scripts/test-chat-scroll-benchmark.py`
(create the external directory first). Process tests retain their ownership and
signal ledgers, including on failure; bounded fixture children expire naturally
and fallback cleanup never signals remembered numeric PIDs. Native regression:
`python3 scripts/test-quiet.py --log-dir "$CHAT_LOG" --filter Chat`, then the
applicable full repository gate through the same quiet runner. Keep the full Chat
native media-order and accessibility-scroller results with the benchmark package;
W09 parity is revisited only for product tuning changes. Evidence, raw logs and
reports remain outside version control. Remove job-owned build products after all
owned descendants have exited.
