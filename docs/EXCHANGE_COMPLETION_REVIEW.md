# Prepared ndarray exchange completion review

Review date: 2026-10-04. Independent static review of saved experiments and source; no additional live core, GPU, build, or application runs were launched by this reviewer. HEART diagnosis and remediation are outside this review.

The old packaged client has a confirmed buffer-return ownership defect that explains the controlled source-completion timeout. The deployed client implements the existing native fix and passes the unchanged exchange oracle twice. The smallest delivery remedy is to package the fixed native revision and make consumers resolve that package. Julia completion semantics and the oracle need no change on this evidence. The fresh JLL host artifact passes three unchanged-oracle runs and the ordinary package suite. JLL release assets and registry resolution are verified from saved evidence. Fresh registry resolution exposed a second gap: the registered Julia package lacks the prepared API. Publishing the existing API as PipeWireAO 0.6.13 and verifying that registered source remain pending. The instruction-set audit warnings are adjudicated below; they do not establish a native portability defect or broad architecture qualification.

## Scope and provenance

- Julia worktree: `/home/dgamroth/workspaces/codex/pipewire/PipeWireAO-exchange-completion`.
- Branch: `fix/ndarray-exchange-completion-20261004`; initial commit `aa50935feb6da3e24dc4ca71c8c05b443431a358`; clean initial tree, recorded in `preparation.json`.
- Native fix: `42fdf86f4e66b15e7cc1d22404294f2234dfcb85`, “Fix stream buffer ownership on return”. Prior JLL recipe revision: `d130d3afac6e81519dad019629c7ba245e6de34c`.
- Evidence directory: `/home/dgamroth/.cache/pipewireao-exchange-completion-20261004` (abbreviated `E` below). Failed build/control artifacts must be retained.
- Oracle: `test/ndarray_exchange_private_core.jl`, copied byte-for-byte to `E/unchanged-test.jl`; SHA-256 `45c26283bde6c921ba309c7b0051f4cefbbfe3d9297d0aae120b000425591d59` for both files at review.
- Runtime metadata: Julia 1.12.7, one Julia thread, PipeWireAO_jll 1.7.0+18 wrapper, unchanged Julia source and manifest dependency graph. Product preferences determine the actual binary; the wrapper version alone cannot establish fix presence.

## Preserved acceptance contract

The prepared source remains pending when no output buffer is available. It completes only after successful native queue publication. A source token acknowledges that publication; the independently armed sink must validate and capture the matching header, acquisition identity, duration, and payload. Wrong identity/sequence, unarmed/late input, disconnect, and duplicate delivery retain their rejection behavior.

The unchanged oracle exercises Float32, UInt16, and Bool; two generations of three sequences each; deliberately borrowed output buffers with a delayed return; exact receipt/payload assertions; failure cases; and the warmed source callback guard `@allocated(...) == 0`. The guard is scoped to that callback invocation. It is not an allocation claim about waits, timers, setup, all callbacks, or native libraries. The 10-second wait deadline is a functional timeout, not a measured real-time latency target.

## Saved experiment evidence

| Run | Actual selected client | Result | Evidence |
| --- | --- | --- | --- |
| deployed-baseline-1 | `/opt/pipewireao/lib/x86_64-linux-gnu/libpipewire-ao-0.3.so` | 133/133 pass, 10.3 s | `E/deployed-baseline-1.log`, corresponding before/after TOML |
| old-client-control-1 | artifact `8c1a3e9d3261ba839cf16f22202bbafdc9c38921/lib/libpipewire-ao-0.3.so` | 7 pass, 1 error; source completion deadline expires at oracle line 142 | `E/old-client-control-1.log`, corresponding before/after TOML |
| deployed-repeat-2 | same `/opt` client | 133/133 pass, 10.4 s | `E/deployed-repeat-2.log`, corresponding before/after TOML |

Client SHA-256 values:

