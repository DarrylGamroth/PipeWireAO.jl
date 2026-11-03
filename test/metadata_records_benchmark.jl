# Run in the source-validation environment; timed work includes clock overhead.
# Setup, warmup, sample storage and reporting are outside the allocation budget.
using PipeWireAO
function fixture(bytes,count)
    required=(MetadataRequirement(SPA.META_HEADER),MetadataRequirement(SPA.META_ACQUISITION_IDENTITY),MetadataRequirement(SPA.META_EXPOSURE_TIMING))
    base_bytes=sum(r -> Int(r.size),required)
    opaque=count-3
    entries=[r.type=>zeros(UInt8,Int(r.size)) for r in required]
    for i in 1:opaque
        size=i==opaque ? bytes-base_bytes-8*(opaque-1) : 8
        push!(entries,UInt32(0x900+i)=>zeros(UInt8,size))
    end
    return MetadataSnapshot(entries)
end
function update!(metadata,identity,timing)
    initialize_metadata!(metadata)
    set_acquisition_identity!(metadata,identity)
    set_exposure_timing!(metadata,timing)
    acquisition_identity(metadata)
    exposure_timing(metadata)
    return nothing
end
function run(metadata,identity,timing)
    for _ in 1:1000; update!(metadata,identity,timing); end
    samples=zeros(Int64,20000)
    for i in eachindex(samples)
        start=time_ns();update!(metadata,identity,timing);samples[i]=time_ns()-start
    end
    sort!(samples)
    (;median_ns=(samples[10000]+samples[10001])/2,p99_ns=samples[19800],max_ns=last(samples),
        bytes=@allocated(update!(metadata,identity,timing)))
end
identity=AcquisitionIdentity(AcquisitionDomain(ntuple(UInt8,16)),7,typemax(UInt64))
timing=ExposureTiming(123456;clock=METADATA_CLOCK_MONOTONIC,duration_nanoseconds=5000)
for (bytes,count) in ((512,4),(4096,64))
    snapshot=fixture(bytes,count)
    records=writable_metadata_records(snapshot)
    for repeat in 1:3
        println((;layout_bytes=bytes,records=count,repeat,result=run(records,identity,timing)))
    end
end
