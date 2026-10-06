# Native filter-state allocation validation

2026-10-06; source base `3545127`, dedicated worktree
`/home/dgamroth/workspaces/codex/pipewire/PipeWireAO-bootstrap-state`.
This is the SDK component of native owner-bootstrap review finding BOOT-R001.

`filter_state` keeps the existing callback-failure and closed-handle checks.
Healthy queries use the existing generated `pw_filter_get_state` binding with
its optional error output omitted. The native implementation in the PipeWire
workspace, `src/pipewire/filter.c:1657`, guards the output with `if (error)`.
On ERROR, the getter queries detail under the existing state lock, copies the
borrowed text before unlocking, and throws the existing `PipeWireError`.
If the second query observes a newer non-error state, that state is returned.
No public API, dependency, handle ownership or scientific code changes.

The unchanged focused test, after replacing only the getter with its original
body in a cache-only investigative process, produced **9 pass / 1 fail**:
1,000 warmed healthy state queries allocated 16,000 bytes. The same test with
the corrected getter passes **10/10**, including zero healthy bytes, native
error code/detail, retained callback-exception identity and closed handles.
The existing managed-filter, native-error and filter-buffer suites pass
**143/143**. Their usual `chunk_info_allocations` helper was loaded from the
full-suite source; running `filter.jl` alone without that helper produced a
fixture-only undefined-name error, retained separately.

Verification used Julia1.12.7 on CPU15 with the established deployment Manifest
copied to the ignored SDK Manifest, selecting installed PipeWireAO_jll1.7.0+19;
there was no dependency resolution/download or new build target. Retained
scripts and logs:
`~/.cache/rtc-native-owner-bootstrap-remedy-20261006/{sdk_filter_before.jl,filter_state_before.jl,sdk-filter-state-before.log,sdk_filter_proof.jl,sdk-filter-state-final.log}`.

Together with the runtime wake/facts remediation, the original reviewer’s
GC-enabled actual private-core oracle observes zero bytes and zero pool
allocations in both warmed quiet Connected500ms windows, matching its zero
baseline. That result is recorded in the RTC bootstrap design and
`idle-after-final.log`; it is not installed scientific/allocation/placement or
hardware qualification. Independent verification remains required.