- Old artifact: `94d1766ac2fed15748ad3fd1e9490ead36477eff479fc573ce119a1344d68255`.
- Deployed fixed client: `083da9b7c347a40e8ce03cc1332c06774cbf766fdd71fe36010233e6d9096387`.

The control changes only `libpipewire_ao_path`; both environments have semantically equal manifests. The product path and SHA records are unchanged between each run's before/after snapshots. `Libdl.dllist()` confirms the selected client and SPA AO library are loaded. The selected SPA AO and support products retain identical `/opt` paths and hashes across all three runs. The support product uses `dont_dlopen=true` and is absent from the saved Julia library list; its path/hash records demonstrate selection, not that Julia mapped it. The oracle uses the same absolute `/opt/pipewireao` daemon path and module/plugin prefix. The saved TOML does not independently enumerate the daemon's mapped modules.

The logs include precompilation notices about already loaded Dates, Printf, and TOML versions. They occur in both the passing baseline and failing control; no changed exchange implementation or weakened assertion accompanies the passing run. These notices do not explain the binary ownership defect.

## Findings

### EC-001 — Returned native buffers retain a stale loan flag

**Severity:** high. **Confidence:** high. **Disposition:** confirmed defect in the old artifact; existing native correction accepted; fresh host package and published JLL delivery verified.

**Observed:** Native `src/pipewire/stream.c` at the old recipe revision sets `BUFFER_FLAG_DEQUEUED` when lending a buffer and discards already-flagged entries during dequeue. Its return function reinserts the buffer but never clears that flag. The actual old client disassembly agrees: `pw_stream_return_buffer` at `0xfe520` decrements Busy if present and inserts at the queue front, without a flag check or clear (`E/old-client-return.asm`). Independent read-only disassembly of the same SHA-identified old binary shows `pw_stream_dequeue_buffer` tests bit `0x2` at `0xfe1aa`, branches to duplicate handling at `0xfe2d8`, and loops to pop another entry. This establishes the incompatible ownership operations in the actual artifact, rather than inferring its behavior from a source checkout alone.

**Derived mechanism:** The oracle borrows available source buffers before submitting sequence 2, then returns them after checking the source remains pending. The old native return makes those buffers visible in the ring while still marking them as lent. A subsequent dequeue consumes each ring entry as a duplicate. Available output capacity is lost, queue publication cannot occur, and the unchanged Julia source correctly remains pending until its deadline. A longer deadline or forcing completion would conceal the ownership failure.

**Observed correction:** Commit `42fdf86f4` checks ownership, clears the loan flag, decrements Busy only for output, and restores the loan flag/output Busy count when insertion fails. `E/deployed-client-return.asm` contains these operations: flag test/clear at `0xeb4a6`/`0xeb4aa`, direction check at `0xeb4b0`, and failed-insertion restoration at `0xeb4f0` and `0xeb519`. Both deployed runs pass the exact oracle that fails with the old actual client.

**Limit:** The control changes the entire client binary, not only this commit; six native commits separate the recipe revisions. The combination of isolated library selection, concrete source defect, matching binary instructions, expected failure location, and repeated unchanged-oracle passes gives high confidence in this mechanism. The supplied run is not an instruction-level trace of the failing dequeue and is not a one-commit binary bisect.

**Remediation:** Deliver the existing native fix through the JLL. Do not change the Julia exchange algorithm or the oracle for this defect.

**Required validation:** Fresh package selection and repeated unchanged-oracle passes, plus recorded native ownership regression outcomes, as specified below.

### EC-002 — Input return must preserve delivery Busy ownership

**Severity:** high for affected input-return use. **Confidence:** high from source and assembly; not established as the cause of this output-starvation experiment. **Disposition:** confirmed companion defect corrected by the same native commit.

Output dequeue acquires Busy ownership; input dequeue uses the ownership already attached to its delivery. The old return unconditionally decrements Busy when present, including input. Current return preserves input Busy until the buffer is queued back to its producer. Repeated return/dequeue cycles therefore retain the input delivery reference. Duplicate return is rejected, and insertion failure leaves the caller's loan intact. The fixed function contains no new allocation, retry loop, or blocking call on valid return; exceptional duplicate-return logging remains a separate path.

