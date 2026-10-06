# Registry retirement and bootstrap sealing review — 2026-10-06

Verdict: approve the SDK API and the reviewed RTC commit
for paired integration. No blocking source defect was found. Installed
scientific and inclusive allocation qualification remains a separate gate.

## Source identity and scope

SDK commit: `dbc377e6c6c37a86f658c08cdb145fc167933309`, based on independently
reviewed hook repair `2daa72c470959be2ff2e58d76a0986f1e911f1b9`. SDK worktree:
`/tmp/pipewireao-sdk-bootstrap-seal`, clean at review.

RTC commit: `7efd4327ea4420e7d1c9103ea877d6fcb787230f`, base
`a31b6529d67ea7da3dabedf029f9b548bbf2794e`, worktree
`/tmp/pipewireao-rtc-bootstrap-seal`. The complete production source hash pair:

- `deployment/julia/src/native_control_endpoint.jl`:
  `230d06ed0f2fc8e2392b96e8c7f51ad8fa059bb15a374f30760a69bd4f157e98`.
- `deployment/julia/src/native_owner_bootstrap_runtime.jl`:
  `472138a3128c6a693763f63f170ac66a3517b25a1c38d8b45ddc3169530185d4`.

RTC source and evidence work were initially uncommitted and owned by the
implementation worker. Before completing this review, the worker froze commit
`7efd432`; its production hashes match the independently reviewed checkpoint
and its worktree is clean. This review changed neither worktree.

The review followed the supplied global instructions, RTC AGENTS.md, the
`review-low-latency-design` skill and its checklist. It examined the active
RTC-ARCH-024 / RTC-DEV-030 boundaries, the approved bootstrap design change,
production source, test source, retained logs, and SDK receipt hashes. It did
not start a Julia process, private core, GPU, scientific workload or build.

## Contract and ownership trace

The bounded performance objective is to remove ordinary source-bootstrap
registry discovery allocations after successful Connect, while preserving
the exact retained controller's authority checks and cleanup. This is a
whole-process interference mechanism within the existing science allocation
boundary; it establishes no latency percentile, offered-load or real-time
guarantee.

```text
native registry / bound NodeInfo / proxy events
  -> native ThreadLoop, serialized by its native mutex
  -> one endpoint pending ticket and atomic wake hint
  -> reserved monitor thread 2 checks identity/deadline
  -> main thread 1 performs actual connection or scientific cleanup
  -> locked main/monitor facts
  -> monitor seals discovery, then publishes lifecycle and completion
  -> main observes completed Connect before source frame loop
```

The registry cache and endpoint/controller state are separate from bound
proxy event lists. SDK registry state uses its own lock; all RTC mutations
that can race native callbacks use the ThreadLoop lock. The main/monitor
handshake uses `runtime.lock`; cancellation and wake are atomic. Sealing does
not add a request queue or expand the one-ticket capacity. The retained set
shrinks from the existing maximum of 32 candidates to one controller.

## REG-SEAL-001 — registry retirement preserves independent native ownership

Severity: informational. Confidence: high. Disposition: accepted.
Evidence class: observed source and retained software tests.

Affected code: SDK `src/core.jl:1345–1382`, `src/listeners.jl:73–113`,
`test/registry_tracking.jl`.

`stop_global_tracking!` takes the native ThreadLoop mutex before the registry
state lock and callback-state lock. It requires an open registry, transitions
`active` to false once, and removes only the built-in hook while preserving
the registry and hook across the pointer operation. Repetition observes
inactive state and performs no second unlink. MainLoop callers retain the
documented owning-thread obligation.

The registry handle, proxy count, callback cache and independent managed
listeners survive. Bound proxies retain their separate native listeners and
their parent registry. Registry close still rejects while proxies are open.
The hook alias prerequisite is required: RTC first removes its independently
owned hook, then the SDK removes the remaining singleton built-in hook.

The API and `globals` docstrings explicitly make the retained cache historical.
There is no implicit resume. New generic registries remain active by default.
The early `active` check prevents unnecessary copying if an inactive callback
is invoked; native serialization is what excludes an in-flight callback
during ordinary ThreadLoop detachment.

Required validation is present in the retained 13-assertion native fixture:
idempotence, unchanged cache, an independent listener still receiving a new
node, retained NodeInfo property updates and removal, proxy ownership and
closed-resource rejection. Full SDK logs report 2087 assertions in 65 sets.

## REG-SEAL-002 — Connect completion orders source admission after sealing

Severity: informational. Confidence: high. Disposition: accepted.
Evidence class: derived from inspected source; supported by cold lifecycle tests.

Affected code: RTC `native_owner_bootstrap_runtime.jl:383–401`,
`native_control_endpoint.jl:199–220`, `native_owner_bootstrap_runtime.jl:282–292`,
and `deployment/hil/simulator_owner.jl:448–478`.

The monitor enters the new branch only after an accepted Connect and actual
main readiness. It rechecks the applying ticket under the native mutex,
closes the independent registry listener under that mutex, closes other
controller proxies, keeps exactly the accepted identity, stops SDK tracking,
then records the retained identity. Other profiles never call this method.

