# Stopping native registry tracking

The public `stop_global_tracking!(registry)` API permanently detaches only the
SDK's built-in global-event listener. Cached globals become a historical
snapshot. The registry stays open, retains proxy ownership counts and refuses
close while bound proxies remain open. Independently added listeners are separate
resources and must be closed by their owner. There is no implicit resume.
ThreadLoop mutations are serialized internally; MainLoop callers retain their
normal owning-thread obligation.

## Reason for the API

An ordinary RTC source bootstrap discovers its controller before science starts.
The deployment supervisor retains that same controller through reset and Quit.
After admission it needs bound NodeInfo proof, removal and error events, rather
than every subsequent operator client's registry metadata. The existing global
callback copies metadata before application filtering. Stopping application
polling alone cannot prevent those allocations. This API permits explicit
listener retirement without closing the registry or its independently bound
controller proxy. Other registry users remain dynamic by default.

## Verification

The actual private-core fixture `test/registry_tracking.jl` passes 13 assertions:

- Repeated stop is harmless while open; the historical snapshot stays unchanged.
- A separately added listener still receives a newly exported native node.
- An already bound NodeInfo proxy still receives changed properties and node
  removal after tracking stops.
- Open proxy ownership still prevents registry close; after cleanup, stop on a
  closed registry rejects.

The new fixture is included in the standard package suite. CPU15 runs are
ordinary cold software tests with `RLIMIT_RTPRIO=0`, no scientific frames or GPU.
The prerequisite singleton-hook alias repair is recorded separately in
[HOOK_REMOVAL_VALIDATION.md](HOOK_REMOVAL_VALIDATION.md), worker commit `2daa72c`,
independently reviewed and integrated as `f7cfdaf`.

The SDK full-suite result and source/log hashes are retained in
`docs/validation/registry-tracking-20261006/receipt.json`. The RTC repository
records the external-controller allocation discriminator. That software
mechanism proof does not replace installed SCI allocation qualification.
