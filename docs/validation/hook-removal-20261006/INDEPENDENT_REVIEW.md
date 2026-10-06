# SDK SPA hook removal independent review — 2026-10-06

Verdict: approve the bounded primitive repair in commit
`2daa72c470959be2ff2e58d76a0986f1e911f1b9`. No blocking issue was found in
that commit. This verdict does not cover the subsequent registry tracking
API, its native fixture, or the full bootstrap seal.

## Scope and source identity

- Base: `d514d6b0d76a1dcac359ec23943876343b7bb205`.
- Reviewed commit: `2daa72c470959be2ff2e58d76a0986f1e911f1b9`.
- Worktree: `/tmp/pipewireao-sdk-bootstrap-seal`.
- Branch: `fix/bootstrap-registry-notifications-20261006`.
- Pre-existing worker changes: `src/PipeWireAO.jl`, `src/core.jl`,
  `test/runtests.jl`, and untracked `test/registry_tracking.jl`.
- No worktree files were modified by this review. This artifact is separate.
- The supplied global AGENTS instructions apply. No AGENTS.md was present
  in the SDK worktree, primary SDK checkout, or their ancestor directories.

Review examined the committed diff, committed test registration, generated
SPA layouts, native list/hook headers, listener ownership and loop-lock
contracts, and retained evidence. No Julia process, native fixture, GPU,
scientific workload, build, or new test was run. Static diff checking passed.

## SDK-HOOK-R001 — singleton alias lost update

Severity: high in the base revision. Confidence: high. Disposition: resolved
by the reviewed commit. Classification: observed failure evidence plus
independent source derivation.

Affected code: `src/listeners.jl:73`, specifically lines 79–84.

For removed hook X and head H, the singleton ring starts with
`H.next = H.prev = X` and `X.next = X.prev = H`. In the base revision both
neighbor snapshots were `(X, X)`. The first whole-struct store produced
`H = (H, X)`, but the second store reused the old following snapshot and
produced `H = (X, H)`. Clearing X then left the list head pointing at the
cleared hook.

The candidate loads following after storing previous. The following snapshot
therefore becomes `(H, X)` and the final store produces `H = (H, H)`. For
distinct previous P and following N, the writes remain `P.next = N` and
`N.prev = P`, preserving their other fields. This also handles removal from
the front, middle, or tail of a valid serialized ring. The change reproduces
the ordered scalar effects of native `spa_list_remove`, including the alias
case. The `spa_list` and `spa_hook` generated field order matches the C
layouts; the hook link is the first member.

Native authority inspected: installed artifact
`cee1f96f590a4ee6f4c25f6860648cda5d5ca225/include/spa-ao-0.2/spa/utils/list.h:69`
and `hook.h:457`, also matching the host SPA headers. Native hook removal
unlinks first and invokes the removed callback afterward, as this function
continues to do. The existing SDK zeroing and repeated-removal behavior is
unchanged.

Required validation: failure on the old singleton head-next invariant and
success on the same invariant after repair, plus preservation of both
directions for larger lists. Retained evidence satisfies that bounded
obligation: the old fixture reports `HEAD_NEXT_SELF false HEAD_PREV_SELF
true`, and `test/hook_removal.jl` reports 42/42 passing assertions. The test
roots the head and hook vector for its pointer operations, removes lists of
one, two and three hooks from the front, checks head and surviving endpoint
links, checks clearing, and repeats removal. It does not independently
exercise non-null removed callbacks or middle-first/tail-first ordering;
these are coverage limits, not blockers for this reordered load.

## SDK-HOOK-R002 — caller lifetime and serialization remain prerequisites

Severity: informational for this commit. Confidence: high. Disposition:
unchanged contract; native teardown validation belongs to the next increment.
Classification: observed source contract.

Affected code: `src/listeners.jl:9`, `src/listeners.jl:73`,
`src/listeners.jl:102`, and `src/thread_loop.jl:5`.

The primitive acquires no native lock. Its neighbor pointers must identify
live, consistent list storage, and mutation must be serialized with native
dispatch and owner destruction. `close(::ManagedListener)` preserves both
listener and hook across removal; the listener keeps its owner reachable.
Reachability alone does not prevent another execution context from closing
the native owner. The documented loop-thread/native-loop-lock contract is
therefore necessary. The Julia state lock does not substitute for the native
loop lock. This commit neither changes nor establishes concurrent close or
finalizer safety.

The earlier `registry_demarshal_global_remove` SIGSEGV is retained evidence
of a native crash, but does not identify a unique cause. The reported fixture
lock omission and singleton corruption are distinct mechanisms. No claim
that this primitive fix alone resolves the native crash is approved here.

## Evidence integrity

The hashes below were recomputed and matched `docs/HOOK_REMOVAL_VALIDATION.md`:

- `hook-singleton-before.log`:
  `dff243e8d7ee4aa8a86d578a2217950643dcec4b39c387d794eaf6633ff263f3`.
- `hook-removal-after.log`:
  `9f2615747e801fde0e3f448683245cf2f1edc0eea5f717cf130b9a54c14f1526`.
- `sdk-after-setup.log` (native crash evidence):
  `33b83144ffcdf4cdb511fc3fe7fce7c25273e68edd7c6cca63f5caab06db458b`.

All are under
`/tmp/gui-source-allocation-diagnostic-20261006/candidate-cold-tests/`.
These are retained implementation-run results, independently inspected but
not rerun by this reviewer. `git diff 2daa72c^ 2daa72c --check` passed.

No public-release, native system, allocation-budget, or hardware validation
claim follows from this bounded source review.
