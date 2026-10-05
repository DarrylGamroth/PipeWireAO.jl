# Native owner-control infrastructure review

Date: 2026-10-05. Starting revision:
`5b217493dbaf7588412e21c186ef88140627f662`.
Worktree: `PipeWireAO-native-owner-control`; branch
`work/native-owner-control-20261005`.

The implementation and tests were already modified when this review began.
The reviewer changed only this document. Scope covers the generic Julia
run/reset wrappers, prepared Props/POD storage, stream parameter callbacks and
publication overloads. RTC source-owner state machines, report ownership,
scientific execution and live-control qualification are outside this review.
No GPU or user-session workload was launched.

## Conclusion

No confirmed production correctness blocker was found in the inspected generic
implementation. The existing native Version 1 run/reset schemas are reused.
The fixed-scalar Props helper encodes standard SPA parameters; semantic schema
validation remains the caller's responsibility. Batch publication coverage now
passes the independent private-core check recorded under NC-02.

This conclusion does not qualify an inclusive simulator-process live-control
interval. Moving control representation to native SPA does not by itself remove
report serialization, paused waiting or application-owned callback allocations.

## Evidence

The reviewer independently ran these four focused files with Julia 1.12.7:
`test/run_control.jl`, `test/pod_buffer.jl`, `test/props_buffer.jl`, and
`test/stream_param_overflow.jl`. All 474 assertions passed across eight testsets.
The tests include native ABI parsing, native prepared construction, alternating
buffer lengths, malformed and truncated Props, reordered fields, independent
allocating wire-format oracles and warmed allocation measurements.

The overflow test calls the registered `events.param_changed` C function pointer
on a self-core stream. It verifies rejection without buffer mutation or normal
callback execution, subsequent valid callback delivery, no recorded callback
error, and zero Julia heap allocation for warmed handled overflow. This is
stronger than measuring only the internal copy helper.

The separately inspected script
`/home/dgamroth/.cache/rtc-live-controls-20261005/probe_native_props.jl` uses an
owned private core and two client loops. Its saved
`native-props-prepared-probe.json` records request token 73 at the stream,
completion token 73 at the separate subscribed client, zero callback bytes and
zero prepared single-publication bytes. The script explicitly measures the
registered callback function pointer and retains the proper loop lock during
publication. The reviewer inspected this evidence without rerunning that probe.
It does not establish application command-adoption ordering or a batch snapshot
contract.

## Review observations and disposition

### NC-01 — Borrowed storage and native rooting

- Severity: informational. Confidence: high. Evidence: source and focused tests.
- Affected code: `src/spa_types.jl`, `src/spa.jl`, `src/stream.jl`.
- `PodBuffer` owns its bytes. The stream callback tuple retains the buffer;
  successful copying preserves the backing vector during the native copy.
  Capacity is checked before resize/copy, so handled overflow leaves it intact.
- The default callback path still supplies an owned copy. Prepared storage is
  opt-in and documented as borrowed only until callback return. A retained
  `Pod` wrapper does not extend the bytes' stable lifetime; callers must copy
  before reuse. One stream/caller owns each buffer, with no concurrent sharing.
- Both publication overloads keep the parameter owners alive across the native
  call. `PreparedParams` retains the POD tuple and its pointer vector, rebuilding
  pointers inside the state lock. Native `pw_stream_update_params` copies the
  parameter bytes synchronously into its own parameter records; it does not
  require the Julia storage to remain immutable after return.
- Disposition: accepted under the documented single-owner and stream-loop-lock
  contract. The state lock alone does not grant permission to call PipeWire
  from an arbitrary thread. Reusing callback scratch as outgoing mutable storage
  concurrently remains caller misuse.

### NC-02 — Prepared batch publication coverage

- Severity: medium validation gap, now closed. Confidence: high. Evidence:
  inspected tests, native `stream.c` implementation and independent private-core
  execution; no implementation failure was observed.
- Affected code: `PreparedParams` and its `update_params!` overload.
- Native update first clears each supplied parameter ID, then installs all PODs
  in the same call. Separate updates containing different `SPA_PARAM_Props`
  objects replace the preceding objects of that ID. A caller publishing run,
  reset and source status together must supply the complete intended set.
- Retaining and preserving the complete tuple is consistent with that native
  contract. It does not make delivery to all subscribers a transaction, or
  promise rollback if native publication fails partway through.
- Validation: the reviewer independently ran
  `timeout 90s julia --startup-file=no --project=. -e
  'include("test/native_control_private_core.jl")'`. All 17 assertions passed
  in 4.5 seconds. An owned private daemon and two independent client loops
  exercise empty, single, four same-ID Props and mixed PropInfo/Props sets.
  Every warmed publication measures zero Julia heap bytes. Enumeration matches
  the complete intended Props set, including after collection, prepared-buffer
  updates and republication. Unrelated EnumFormat and PropInfo remain intact.
