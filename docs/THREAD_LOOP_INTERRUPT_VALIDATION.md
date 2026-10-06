# Native thread-loop interrupt ownership

Validated on 2026-10-06 with Julia 1.12.7. Starting revision:
`6e4e1eebf8bd160f01a532dcfc7284dec92de61b`; initially clean dedicated worktree
`PipeWireAO-bootstrap-state`, branch `fix/thread-loop-interrupt-scope-20261006`.

## Observed defect and repair

A pending SIGINT can be delivered when the GC-safe native mutex acquisition
returns. Previously acquisition preceded the unlock `try/finally`, leaving
native ownership and the reserved access count unreleased. A child-only fixture
signals its exact owned process after a native callback records a reserved
acquire. The original method fails: two assertions pass, three fail, and the
access count remains one. The repaired method passes all five assertions,
returns the count to zero, permits a different OS thread to reacquire the mutex,
and closes normally.

`Base.disable_sigint` now covers reservation, acquisition, the callback, unlock
and count cleanup. The callback must remain bounded; its explicitly thrown
exceptions still release ownership. GC-safe acquisition remains enabled.
GC is not disabled. Recursive locks and nested callback exceptions retain the
correct access count.

Putting the complete body inside the SIGINT closure initially introduced
16–64-byte boxes of immutable `PreparedParams` in prepared publication calls.
The unchanged private-core fixture passed 17/17 before that change and failed
five allocation checks afterward. Keeping the protected body in an ordinary
private helper restores all 17 checks, without tuning annotations, changing
parameter storage, or using internal signal primitives. The independent
investigation is retained in the RTC repository's
`docs/THREAD_LOOP_INTERRUPT_REVIEW.md` and its associated validation directory.

## Verification

Final production-source checks:

- Full `Pkg.test(; julia_args=["--threads=2,0"], allow_reresolve=false)`:
  **2,032/2,032 assertions across 63 test sets**, including Aqua.
- Prepared lock allocation, returns, explicit exceptions and recursive counts:
  **10/10**; 1,000 warmed lock calls allocate **zero bytes**.
- Exact-process SIGINT ownership and cross-thread reacquisition: **5/5**,
  independently repeated on CPU15.
- Prepared parameter publication on a private core: **17/17**, with unchanged
  zero-allocation requirements.
- Existing GC participation child probes, `lock` and `stop`: both exit zero
  with their expected completion witness.

Root checks use CPU11; the independent check uses CPU15. No scientific stream,
platform tuning, native ABI change, or latency benchmark is part of this proof.
The full suite used the existing offline resolved dependencies and retains its
stale-manifest warning; no dependency resolution was performed.

The [receipt](validation/thread-loop-20261006/receipt.json) records source and
log hashes. Failed tests remain retained alongside the successful final suite.
This proves the library defect and repair. It does not establish that the same
mechanism caused the earlier installed service failure; repeat that service
against a freshly sealed package before reporting its cleanup gate as passed.