Native `src/tests/test-stream-buffer-return.c` specifies 128 return/dequeue cycles, both directions, with and without Busy metadata, duplicate-return rejection, subsequent queue behavior, and failed-insertion ownership rollback. Static review found the assertions consistent with the corrected ownership model. The primary agent subsequently rebuilt the current native revision and ran `pw-test-stream-buffer-return`: 1/1 passed with no failures or timeouts (`E/native-buffer-return-regression.log`). This reviewer inspected the saved result. This is pass-after evidence; the Julia old-client control supplies the fail-before evidence for the completion defect. The native build emits a null `%s` warning at unchanged `src/pipewire/conf.c:1138`; it is not a failure in the ownership regression and is not represented as corrected here.

### EC-003 — Source fix is absent from normal packaged delivery

**Severity:** high for consumers selecting the old artifact. **Confidence:** high. **Disposition:** recipe, fresh host package, published assets and registry JLL resolution verified; separate Julia API publication gap tracked in EC-005.

The prior recipe pins `d130d3afa`, which lacks the fix, while the deployed `/opt` binary demonstrably includes it. The reviewed recipe diff changes the source pin to `42fdf86f4` and preserves products, platforms, ABI/version family, and build settings. Product preferences can mask this delivery gap even when the wrapper still reports 1.7.0+18.

The smallest durable remedy is JLL 1.7.0+19 from the fixed native revision, followed by verified fresh registry resolution and an explicit update/restart requirement for existing environments. README now documents the prepared-path minimum and the distinction between daemon prefix and JLL product selection. A global +19 wrapper-version guard is not required to correct this native-only defect and would reject the fixed native installation already demonstrated with wrapper +18. The initial conclusion that no consuming release was needed applied to the native correction alone. Subsequent registry-only testing revealed that the already tested prepared Julia API had never been released under a distinct package version; EC-005 now requires a 0.6.13 API release for that separate delivery gap. Local Pkg 1.12.1 source maps `VersionBound(::VersionNumber)` to major/minor/patch only (`Pkg/src/Versions.jl:23`), so a build-specific compat floor cannot encode this requirement. The existing general +17 guard can remain. This accepts the normal dependency-update policy; it does not claim every historical locked manifest is repaired automatically. Such environments must update the JLL or explicitly select a native installation with the fix. Absolute `/opt` preferences remain a valid supported installation choice but do not prove portable packaged delivery.

No remote publication has been performed by this reviewer. Native `origin` is upstream GitLab and must not be pushed; native delivery uses the owner's `ao` fork. The recipe uses the owner's Yggdrasil fork, not upstream.

### EC-004 — Instruction-set audit warnings adjudicated

**Severity:** informational after investigation. **Confidence:** high for the identified instructions and dispatch paths. **Disposition:** initial unsupported-AVX512 hypothesis rejected for the client-node warning; baseline warnings explained by runtime-selected optimized variants and the same classifier limitation. No native change required for these warnings.

**Observed classifier limitation:** BinaryBuilder `YNHY8/src/auditor/instruction_set.jl:56–68` extracts only the mnemonic and counts its category. `instructions.json` assigns `vpgatherqd` solely to `avx512evex`; the classifier does not distinguish VEX from EVEX encoding. Independent scanning of the complete AVX2 `libpipewire-module-client-node.so` found exactly four instructions in the auditor's AVX512 categories, all `vpgatherqd` inside `do_port_use_buffers`. Their addresses and complete bytes are:

```text
18cd1  c4 e2 4d 91 04 3d 04 00 00 00
18ce3  c4 e2 4d 91 0c 2d 04 00 00 00
18d00  c4 e2 45 91 04 35 00 00 00 00
18d0f  c4 e2 55 91 0c 35 00 00 00 00
```

