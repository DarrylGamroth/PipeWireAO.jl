# Prepared ndarray completion validation

## Scope and execution identity

This work qualifies prepared ndarray source/sink exchanges, including recovery
when all source buffers are borrowed. It leaves Julia exchange algorithms,
completion semantics, scientific data, timeout limits, and HEART unchanged.
These functional checks do not establish RTC cadence or latency.

Starting Julia commit: `aa50935feb6da3e24dc4ca71c8c05b443431a358`, clean checkout.
Worktree: `PipeWireAO-exchange-completion`; branch:
`fix/ndarray-exchange-completion-20261004`. Native fixed revision:
`42fdf86f4e66b15e7cc1d22404294f2234dfcb85`. Previous recipe source:
`d130d3afac6e81519dad019629c7ba245e6de34c`.

Raw evidence is retained in
`/home/dgamroth/.cache/pipewireao-exchange-completion-20261004`.
The unchanged integration oracle SHA-256 is
`45c26283bde6c921ba309c7b0051f4cefbbfe3d9297d0aae120b000425591d59`.
See [the independent review](EXCHANGE_COMPLETION_REVIEW.md) for ownership
analysis and its evidence limits.

## Controlled failure and deployed passes

All three runs use Julia 1.12.7, one Julia thread, CPU 11, one BLAS/OpenMP
thread, the same Julia source, frozen oracle, and dependency graph. The private
core, daemon modules, and plugins use `/opt/pipewireao`. The first and third
runs select all three JLL product paths from that installation through the
active environment's `LocalPreferences.toml`.

| Run | Selected native client | Result |
| --- | --- | --- |
| `deployed-baseline-1` | fixed `/opt/pipewireao` | 133/133, exit 0 |
| `old-client-control-1` | JLL 1.7.0+18 artifact client | 7 pass, 1 source-completion timeout, exit 1 |
| `deployed-repeat-2` | fixed `/opt/pipewireao` | 133/133, exit 0 |

The control changes only `libpipewire_ao_path`; the other product preferences,
private-core prefix, test, and environment are preserved. Selected client
paths and SHA-256 hashes are saved in each run's runtime TOML files, alongside
Julia's loaded-library list. The support plugin is a `dont_dlopen` JLL product;
its configured product path alone is not proof of a mapped library.

The older client's actual exported return function does not clear the
`DEQUEUED` flag. Its actual dequeue function rejects buffers still bearing
that flag. The existing native fix clears ownership on successful return and
restores it if insertion fails. The paired client comparison establishes the
packaging gap; it is not a one-commit bisection of all native changes between
those revisions.

The oracle retains exact receipts and payload checks for Float32, UInt16,
and Bool, generation/sequence validation, deliberately exhausted source
loans, duplicate/unarmed/wrong identity/late/disconnected rejection, and a
warmed successful source callback allocation assertion of zero bytes.
Setup, waits, exceptional paths, and complete application exchanges are
outside that allocation assertion.

## Native regression

`taskset -c 2-15 meson test -C build-revolt-classic-release
pw-test-stream-buffer-return --print-errorlogs` rebuilt the current source
and passed 1/1 native test. This executable checks 128 return/dequeue cycles
for input/output, with and without Busy metadata; duplicate return rejection;
queue publication; and failed insertion rollback for all four combinations.
Raw output: `native-buffer-return-regression.log`.

## Packaged delivery

The recipe pins the existing native fix and rebuilds all five published
platforms with BinaryBuilder auditing enabled. No upstream Yggdrasil or
native PipeWire publication is authorized. The generated JLL release is
`1.7.0+19` in `DarrylGamroth/PipeWireAO_jll.jl`.

All five release tarballs were rebuilt and their SHA-256 and unpacked Git
artifact trees checked. `built-artifacts.toml` records each identity. The
fresh host AVX2 artifact is `02332925c3953742006b7b962621affb654fc265`;
`packaged-client-return.asm` independently exposes the corrected return
ownership operations. Wrapper source, platform augmentation and dependencies
are unchanged by regeneration.

Fresh processes use a dedicated environment with locally developed JLL
1.7.0+19 and unchanged PipeWireAO 0.6.12 source. There are no product
preferences, prefix overrides, module/plugin overrides or artifact overrides.
The private core defaults to the new JLL artifact.