Both detachment operations finish before Connected lifecycle or success
completion is published. Publication is not one indivisible operation: the
native mutex is released between sealing, lifecycle publication and completion.
This is safe for source admission because the sole pending ticket remains
occupied, completion rechecks controller and deadline, and the source's
`await_connected!` requires Connected plus retirement of that exact pending
ticket. A failure during this interval enters the existing fault/cancel path;
the source cannot proceed merely from the lifecycle label.

Closing other candidates and detaching are irreversible for that endpoint.
Failure therefore terminates the bootstrap rather than trying to reopen
discovery. This agrees with the approved no-reconnect/no-retry behavior.

## REG-SEAL-003 — retained controller revocation remains live

Severity: informational. Confidence: high. Disposition: accepted.
Evidence class: observed source and retained software tests.

Affected code: RTC `native_control_endpoint.jl:60–85`, `:169–190`,
`:357–370`; `native_owner_bootstrap_runtime.jl:99–113`, `:432–508`.

Skipping registry refresh does not suppress the retained bound Node's full
NodeInfo proof, removed or error callbacks. Those callbacks permanently clear
verification/mark retirement and publish the endpoint, setting its wake flag.
The monitor additionally checks retained-controller presence on every duty
cycle, even with no wake or pending request. Core errors set endpoint failure;
quiet operational checks also reject a stopped loop or disconnected filter.
There is no refresh path that silently recreates a retained stale controller.

Every accepted effect still checks the exact controller and absolute deadline.
Pending Connect failure precedes sealing; pending Quit expiry/removal faults
and cancels through the existing cleanup path. A controller that disappears
after successful Connect also cancels the owner. This does not promise
instantaneous zero-latency cancellation: it retains the existing monitor
polling/cleanup model and native event delivery dependency.

The final retained fixture exercises proof change, node removal, client
connection close, pending Quit expiry/removal, retained Status/Quit, foreign
discovery rejection and cleanup. Existing Connect expiry/removal tests also
passed in the retained regression run.

## REG-SEAL-004 — compatibility and scope limits

Severity: informational for paired integration. Confidence: high.
Disposition: accepted with explicit integration conditions.

Affected code: RTC `native_control_endpoint.jl:132–136`,
`deployment/julia/src/deploy.jl:947–950`, `:1331–1336`, `:1414–1420`,
and `deployment/julia/Project.toml`.

`retained_controller` defaults to `nothing`; the only call to retention is the
ordinary bootstrap Connect path. Generic native endpoints continue refreshing
their controllers. The public supervisor remains dynamic, while deployment
stores the bootstrap client by owner role before Connect and retains it through
SourceControl operations and terminal Quit. Its cleanup finally closes those
clients. No rebind has been introduced.

The intentional bootstrap behavior change rejects new independent direct
controllers after successful Connect. Exact retained identity is permanent
until endpoint teardown; this is not a wire-format change. GUI/operator
interaction continues through the public supervisor.

RTC now requires the SDK implementation of `stop_global_tracking!`, although
its compatibility range still permits older PipeWireAO 0.6.16 builds without
that symbol. Approval therefore applies to the paired source installation
with the recorded SDK revision, not arbitrary older SDK installations. A
separate public release would need a dependency/version decision; none is
authorized or claimed by this review.

## Validation evidence and remaining gate

Independently inspected retained results:

| Evidence | Result | Claim supported |
| --- | --- | --- |
| SDK full suite | 2087 / 2087, 65 sets | SDK regression coverage |
| SDK final include fixture | 13 / 13 | Corrected helper guard and registry/proxy behavior |
| RTC final regression log | 232 / 232, 10 sets | Retention, old bootstrap/deadline behavior, quiet checks and generic endpoint coverage |
| Foreign-controller churn before | 8 pass / 1 fail; 3,765,232 bytes | Old zero-byte oracle fails under actual external churn |
| Foreign-controller churn candidate | 9 / 9; zero bytes and zero GC | Same bounded cold mechanism oracle passes |

The final RTC regression total includes retained authority 66, bootstrap 49,
quiet allocation 12, and generic profile/endpoint/fault suites 105. The earlier
46-assertion seal result is superseded by the 66-assertion fixture. The full
SDK run's duplicate test-helper include warning was corrected with a guard;
the exact final include path passes without that warning.

RTC logs inspected under
`/tmp/gui-source-allocation-diagnostic-20261006/candidate-cold-tests/`:
`rtc-final.log`, `rtc-sealed.log`, `churn-before-valid.log`, and `churn-final.log`.
The before log preserves the failed unchanged zero-byte assertion; the final
churn log shows actual publication/removal timestamps inside the owner window
and `CLEANUP_CONFIRMED`. Tests use external peers, so their allocations are
outside the owner's process measurement. The test is a bounded cold experiment,
not a bound for arbitrary client traffic or every previous scientific allocation.

All five source hashes and all three log hashes in SDK
`docs/validation/registry-tracking-20261006/receipt.json` were recomputed and
matched. All five source hashes and all ten evidence hashes in RTC
`docs/validation/bootstrap-seal-20261006/receipt.json` were also recomputed and
matched. Source diffs were inspected and whitespace checks passed. No worker
tests were rerun by this reviewer.

Before a complete GUI handoff, the primary must install the paired SDK/RTC source and
complete the unchanged scientific trajectory/reset/death/picker and inclusive
allocation gates. This review provides source and cold-software acceptance;
it does not replace those installed results or establish hardware qualification.