These are C4 VEX AVX2 gather forms with vector-mask operands. The primary agent reassembled the four operand forms with GNU assembler 2.44 using `as --64 -march=corei7+avx2`, with no AVX512 enabled. Independent disassembly and full-byte comparison of the saved object show all four 10-byte sequences match the packaged instructions exactly, including displacement bytes. Evidence: `E/avx2-client-node-classifier.json`, `avx2-client-node-isa-adjudication.json`, `avx2-gather.s`, `avx2-gather.o`, and `avx2-gather-encoding.asm`. Module SHA-256 is `f2e26602fb11c99a1fbd2b48d183d1ff91596ad4fe53d9e4047ba6c84c903e72`. The warning is an auditor classification false positive for these instructions.

**Baseline audioconvert:** Independent scanning of artifact `f2ee3863a816ed15f4b2ba6b378bdd5cf7a7b9ab` found the AVX512-classified hits are exclusively 18 `vpgatherdd` instructions: eight in `conv_s24_to_f32d_avx2`, ten in `conv_s32_to_f32d_avx2`. Each is C4 VEX encoded, again counted by mnemonic as `avx512evex`. `spa/plugins/audioconvert/meson.build` separately compiles the optimized AVX2 implementation. `fmt-ops.c:113,134` requires `SPA_CPU_FLAG_AVX2` for these two functions; `find_conv_info` checks that all required CPU bits are present (`fmt-ops.c:363–373`). `audioconvert.c:4633` obtains the runtime flags through the SPA CPU interface. Their presence in the baseline library is intentional multiversioning, not evidence that the baseline path executes AVX2 unconditionally.

**Baseline filter-graph:** The same independent scan found no AVX512-category instructions. Its AVX2-category hits are confined to `dsp_linear_avx2` and `dsp_mix_gain_avx2`; `audio-dsp.c` requires AVX2 plus FMA3 before selecting that method table and provides SSE/C fallbacks. `filter-graph.c:2557` supplies runtime SPA CPU flags or zero. The builtin plugin's AVX2-category hits are confined to `do_resample_full_avx2` and `do_resample_inter_avx2`; `plugin_builtin.c:992` carries the DSP CPU flags into the resampler, whose table requires AVX2 plus FMA3 and retains scalar fallback (`resample-native.c:215–235`). These source dispatch checks explain the optimized instructions in baseline packages.

Lower-than-requested optimization-tier notes are not unsupported-instruction evidence; CPUID warnings explicitly reflect the auditor's inability to infer runtime dispatch. This adjudication covers the reported warnings and inspected instruction/dispatch paths. It does not certify every instruction on every supported CPU or replace architecture-specific runtime validation. No lower-ISA live test or new build was run by this reviewer.

### EC-005 — Registered Julia package predates the prepared API

**Severity:** high for a fresh consumer of the requested API. **Confidence:** high. **Disposition:** confirmed independent package-publication gap; 0.6.13 release prepared and ordinary package tests passed, final registered-source exchange verification pending.

**Observed:** `E/published-resolution.toml` records fresh `Pkg.add("PipeWireAO")` selecting registered PipeWireAO 0.6.12 tree `763d28f2fe82fdadb4f704522e5c31067a78a7bc` and registered JLL 1.7.0+19 tree `6847e65abbe43442d82db075c13433bf63845b4f`, both from ordinary installed package paths, with no developed source. `published-default-one-thread-1.log` fails the unchanged oracle before any assertion with `UndefVarError: NdArraySource not defined`, at oracle line 100. The registered package's `src` directory has no `ndarray_exchange.jl` and contains no `NdArraySource` identifier. Its runtime metadata nevertheless selects the fixed host artifact and client SHA `803b6f58…`; saved observer evidence identifies the new daemon and confirms cleanup. This is a missing API failure, distinct from the old-client ownership timeout after seven successful assertions. Both failures remain preserved.