| Run | Julia threads / affinity | Result |
| --- | --- | --- |
| `packaged-one-thread-1` | 1 / CPU 11 | 133/133, exit 0 |
| `packaged-two-thread-2` | 2 / CPUs 11,12 | 133/133, exit 0 |
| `packaged-one-thread-3` | 1 / CPU 11 | 133/133, exit 0 |

Each run records selected product hashes and Julia's loaded libraries. An
external setup-only observer retains the private daemon executable hash,
complete `/proc/PID/maps`, and process identity; all three daemons are absent
after cleanup. Complete mapped-artifact hash lists for the first two runs are
derived separately from their retained raw maps in
`packaged-maps-derived.json`. The third observer records all mapped artifact
files directly. These include the support plugin as well as core modules.
External observation is for identity, not timing measurement.

The ordinary `Pkg.test("PipeWireAO"; allow_reresolve=false)` suite passed
1,506 assertions across 49 reported testsets with the developed JLL, two
Julia threads and CPUs 11,12. Raw output: `package-tests.log`. The standalone
133-assertion private-core oracle is separate from that suite.

Native compilation retains an existing `conf.c:1138` null-`%s` warning and
unused helpers from disabled desktop features. BinaryBuilder also warned of
AVX512 in the AVX2 client-node and baseline audioconvert modules. Independent
byte inspection and constrained GNU assembler checks establish that all 22
classified instructions are AVX2 VEX gather forms, reassembled byte-for-byte
with `-march=corei7+avx2` and no AVX512. The mnemonic-only auditor placed them
in its AVX512 category. Baseline audioconvert/filter-graph optimized routines
retain explicit CPU-feature dispatch and fallback. The warnings were
adjudicated; no vendor code or audit setting was changed.
`isa-encoding-validation.json`, `qualify_isa.py` and the independent review
retain this evidence. Cross-architecture runtime behavior remains untested.

## Publication and package API delivery

The own-fork JLL release `PipeWireAO-v1.7.0+19` is public with ten assets
(five binaries and five logs). All ten were downloaded again and match the
built assets by SHA-256 (`published-release-sha256.json`). JLL source commit:
`3d91d4cf5ec19336d418727acc7ee0c59670352f`; package tree:
`6847e65abbe43442d82db075c13433bf63845b4f`. Own Yggdrasil recipe commit:
`33032e430`; own registry JLL entry commit: `3bcdd21`.

The first clean `Pkg.add("PipeWireAO")` resolves published JLL +19 correctly
without developed paths (`published-resolution.toml`). Its unchanged oracle
fails before exchange: registered PipeWireAO 0.6.12, tree
`763d28f2fe82fdadb4f704522e5c31067a78a7bc`, lacks `NdArraySource`. This is a
separate API delivery gap: the prepared exchange implementation was already
committed on main, but not in the registered version. That failed result is
retained in `published-default-one-thread-1`, including mapped native identity
and successful daemon cleanup. It is not a repeated native completion timeout.

PipeWireAO 0.6.13 releases the already committed and tested prepared API from
main. Its new production diff is package version metadata; exchange code,
format preparation, completion semantics, exact oracle and allocation assertion
remain unchanged. A blanket JLL wrapper-version guard was not added: a fixed
native-library preference can supply this capability with an older wrapper.
The prepared path's required native revision/build is stated in the README.
Older locked manifests require an explicit dependency update and Julia restart.

The unchanged package suite also passes 1,506 assertions with the 0.6.13
release candidate (`package-tests-0.6.13.log`). Final registry-only exchange
results are appended after publication.

## Build resource record

The first build attempt lacked a direct BinaryBuilderBase environment
entry; the second needed the new native commit fetched into BinaryBuilder's
cached clone. Build attempts v3–v5 failed installing audit compiler caches after disk
exhaustion. All failed logs are retained; audits were not disabled. Completed
RTC and SPA Rust caches, an unused Julia 1.13 precompile cache, and completed
ARM/AVX2 audit compiler caches were removed. Source edits, installed plugins,
release binaries, runtime package artifacts, scientific evidence, and audited
release tarballs were preserved. The removal paths and rationale are recorded
in `build-cache-cleanup.json`. The ARM package passed in v4, the untagged
x86 baseline in v5, and the three tagged x86 variants in v6 (exit 0).