- The test first completes a roundtrip on the publishing connection, then
  enumerates through the observing connection. A subscriber-only roundtrip does
  not order another client's pending publication; the earlier stale-observation
  fixture was therefore insufficient evidence of a production defect. The
  corrected synchronization is appropriate for this inspection test, and does
  not replace token-matched application completion.
- The extracted `test/private_core.jl` helper body is byte-identical to the
  previous helper in `test/ndarray_exchange_private_core.jl`; this review checked
  that extraction directly. The new test is included by `test/runtests.jl`.
- Disposition: closed by direct batch-publication evidence. The 474 earlier
  focused assertions plus these 17 assertions cover the generic increment;
  this review did not rerun the full package suite.

### NC-03 — Bounds and validation ownership

- Severity: informational. Confidence: high. Evidence: source and focused tests.
- Affected code: `src/run_control.jl`, `src/props_buffer.jl`.
- Constructors reject unsupported scalar types, duplicate/invalid names and
  invalid token/state ranges. Bool tokens/results are explicitly rejected.
  Prepared native builders reset their builder for every call and use bounded
  storage; insufficient capacity throws on the exceptional path.
- The generic parser validates the complete outer length, object and parameter
  type, sole params property, nested Struct extent, padded names and scalars,
  exact scalar sizes/types and field uniqueness before decoding. It bounds
  lengths before integer conversion and byte access. Destination assignment
  occurs after full structural validation. A rejected attempt does not prevent
  a later valid parse.
- Native run/reset parsers preserve the existing ABI error codes and may write
  partial destination fields on rejection; their documentation correctly makes
  the destination usable only on success. They consume a valid `Pod` container,
  not an arbitrary unbounded native byte pointer. Application code must not
  corrupt or resize owned/borrowed POD storage behind the API.
- Schema-version policy, token freshness, acquisition generation and causal
  completion belong to the eventual owner protocol. `parse_props!` deliberately
  does not impose these application meanings.
- Disposition: accepted. No speculative parser rewrite is requested.

### NC-04 — Allocation and error evidence has a defined boundary

- Severity: informational. Confidence: high. Evidence: measurements and source.
- Successful prepared parsing, construction and bounded callback copying pass
  warmed Julia heap checks. Opt-in overflow handling rejects the parameter and
  continues; the default overflow path remains a contained callback failure.
  Exceptions raised by the overflow handler use the same contained failure path.
- Native stream publication allocates native parameter records. The reported
  `@allocated` result measures Julia heap allocation, not libc allocation,
  kernel memory, subscriber work, bounded latency or real-time safety. The
  overload documentation states that native publication has its own costs.
- The overflow callback must stage a bounded rejection without throwing if an
  application requires nonfatal handling. Ignoring an oversized request is not
  an acknowledged application rejection; the caller still needs token/error
  semantics and a finite control deadline.
- Disposition: accepted scope; the later observer-allocation attribution is
  resolved by the final check below. The evidence must not be described as
  whole-system zero allocation or complete live-control qualification.

## Final allocation attribution and release-documentation check

The later full-suite run initially failed a prepared-publication assertion with
224 bytes. The preserved evidence is
`/home/dgamroth/.cache/rtc-live-controls-20261005/pwa-allocation-initial-224-failure.log`.
An unchanged focused test and an unchanged subsequent full run passed; those
passes alone did not explain the intermittent result.

The reviewer inspected `pwa-allocation-investigation.md`, the discrimination and
observer-lock logs, and the final fixture. Complete publisher calls and native
idle regions both recorded intermittent 224-byte increments while the independent
observer ran. Recorded allocation stacks originate in the observer's
`_node_info` / `_copy_node_info` path, including a property dictionary and
parameter-info array. Holding only the observer loop removed the measured
increments while retaining the full public publisher call. This evidence
supports observer attribution; it is not an inferred compiler defect.

The final `batch_publication_bytes` fixture acquires the observer lock outside
its measured region, then includes the complete `publish_batch` call inside
`@allocated`, including publisher-loop acquisition and native update. It releases
the observer before enumeration and retains all semantic publication checks.
There is no selected-minimum sample, changed byte threshold, GC disabling or
production source repair. This isolates a library operation in a fixture whose
observer otherwise shares process-wide counters. It is appropriate for that
operation's contract; it would not be appropriate for an inclusive application
measurement that actually includes its observer in the measured process.

The inspected final `pwa-allocation-focused-after.log` passes 17/17. The final
`pwa-allocation-full-after.log` ends with `PipeWireAO tests passed`; its 60 printed
testset summaries total 2009 passing assertions and contain no failed summary.
The investigation records CPU 14 placement and ordinary GC. This reviewer did
not rerun that full suite. Earlier independent 474-assertion and 17-assertion
runs remain historical evidence of their then-current fixture.

NC-04's allocation-attribution question is resolved within this library scope.
NC-02 remains closed for complete-set retention and prepared publication.
Neither disposition establishes whole-application zero allocation. The RTC
client's separate initial-join deadline investigation is not qualified by these
library results and remains outside this release review.