**Derived:** Checkout `aa50935` retains package metadata 0.6.12 but has source tree `4af52db39f45a10523db245ba6c8c8f4b0201785`, different from the registered 0.6.12 tree. The existing commits `d8fdb3e`, `3c84602`, and `aa50935` contain the prepared API, preconnection compilation, and zero-sequence handling already used by the successful source-checkout tests. A JLL-only release cannot expose missing Julia names in the older registered source.

**Remediation accepted:** Publish that existing tested API as PipeWireAO 0.6.13 with README requirements for the API release and fixed JLL. Relative to `aa50935`, the production change is only `Project.toml` version metadata; `src` and `test` have no diff. A new runtime guard or exchange algorithm change is unnecessary. `E/package-tests-0.6.13.log` confirms the ordinary suite passed using the relabeled source and JLL +19. Fresh registry-only resolution to 0.6.13 and repeated unchanged-oracle runs are the remaining gate; local development paths do not satisfy it.

## Ownership and publication assessment

| State/resource | Owner and transition | Ordering or serialization |
| --- | --- | --- |
| Native buffer loan flag | Application-facing dequeue sets it; queue or successful return clears it; failed return restores it | Ordinary field within the existing serialized stream operations; the fix does not make concurrent unsynchronized return/dequeue valid |
| Output Busy count | Successful output dequeue increments; queue or return decrements; failed return restores | SPA atomic increments/decrements use `__ATOMIC_SEQ_CST` |
| Input Busy count | Delivery retains its reference across return/redequeue; queue to producer releases it | Existing SPA atomic reference operations; input return performs no decrement |
| Dequeued ring IDs/read index | Return places the ID before publishing the reverted read index; dequeue consumes it | Ring index update uses release, foreign write-index observation uses acquire; the patch preserves the established ring protocol |
| Julia `StreamBuffer.handle` | Reusable wrapper gains a native loan; successful queue/return clears it; native error leaves the wrapper available | Stream state lock around native operation; outer thread-loop lock serializes explicit test loan/return with ordinary client callbacks |
| Julia phase and receipt | Source publishes complete after queue succeeds; sink publishes complete after receipt validation/copy and queue | Existing atomic phase, thread-loop serialization and condition notification; no publication or memory-order change proposed |

The C change repairs state transitions inside an established queue protocol. It does not establish a new general proof for arbitrary concurrent queue front insertion, graph recovery, or external callers violating the stream serialization contract. The Julia/C ABI and native buffer lifetime are unchanged. Julia wrappers release no native buffer memory; they clear their borrowed pointer only after a successful return status. Native failure remains a status translated by the wrapper; ordinary callback exceptions are captured by the exchange failure path.

## Verification gates and limits

1. Finish all five recipe targets: aarch64 glibc, untagged x86-64 glibc, and x86-64 baseline/AVX2/AVX-512 variants. Record source revision, build results, artifact hashes and failed attempts. Compilation is not runtime verification on each architecture.
2. Extract the fresh host-compatible artifact and inspect its exported return implementation or equivalent binary evidence for the corrected ownership operations.
3. Run the unchanged oracle repeatedly in fresh Julia processes with actual client, SPA AO/support products, private daemon, and module/plugin directories selected from that new package. Save actual loaded library paths/hashes and selection settings. An `/opt` success cannot stand in for this gate.
4. Preserve the old-client failing control and both deployed passing controls. Keep the zero-allocation assertion, exact receipts, deliberate no-buffer/pending check, duplicate rejection, and timeout behavior unchanged.
5. Record native ownership regression execution separately from static inspection. If fail-before/pass-after native evidence is available, retain its precise source revision and invocation; do not manufacture it from build success.
6. Record downstream resolution of the fixed JLL build with product overrides removed or explicitly accounted for. Verify that the resolved build contains the fix before claiming delivery complete.

These artifacts support functional completion and the scoped Julia allocation guard. They do not establish end-to-end latency distributions, worst-case timing, all-architecture runtime behavior, hardware validation, or HEART correctness. The later packaged observers capture affinity and full daemon maps; compiler/allocator and GC configuration remain outside a complete timing qualification. No broader timing claim is made.

