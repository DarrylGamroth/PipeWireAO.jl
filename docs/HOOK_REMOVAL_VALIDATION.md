# SPA hook removal validation — 2026-10-06

Starting SDK source: `d514d6b0d76a1dcac359ec23943876343b7bb205`, isolated
worktree `/tmp/pipewireao-sdk-bootstrap-seal`. This prerequisite arose while
implementing explicit registry tracking stop; it changes no public ABI or
pointer API, scientific code, or allocation budget.

## SDK-HOOK-001 — singleton head alias

Confirmed by a pure owned-SPA-list test. `_remove_spa_hook!` loaded both
neighbor structures before its stores. In a singleton list, previous and
following are the same head. The second whole-structure store restored the
old `head.next`, leaving it pointing to the cleared removed hook. The observed
before invariant was `HEAD_NEXT_SELF=false`, `HEAD_PREV_SELF=true`; the same
head-next assertion failed. No daemon or SCI was used for this proof.

The repair reads following **after** updating previous.next, reproducing the
ordered scalar effects of SPA list removal without changing structure layout.
The regression test covers one, two and three hooks; both head directions,
surviving link directions, cleared removed hooks and repeated removal. All
42 checks pass on Julia1.12.7, CPU15, offline, existing compiled modules.
`test/runtests.jl` includes the test. `git diff --check` passed.

An earlier actual registry fixture ended with SIGSEGV in
`registry_demarshal_global_remove`. Its independent managed-listener close
also lacked the native loop lock; that fixture is corrected separately.
The singleton defect is independently confirmed, but this document does not
uniquely attribute that crash to one of those two conditions. Actual registry
stop/proxy-removal validation belongs to the subsequent feature increment.
No native core, GPU or science execution was added for this primitive fix.

Commands used the warm installed project and a LOAD_PATH override selecting
this exact SDK worktree, not a package resolve or shared-source edit:

```sh
prlimit --rtprio=0:0 taskset -c 15 env JULIA_PKG_OFFLINE=true \
  OPENBLAS_NUM_THREADS=1 julia --startup-file=no --compiled-modules=existing \
  --project=/tmp/classic-jfg-sdk-interrupt-final-v1-installed/julia \
  -e 'pushfirst!(LOAD_PATH,"/tmp/pipewireao-sdk-bootstrap-seal"); using PipeWireAO; include("/tmp/pipewireao-sdk-bootstrap-seal/test/hook_removal.jl")'
```

Retained evidence hashes:

- `/tmp/gui-source-allocation-diagnostic-20261006/candidate-cold-tests/hook-singleton-before.log`: `dff243e8d7ee4aa8a86d578a2217950643dcec4b39c387d794eaf6633ff263f3`.
- `/tmp/gui-source-allocation-diagnostic-20261006/candidate-cold-tests/hook-removal-after.log`: `9f2615747e801fde0e3f448683245cf2f1edc0eea5f717cf130b9a54c14f1526`.
- `/tmp/gui-source-allocation-diagnostic-20261006/candidate-cold-tests/sdk-after-setup.log`: `33b83144ffcdf4cdb511fc3fe7fce7c25273e68edd7c6cca63f5caab06db458b`.