The final version declaration is 0.6.15. The README correctly describes native
Version 1 run/reset schemas, fixed scalar Props, borrowed callback lifetime,
optional handled overflow, owner-applied acknowledgement and native allocator
cost exclusions. Its example calls require the owning loop lock, as stated in
the following prose; showing that lock directly in the example would make this
precondition easier to preserve when copying it. This is a documentation
clarification, not a confirmed library correctness blocker. No additional
production remediation is requested by this final pass.

## Integration requirements outside this review

Keep native callbacks limited to bounded parsing and request staging. Apply
owner state changes only between completed frame/command exchanges, preserve
pause after adoption, and acknowledge a coherent owner observation with the
matching request token. Reset generation and stale-token handling remain owner
responsibilities. Prepared native status publication does not prove those
properties. Cold JSON reports may remain persisted evidence, but their timing
and ownership require a separate design decision before an inclusive
simulator-process zero-allocation claim.

## NC-005 — Do not register unused optional notifications

Date: 2026-10-05. Severity: high for the required inclusive simulator Julia-heap
budget. Confidence: high for the sampled callback attribution and the narrow
native-contract analysis. Disposition: targeted change verified by source,
saved full-suite results and the completed Classic FGN v9 lifecycle below.
Other live-control compositions remain unqualified by this finding.

### Observed failure and attribution

The unchanged failed v7 and diagnostic v8 acquisitions remain preserved under
`/home/dgamroth/.cache/rtc-live-controls-20261005`, abbreviated `E` here.
V7 records 329552 allocated bytes and 6675 pool allocations over 7936 measured
exchanges, with zero GC. The v8 diagnostic is separately identified by
`E/classic-fgn-native-profile-v8-allocation-stacks.json` and is not a replacement
qualification run.

Independent inspection of that 10%-sampled profile finds 654 events and 27337
sampled bytes. Of these, 653 events/27313 bytes across 449 stacks enter compiler
and ABI-converter work through `core_event_demarshal_remove_mem` and
`jl_get_abi_converter`. The remaining event is 24 bytes in
`_stream_command` / `_copy_pod`. No sampled stack attributes allocation to the
optics. Sampling does not prove absence of other allocations, nor can these
sampled bytes be equated with the whole-process v7 count.

Before the fix, `_core_events` registered `_core_remove_memory` even when
`on_remove_memory === nothing`. That Julia handler only invokes the optional
observer. `_stream_events` similarly registered `_stream_command` without an
observer; the handler copied the POD before attempting optional dispatch.
Thus the absent-observer configuration still entered Julia and, for commands,
constructed discarded owned data.

### Native contract and reviewed implementation

Native `src/pipewire/core.c` registers its own `core_events` listener when
constructing the core. Its `core_event_remove_mem` performs
`pw_mempool_remove_id` independently of the Julia observer. Omitting the Julia
notification does not omit native memory reclamation.

Native `src/pipewire/stream.c:impl_send_command` applies its Pause/Suspend/Start
state and IO work before emitting the command notification. Public `stream.h`
describes this event as a command notification. The native SPA hook dispatcher
checks callback presence. A null Julia notification therefore leaves native
command handling intact.

The inspected diff changes only these optional registrations: an absent
`on_remove_memory` or `on_command` selects `_NULL_CALLBACK`; otherwise it creates
the same typed `@cfunction` and invokes the existing handler. There is no native
ABI/schema change or resource-policy change. Mandatory state, error,
synchronization, process and trigger-completion registrations are unchanged.
Configured observers retain the original owned payload, dispatch and contained
error behavior. Avoiding absent-observer foreign entry is narrower than warming
an unused ABI trampoline and retaining its repeated notification overhead.

### Validation and limits

The added `unused native notifications` test checks that both default event
pointers are null. Existing core-protocol tests still configure and exercise
memory-removal observation; stream tests still configure command observation
through the registered events. Inspection of
`E/pwa-unused-notifications-full.log` finds 61 passing testset summaries,
2011 assertions and the final `PipeWireAO tests passed` message. There are no
failed summaries. This review inspected those results without rerunning jobs.

The completed `E/classic-fgn-native-v9-evidence.lifecycle.json` has
`success=true`, confirmed public shutdown and complete cleanup. Both primary
`run-1/sustained-result.json` and `run-2/sustained-result.json` report 8192/8192
completed frame/command exchanges and 7936 measured exchanges. Both intervals
record zero allocated bytes, pool/big/malloc/realloc counts, GC pauses/time and
full sweeps. Run 1 includes public midrun stop/resume and fresh status tokens 5
and 6 holding sequence 6136 in generation one; the saved-report cursor remains
zero and correctly reports `report-ready=false` while paused. Run 2 follows
stopped reset/restart. The lifecycle's retained frame and command hashes match
across both runs.

These are positive before/after observations for the targeted callback change
in one actual Classic FGN composition. They do not establish every source of
unsampled historical allocation, all Classic/Copper FGN/JFG cohorts, native
allocator freedom, hard real-time behavior or physical-device qualification.
The application still owns causal control completion and inclusive measurement;
this library change does not mask counters, exclude the pause interval or
move work into another simulator task.