## Post-build review

The following saved evidence was independently inspected on 2026-10-04 (local time; packaged run UTC timestamps are 2026-10-05):

| Gate | Evidence and disposition |
| --- | --- |
| Five target builds | Auditing remains enabled. ARM completes in v4, untagged x86 in v5, and three tagged x86 variants in v6. Failed disk/cache-install attempts remain saved. Warnings are retained and adjudicated in EC-004. |
| Artifact identity | SHA-256 recomputed independently for all five tarballs and matched against `built-artifacts.toml` and generated JLL `Artifacts.toml`. Git tree SHA-1 independently reconstructed from all installed artifact contents and modes; all match. Untagged and tagged baseline artifacts correctly share one identical tree. |
| Generated JLL | `PipeWireAO_jll-buffer-return` is version 1.7.0+19. Diff is restricted to `Artifacts.toml`, `Project.toml` version and README source/version; wrapper, platform and dependency code is unchanged. Source pin is `42fdf86f4`. |
| Packaged native operations | Host AVX2 tree `02332925c3953742006b7b962621affb654fc265`, client SHA-256 `803b6f58c11afb1c9354ca5216c309ab024d891129a5807c228c2c046ade37d9`. `packaged-client-return.asm` shows flag check/clear, output-only Busy release and failed-insertion rollback. |
| Repeated host functional tests | `packaged-one-thread-1`: 133/133, exit 0; `packaged-two-thread-2`: 133/133, exit 0; `packaged-one-thread-3`: 133/133, exit 0. Observer records show one thread on CPU 11 or two on CPUs 11,12; startup files disabled. |
| Actual runtime selection | All selected products and loaded client/SPA AO libraries come from the new host artifact. Before/after product identities match and hashes independently recheck. Observer removes prefix/module/plugin/library-path overrides; environment has no product preference file. No foreign AO paths appear in any retained daemon map. |
| Daemon/support identity | Saved daemon executable hashes and raw maps identify the same new artifact. Complete file lists for runs 1 and 2 are derived from retained raw maps; their map hashes, path sets and file hashes independently recheck. Run 3 records support plugin hashes directly. All three observers report no surviving daemon after cleanup. |
| Oracle preservation | Copied oracle still matches the repository test byte-for-byte. No production Julia or native algorithm changes form part of this delivery. Exact receipt and warmed zero-allocation assertions remain active. |
| Native regression | Current native source rebuild and ownership test pass 1/1; warning qualified under EC-002. |
| Ordinary package tests | `E/package-tests.log` resolves locally developed JLL +19 with unchanged PipeWireAO 0.6.12 and ends `Testing PipeWireAO tests passed`. |
| Published JLL delivery | `published-release.json` records the owner-fork +19 release, non-draft, with ten uploaded assets. `published-release-sha256.json` records independent downloads; this reviewer recomputed all ten local tarball/log-asset hashes and sizes and matched those records. Asset name sets match. `published-resolution.toml` confirms a registry-selected +19 source tree with no development path. |
| Registered API failure | Initial published run selects old registered 0.6.12 and fails 0 pass/1 error because `NdArraySource` is missing, with fixed native client selection and daemon cleanup retained. EC-005 confirms and separates this failure. |
| API 0.6.13 preparation | Only production version metadata changes against the tested `aa50935` checkout; ordinary package suite passes again. Final registry-selected 0.6.13 exchange runs pending. |

The host completion remedy and published JLL delivery are verified from the inspected evidence. EC-004 is adjudicated without a native defect finding. EC-005 adds the remaining delivery gate: publish the existing Julia API as 0.6.13, resolve it without development overrides, and repeat the unchanged exchange oracle. Architecture-specific runtime verification beyond the host remains outside the completed evidence. The primary validation record is [EXCHANGE_COMPLETION_VALIDATION.md](EXCHANGE_COMPLETION_VALIDATION.md).
