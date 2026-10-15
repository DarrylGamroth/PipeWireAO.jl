# Acquisition Version 3 release review

Independent review, October 15, 2026. Native candidate 62a3aff803e5330d32a3a790e36fef69f2b35759
reviewed against existing main 9cf200645. SDK 0.6.18 candidate reviewed against 1417b69.
Review scoped to acquisition ABI, negotiation/admission, native validation and
publication, Julia borrowed metadata ownership, and the new SDK entry points.

## Native assessment

No release-blocking defect found in the acquisition diff. The metadata allocation
remains 96 bytes/alignment 8 with trigger classification in reserved2 at offset 88;
port and callback-buffer ABI layouts are unchanged. Native validators reject
unknown versions, malformed reserved bits, and out-of-range classifications.
V3 retains V2 timing/PTP semantics. Defaults and CURRENT remain V2. V3 ports require
a mandatory V3 feature; old libraries reject the unknown port flag at admission.
The current helper rejects missing V3 acquisition storage and incorrect payload
versions before callbacks/publication. Empty V3 outputs initialize an absent
classification. Existing bounds/alignment admission precedes metadata copies.

Native runtime evidence was supplied by the primary: 78/78 tests passing on the
candidate. This reviewer inspected the production diff and relevant tests, but
did not independently rerun the full native suite. Native protocol tests cover
shared-memory transport, not cross-host serialization or physical trigger timing.

## SDK-ACQ-001: cleared borrowed record compares stale fields

Severity: medium. Confidence: confirmed. Observed with the release candidate
native library through `docs/review/acquisition_validity.jl`.

Generalizing `acquisition_identity_equal`, `acquisition_time_difference`, and
`acquisition_times_match` to `NdArrayAcquisitionMetadata` added a second validity
source: the callback buffer's metadata_valid bit. These three functions called
native comparison helpers directly. `clear_buffer_acquisition!` clears the
callback validity bit while leaving the old acquisition bytes intact, so a
previously borrowed record still compared equal and returned an old PTP time
difference even though `acquisition_valid` was false.

Fix: require both records to satisfy `acquisition_valid` before native comparison.
Return false/nothing consistently with their existing invalid-record contract.
Validate tolerance before the early return to preserve negative-tolerance errors.
No new retained state or normal-path allocations are introduced.

Verification: before log reproduces all three incorrect comparisons; after log
passes 141/141 assertions (78 existing acquisition, 37 trigger, 11 borrowed record,
15 regression). The regression covers either operand invalid, both invalid,
valid comparisons, negative tolerance, and 0 B warmed comparisons. Existing tests
also verify output initialization with version 3 before its metadata_valid bit is
set: the native setter validates the initialized raw acquisition record, so this
ordering is safe.

Files changed by this reviewer: `src/stream.jl`, appended testset/helper in
`test/acquisition_trigger.jl`, and `docs/review/` evidence. No native source edit.
The runner sets only its process-local JLL library path to the specified native
candidate; it does not modify the depot or a production manifest. Final release
verification should also run the complete SDK suite with the actual JLL artifact.
