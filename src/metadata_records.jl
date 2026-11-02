"Whole-exposure optical classification, independent of electrical state."
@enum OpticalClassification::UInt32 begin
    OPTICAL_ABSENT = 0
    OPTICAL_UNFRINGED = 1
    OPTICAL_FRINGED = 2
    OPTICAL_MIXED = 3
end

"The identified clock of a metadata event; its label alone does not assert synchronization."
@enum MetadataClock::UInt32 begin
    _METADATA_CLOCK_UNAVAILABLE = 0
    METADATA_CLOCK_MONOTONIC = 1
    METADATA_CLOCK_REALTIME = 2
    METADATA_CLOCK_TAI = 3
    METADATA_CLOCK_MODEL = 4
end
"The event described by an absolute timestamp."
@enum TimeEvent::UInt32 begin
    TIME_EVENT_ACQUISITION = 1
    TIME_EVENT_PRODUCTION = 2
    TIME_EVENT_RECEIPT = 3
    TIME_EVENT_FILE_WRITE = 4
end
const _EMPTY_METADATA_ID = ntuple(_ -> UInt8(0), 16)
_metadata_id(id::NTuple{16,UInt8}, name) = all(iszero,id) ? throw(ArgumentError("$name must be nonzero")) : id
_metadata_mapping(::Nothing) = _EMPTY_METADATA_ID
_metadata_mapping(id::NTuple{16,UInt8}) = _metadata_id(id,"clock mapping")
_metadata_int64(value::Integer) = typemin(Int64) <= value <= typemax(Int64) ? Int64(value) : throw(ArgumentError("timestamp must fit Int64"))
_metadata_uint64(value::Integer) = 0 <= value <= typemax(UInt64) ? UInt64(value) : throw(ArgumentError("value must fit UInt64"))

"An owned exposure interval; independently optional start, duration and uncertainty are explicit."
struct ExposureTiming
    has_start::Bool
    start_nanoseconds::Int64
    clock::MetadataClock
    clock_domain::NTuple{16,UInt8}
    mapping::NTuple{16,UInt8}
    has_duration::Bool
    duration_nanoseconds::UInt64
    has_uncertainty::Bool
    uncertainty_nanoseconds::UInt64
end
function ExposureTiming(start::Integer; clock::MetadataClock,clock_domain::NTuple{16,UInt8},
        mapping::Union{Nothing,NTuple{16,UInt8}}=nothing,duration_nanoseconds::Union{Nothing,Integer}=nothing,
        uncertainty_nanoseconds::Union{Nothing,Integer}=nothing)
    clock == _METADATA_CLOCK_UNAVAILABLE && throw(ArgumentError("exposure clock is unavailable"))
    duration = isnothing(duration_nanoseconds) ? UInt64(0) : _metadata_uint64(duration_nanoseconds)
    isnothing(duration_nanoseconds) || duration > 0 || throw(ArgumentError("exposure duration must be positive"))
    return ExposureTiming(true,_metadata_int64(start),clock,_metadata_id(clock_domain,"exposure clock domain"),
        _metadata_mapping(mapping),!isnothing(duration_nanoseconds),duration,!isnothing(uncertainty_nanoseconds),
        isnothing(uncertainty_nanoseconds) ? UInt64(0) : _metadata_uint64(uncertainty_nanoseconds))
end
function ExposureTiming(;duration_nanoseconds::Integer)
    duration = _metadata_uint64(duration_nanoseconds)
    duration > 0 || throw(ArgumentError("exposure duration must be positive"))
    return ExposureTiming(false,0,_METADATA_CLOCK_UNAVAILABLE,_EMPTY_METADATA_ID,_EMPTY_METADATA_ID,true,duration,false,0)
end

"An owned absolute event time in integer epoch seconds and normalized nanoseconds."
struct AbsoluteTime
    seconds::Int64
    nanoseconds::UInt32
    clock::MetadataClock
    event::TimeEvent
    origin::NTuple{16,UInt8}
    clock_domain::NTuple{16,UInt8}
    mapping::NTuple{16,UInt8}
    has_uncertainty::Bool
    uncertainty_nanoseconds::UInt64
    clock_step::Bool
end
function AbsoluteTime(seconds::Integer,nanoseconds::Integer;clock::MetadataClock=METADATA_CLOCK_REALTIME,
        event::TimeEvent,origin::NTuple{16,UInt8},clock_domain::NTuple{16,UInt8},
        mapping::Union{Nothing,NTuple{16,UInt8}}=nothing,uncertainty_nanoseconds::Union{Nothing,Integer}=nothing,
        clock_step::Bool=false)
    clock in (METADATA_CLOCK_REALTIME,METADATA_CLOCK_TAI) || throw(ArgumentError("absolute time requires REALTIME or TAI"))
    0 <= nanoseconds < 1_000_000_000 || throw(ArgumentError("absolute nanoseconds must be in 0:999999999"))
    return AbsoluteTime(_metadata_int64(seconds),UInt32(nanoseconds),clock,event,_metadata_id(origin,"event origin"),
        _metadata_id(clock_domain,"absolute clock domain"),_metadata_mapping(mapping),!isnothing(uncertainty_nanoseconds),
        isnothing(uncertainty_nanoseconds) ? UInt64(0) : _metadata_uint64(uncertainty_nanoseconds),clock_step)
end
const _EMPTY_ABSOLUTE_TIME = AbsoluteTime(0,0,METADATA_CLOCK_REALTIME,TIME_EVENT_PRODUCTION,
    _EMPTY_METADATA_ID,_EMPTY_METADATA_ID,_EMPTY_METADATA_ID,false,0,false)
"At most four owned absolute event times, preserving each event and origin independently."
struct AbsoluteTimes <: AbstractVector{AbsoluteTime}
    count::UInt8
    values::NTuple{4,AbsoluteTime}
end
Base.size(times::AbsoluteTimes) = (Int(times.count),)
Base.length(times::AbsoluteTimes) = Int(times.count)
Base.IndexStyle(::Type{AbsoluteTimes}) = IndexLinear()
@inline function Base.getindex(times::AbsoluteTimes,index::Int)
    @boundscheck checkbounds(times,index)
    return times.values[index]
end
function AbsoluteTimes(times::Union{Tuple,AbstractVector{AbsoluteTime}}=())
    length(times) <= 4 || throw(ArgumentError("at most four absolute events are supported"))
    for i in eachindex(times), j in 1:i-1
        (times[i].event == times[j].event && times[i].origin == times[j].origin) && throw(ArgumentError("duplicate absolute event/origin"))
    end
    return AbsoluteTimes(UInt8(length(times)),ntuple(i -> i <= length(times) ? times[i] : _EMPTY_ABSOLUTE_TIME,4))
end

"One exact, cold metadata layout declaration; required records need valid per-buffer facts."
struct MetadataRequirement
    type::UInt32
    size::UInt32
    required::Bool
    function MetadataRequirement(type::Integer,size::Integer;required::Bool=false)
        0 < type <= typemax(UInt32) || throw(ArgumentError("metadata type must be nonzero UInt32"))
        0 <= size <= 4096 || throw(ArgumentError("metadata size exceeds the profile bound"))
        LibPipeWire.spa_meta_record_layout_validate(UInt32(type),UInt32(size),UInt32(4096)) ||
            throw(ArgumentError("unsupported metadata layout"))
        return new(UInt32(type),UInt32(size),required)
    end
end
MetadataRequirement(type::Integer;required::Bool=false) = MetadataRequirement(type,Int(LibPipeWire.spa_meta_record_size(UInt32(type)));required)
_native_requirement(r::MetadataRequirement) = LibPipeWire.spa_meta_requirement(r.type,r.size,
    r.required ? UInt32(LibPipeWire.SPA_META_REQUIREMENT_REQUIRED) : UInt32(0),UInt32(0))
function _metadata_requirements(requirements;header::Bool=false)
    result = LibPipeWire.spa_meta_requirement[]
    header && push!(result,_native_requirement(MetadataRequirement(LibPipeWire.SPA_META_Header;required=true)))
    for r in requirements
        r isa MetadataRequirement || throw(ArgumentError("metadata declarations must contain MetadataRequirement values"))
        any(x -> x.type == r.type,result) && throw(ArgumentError("duplicate metadata declaration"))
        push!(result,_native_requirement(r))
    end
    length(result) <= 64 && sum(r -> (Int(r.size)+7)&~7,result;init=0) <= 4096 || throw(ArgumentError("metadata layout exceeds profile bounds"))
    return result
end

"""
    validate_metadata_requirements(requirements; header=true)

Validate a cold profile's exact layouts, uniqueness and aligned 64-record/4096-byte
bounds. Header is implicit by default. This does not initialize or validate facts.
"""
validate_metadata_requirements(requirements;header::Bool=true)=(_metadata_requirements(requirements;header);nothing)

"Borrowed immutable record descriptors; views expire with their buffer callback or lease."
struct MetadataRecords{Writable,Owner}
    data::Ptr{LibPipeWire.spa_meta}
    count::UInt32
    owner::Owner
end
MetadataRecords{Writable}(data::Ptr{LibPipeWire.spa_meta},count::UInt32) where {Writable} =
    MetadataRecords{Writable,Nothing}(data,count,nothing)
Base.length(records::MetadataRecords) = Int(records.count)
function metadata_records(buffer::AbstractPipeWireBuffer)
    spa = unsafe_load(_spa_buffer(buffer))
    return MetadataRecords{false,typeof(buffer)}(spa.metas,spa.n_metas,buffer)
end
function metadata_records(buffer::NdArrayFilterBuffer{Writable}) where {Writable}
    native = _native_buffer(buffer)
    return MetadataRecords{Writable}(unsafe_load(_ndarray_buffer_field(native,Val(:metas))),
        unsafe_load(_ndarray_buffer_field(native,Val(:n_metas))))
end
metadata_records(records::MetadataRecords) = records
function metadata_records_valid(records::MetadataRecords,requirements::Tuple=())
    native = ntuple(i -> _native_requirement(requirements[i]),length(requirements))
    storage = Ref(native)
    return GC.@preserve records storage LibPipeWire.spa_meta_records_validate(records.data,records.count,
        isempty(requirements) ? Ptr{LibPipeWire.spa_meta_requirement}(C_NULL) :
        Ptr{LibPipeWire.spa_meta_requirement}(Base.unsafe_convert(Ptr{typeof(native)},storage)),UInt32(length(requirements)))
end
metadata_records_valid(buffer,requirements::Tuple=()) = GC.@preserve buffer metadata_records_valid(metadata_records(buffer),requirements)
function _record(records::MetadataRecords,type::UInt32;required::Bool=false)
    GC.@preserve records begin
        metadata_records_valid(records) || throw(InvalidStateException("malformed metadata records",:malformed))
        ptr = GC.@preserve records LibPipeWire.spa_meta_records_find(records.data,records.count,type)
        ptr == C_NULL && return nothing
        meta = unsafe_load(ptr)
        GC.@preserve records LibPipeWire.spa_meta_record_validate(ptr,required) || return nothing
        return meta
    end
end
function _writable_record(records::MetadataRecords{true},type::UInt32)
    GC.@preserve records begin
        GC.@preserve records LibPipeWire.spa_meta_records_layout_validate(records.data,records.count) || throw(InvalidStateException("malformed output metadata layout",:malformed))
        ptr = GC.@preserve records LibPipeWire.spa_meta_records_find(records.data,records.count,type)
        ptr == C_NULL && throw(InvalidStateException("output record was not negotiated",:no_metadata))
        return ptr
    end
end
function initialize_metadata!(records::MetadataRecords{true})
    GC.@preserve records begin
        GC.@preserve records LibPipeWire.spa_meta_records_layout_validate(records.data,records.count) || throw(InvalidStateException("malformed output metadata layout",:malformed))
        for i in 1:length(records)
            GC.@preserve records LibPipeWire.spa_meta_record_init(records.data+(i-1)*sizeof(LibPipeWire.spa_meta)) # pointers below use zero-based offsets
        end
        return records
    end
end
initialize_metadata!(buffer::Union{AbstractPipeWireBuffer,NdArrayFilterBuffer{true}}) = initialize_metadata!(writable_metadata_records(buffer))
function acquisition_identity(records::MetadataRecords)
    GC.@preserve records begin
        m = _record(records,UInt32(LibPipeWire.SPA_META_AcquisitionIdentity);required=true)
        m === nothing && return nothing
        x=unsafe_load(Ptr{LibPipeWire.spa_meta_acquisition_identity}(m.data))
        return AcquisitionIdentity(AcquisitionDomain(x.domain),x.generation,x.sequence)
    end
end
acquisition_identity(buffer) = GC.@preserve buffer acquisition_identity(metadata_records(buffer))
function set_acquisition_identity!(records::MetadataRecords{true},identity::AcquisitionIdentity)
    GC.@preserve records begin
        m=unsafe_load(_writable_record(records,UInt32(LibPipeWire.SPA_META_AcquisitionIdentity)))
        unsafe_store!(Ptr{LibPipeWire.spa_meta_acquisition_identity}(m.data),
            LibPipeWire.spa_meta_acquisition_identity(UInt32(LibPipeWire.SPA_META_RECORD_VALID),0,
                identity.domain.bytes,identity.generation,identity.sequence))
        return records
    end
end
set_acquisition_identity!(buffer::Union{AbstractPipeWireBuffer,NdArrayFilterBuffer{true}},value::AcquisitionIdentity) = (set_acquisition_identity!(writable_metadata_records(buffer),value);buffer)
function exposure_timing(records::MetadataRecords)
    GC.@preserve records begin
        m=_record(records,UInt32(LibPipeWire.SPA_META_ExposureTiming);required=true)
        m===nothing && return nothing
        x=unsafe_load(Ptr{LibPipeWire.spa_meta_exposure_timing}(m.data))
        return ExposureTiming(!iszero(x.flags&1),x.start_nsec,MetadataClock(x.clock),x.clock_domain,x.mapping,
            !iszero(x.flags&2),x.duration_nsec,!iszero(x.flags&4),x.uncertainty_nsec)
    end
end
exposure_timing(buffer)=GC.@preserve buffer exposure_timing(metadata_records(buffer))
function set_exposure_timing!(records::MetadataRecords{true},value::ExposureTiming)
    GC.@preserve records begin
        m=unsafe_load(_writable_record(records,UInt32(LibPipeWire.SPA_META_ExposureTiming)))
        flags=UInt32(value.has_start)+UInt32(value.has_duration)*2+UInt32(value.has_uncertainty)*4+
            UInt32(!all(iszero,value.mapping))*8
        native=LibPipeWire.spa_meta_exposure_timing(flags,UInt32(value.clock),value.clock_domain,value.mapping,
            value.start_nanoseconds,value.duration_nanoseconds,value.uncertainty_nanoseconds)
        probe=Ref(native)
        check=LibPipeWire.spa_meta(m.type,m.size,Base.unsafe_convert(Ptr{Cvoid},probe))
        GC.@preserve probe LibPipeWire.spa_meta_record_validate(Ref(check),true) || throw(ArgumentError("invalid exposure timing"))
        unsafe_store!(Ptr{typeof(native)}(m.data),native)
        return records
    end
end
set_exposure_timing!(buffer::Union{AbstractPipeWireBuffer,NdArrayFilterBuffer{true}},value::ExposureTiming)=(set_exposure_timing!(writable_metadata_records(buffer),value);buffer)
_native_absolute(t::AbsoluteTime)=LibPipeWire.spa_meta_absolute_time_event(t.seconds,t.nanoseconds,UInt32(t.clock),UInt32(t.event),
    UInt32(1)+UInt32(t.has_uncertainty)*2+UInt32(!all(iszero,t.mapping))*4+UInt32(t.clock_step)*8,
    t.origin,t.clock_domain,t.mapping,t.uncertainty_nanoseconds)
function _absolute_value(t::LibPipeWire.spa_meta_absolute_time_event)
    return AbsoluteTime(t.seconds,t.nanoseconds,MetadataClock(t.clock),TimeEvent(t.event),t.origin,t.clock_domain,t.mapping,
        !iszero(t.flags&2),t.uncertainty_nsec,!iszero(t.flags&8))
end
function absolute_times(records::MetadataRecords)
    GC.@preserve records begin
        m=_record(records,UInt32(LibPipeWire.SPA_META_AbsoluteTime);required=true)
        m===nothing && return AbsoluteTimes()
        x=unsafe_load(Ptr{LibPipeWire.spa_meta_absolute_time}(m.data))
        return AbsoluteTimes(UInt8(x.count),ntuple(i -> i<=x.count ? _absolute_value(x.events[i]) : _EMPTY_ABSOLUTE_TIME,4))
    end
end
absolute_times(buffer)=GC.@preserve buffer absolute_times(metadata_records(buffer))
function set_absolute_times!(records::MetadataRecords{true},values::Union{Tuple,AbstractVector{AbsoluteTime}})
    GC.@preserve records begin
        times=AbsoluteTimes(values)
        m=unsafe_load(_writable_record(records,UInt32(LibPipeWire.SPA_META_AbsoluteTime)))
        zero_event=LibPipeWire.spa_meta_absolute_time_event(0,0,0,0,0,_EMPTY_METADATA_ID,_EMPTY_METADATA_ID,_EMPTY_METADATA_ID,0)
        native=LibPipeWire.spa_meta_absolute_time(UInt32(length(times)),(UInt32(0),UInt32(0),UInt32(0)),
            ntuple(i -> i<=length(times) ? _native_absolute(times[i]) : zero_event,4))
        unsafe_store!(Ptr{typeof(native)}(m.data),native)
        return records
    end
end
set_absolute_times!(buffer::Union{AbstractPipeWireBuffer,NdArrayFilterBuffer{true}},values::Union{Tuple,AbstractVector{AbsoluteTime}})=(set_absolute_times!(writable_metadata_records(buffer),values);buffer)
function optical_classification(records::MetadataRecords)
    GC.@preserve records begin
        m=_record(records,UInt32(LibPipeWire.SPA_META_OpticalChopping);required=true)
        return m===nothing ? nothing : OpticalClassification(unsafe_load(Ptr{LibPipeWire.spa_meta_optical_chopping}(m.data)).classification)
    end
end
optical_classification(buffer)=GC.@preserve buffer optical_classification(metadata_records(buffer))
function trigger_classification(records::MetadataRecords)
    GC.@preserve records begin
        m=_record(records,UInt32(LibPipeWire.SPA_META_ElectricalTrigger);required=true)
        return m===nothing ? nothing : AcquisitionTriggerState(unsafe_load(Ptr{LibPipeWire.spa_meta_electrical_trigger}(m.data)).classification)
    end
end
trigger_classification(buffer)=GC.@preserve buffer trigger_classification(metadata_records(buffer))
function set_optical_classification!(records::MetadataRecords{true},value::OpticalClassification)
    GC.@preserve records begin
        m=unsafe_load(_writable_record(records,UInt32(LibPipeWire.SPA_META_OpticalChopping)))
        ptr=Ptr{LibPipeWire.spa_meta_optical_chopping}(m.data)
        unsafe_store!(getproperty(ptr,:classification),UInt32(value))
        unsafe_store!(getproperty(ptr,:flags),UInt32(1))
        return records
    end
end
function set_trigger_classification!(records::MetadataRecords{true},value::AcquisitionTriggerState)
    GC.@preserve records begin
        m=unsafe_load(_writable_record(records,UInt32(LibPipeWire.SPA_META_ElectricalTrigger)))
        ptr=Ptr{LibPipeWire.spa_meta_electrical_trigger}(m.data)
        unsafe_store!(getproperty(ptr,:classification),UInt32(value))
        unsafe_store!(getproperty(ptr,:flags),UInt32(1))
        return records
    end
end
set_optical_classification!(buffer::Union{AbstractPipeWireBuffer,NdArrayFilterBuffer{true}},value::OpticalClassification)=(set_optical_classification!(writable_metadata_records(buffer),value);buffer)
set_trigger_classification!(buffer::Union{AbstractPipeWireBuffer,NdArrayFilterBuffer{true}},value::AcquisitionTriggerState)=(set_trigger_classification!(writable_metadata_records(buffer),value);buffer)

metadata_param(requirement::MetadataRequirement) = metadata_param(requirement.type;size=requirement.size,required=requirement.required)
"Invalidate all records of a recycled callback output without changing its skeleton."
clear_buffer_metadata!(buffer::NdArrayFilterBuffer{true}) = (initialize_metadata!(buffer);buffer)

const _HOST_CLOCK_DOMAIN = Ref(_EMPTY_METADATA_ID)
"The cold-cached Linux boot identity shared by local clock readers."
host_clock_domain() = _HOST_CLOCK_DOMAIN[]
function _initialize_host_clock_domain!()
    raw = hex2bytes(replace(strip(read("/proc/sys/kernel/random/boot_id",String)),"-"=>""))
    length(raw)==16 || error("invalid Linux boot clock domain")
    _HOST_CLOCK_DOMAIN[] = _metadata_id(ntuple(i -> raw[i],16),"host clock domain")
    return nothing
end
struct _MetadataTimespec
    seconds::Clong
    nanoseconds::Clong
end
function _metadata_clock_read(clock::MetadataClock)
    clock in (METADATA_CLOCK_REALTIME,METADATA_CLOCK_TAI) || throw(ArgumentError("absolute clock must be REALTIME or TAI"))
    result = Ref(_MetadataTimespec(0,0))
    code=ccall(:clock_gettime,Cint,(Cint,Ref{_MetadataTimespec}),clock==METADATA_CLOCK_REALTIME ? 0 : 11,result)
    code==0 || throw(SystemError("clock_gettime",Libc.errno()))
    return result[]
end
"An explicit absolute clock selection; TAI requires the configured positive TAI−UTC offset."
struct AbsoluteClock
    clock::MetadataClock
    tai_utc_offset::Int64
    function AbsoluteClock(clock::MetadataClock=METADATA_CLOCK_REALTIME;tai_utc_offset::Union{Nothing,Integer}=nothing)
        clock in (METADATA_CLOCK_REALTIME,METADATA_CLOCK_TAI) || throw(ArgumentError("absolute clock must be REALTIME or TAI"))
        if clock==METADATA_CLOCK_TAI
            tai_utc_offset === nothing && throw(ArgumentError("TAI requires an explicit configured TAI−UTC offset"))
            0 < tai_utc_offset <= 128 || throw(ArgumentError("configured TAI−UTC offset is outside 1:128 seconds"))
        elseif tai_utc_offset !== nothing
            throw(ArgumentError("REALTIME does not accept a TAI−UTC offset"))
        end
        value=new(clock,isnothing(tai_utc_offset) ? 0 : Int64(tai_utc_offset))
        _checked_absolute_clock(value)
        return value
    end
end
function _checked_absolute_clock(clock::AbsoluteClock)
    if clock.clock==METADATA_CLOCK_TAI
        before=_metadata_clock_read(METADATA_CLOCK_REALTIME)
        value=_metadata_clock_read(METADATA_CLOCK_TAI)
        after=_metadata_clock_read(METADATA_CLOCK_REALTIME)
        delta_before=(Int128(value.seconds)-before.seconds-clock.tai_utc_offset)*1_000_000_000+value.nanoseconds-before.nanoseconds
        delta_after=(Int128(value.seconds)-after.seconds-clock.tai_utc_offset)*1_000_000_000+value.nanoseconds-after.nanoseconds
        delta_before >= 0 && delta_after <= 0 || throw(InvalidStateException("TAI clock offset is unconfigured, changed or stepped",:clock))
        return value
    end
    return _metadata_clock_read(METADATA_CLOCK_REALTIME)
end
"Read integer absolute event time without inferring acquisition time from callback arrival."
function absolute_time_now(clock::AbsoluteClock;event::TimeEvent,origin::NTuple{16,UInt8},previous::Union{Nothing,AbsoluteTime}=nothing)
    value=_checked_absolute_clock(clock)
    stepped = previous !== nothing && previous.clock==clock.clock && previous.clock_domain==host_clock_domain() &&
        (value.seconds < previous.seconds || (value.seconds==previous.seconds && value.nanoseconds < previous.nanoseconds))
    return AbsoluteTime(Int64(value.seconds),UInt32(value.nanoseconds),clock.clock,event,origin,
        host_clock_domain(),_EMPTY_METADATA_ID,false,0,stepped)
end

"Bounded owned metadata storage for held samples, capture and replay; no borrowed pointers are retained."
mutable struct MetadataSnapshot
    storage::Vector{UInt64}
    descriptors::Vector{LibPipeWire.spa_meta}
    count::UInt32
    used::UInt32
end
MetadataSnapshot() = MetadataSnapshot(zeros(UInt64,512),
    fill(LibPipeWire.spa_meta(0,0,C_NULL),64),0,0)
metadata_records(snapshot::MetadataSnapshot) = MetadataRecords{false,MetadataSnapshot}(pointer(snapshot.descriptors),snapshot.count,snapshot)
metadata_count(snapshot::MetadataSnapshot) = Int(snapshot.count)
function _snapshot_descriptor(snapshot::MetadataSnapshot,index::Integer)
    1 <= index <= snapshot.count || throw(BoundsError(snapshot,index))
    return snapshot.descriptors[index]
end
metadata_type(snapshot::MetadataSnapshot,index::Integer) = _snapshot_descriptor(snapshot,index).type
metadata_size(snapshot::MetadataSnapshot,index::Integer) = Int(_snapshot_descriptor(snapshot,index).size)
"A read-only byte view that keeps its owned snapshot alive."
struct MetadataBytes{Owner} <: AbstractVector{UInt8}
    owner::Owner
    data::Ptr{UInt8}
    count::Int
end
Base.size(bytes::MetadataBytes)=(bytes.count,)
Base.IndexStyle(::Type{<:MetadataBytes})=IndexLinear()
@inline function Base.getindex(bytes::MetadataBytes,index::Int)
    @boundscheck checkbounds(bytes,index)
    return GC.@preserve bytes unsafe_load(bytes.data,index)
end
metadata_bytes(snapshot::MetadataSnapshot,index::Integer) = begin
    m=_snapshot_descriptor(snapshot,index)
    MetadataBytes(snapshot,Ptr{UInt8}(m.data),Int(m.size))
end
function clear_metadata!(snapshot::MetadataSnapshot)
    snapshot.count=0
    snapshot.used=0
    fill!(snapshot.storage,0)
    return snapshot
end
"Copy validated independent records into reusable owned storage before releasing the input lease."
function capture_metadata!(snapshot::MetadataSnapshot,source)
    records=metadata_records(source)
    GC.@preserve snapshot source records begin
        metadata_records_valid(records) || throw(InvalidStateException("invalid source metadata",:metadata))
        used=0
        count=UInt32(0)
        for i in 1:length(records)
            m=unsafe_load(records.data,i)
            LibPipeWire.spa_meta_type_is_transport_owned(m.type) && continue
            count+=1
            target=Ptr{UInt8}(pointer(snapshot.storage))+used
            snapshot.descriptors[count]=LibPipeWire.spa_meta(m.type,m.size,Ptr{Cvoid}(target))
            m.size==0 || unsafe_copyto!(target,Ptr{UInt8}(m.data),Int(m.size))
            aligned=(Int(m.size)+7)&~7
            for j in Int(m.size):aligned-1; unsafe_store!(target+j,UInt8(0)); end
            used+=aligned
        end
        snapshot.count=count
        snapshot.used=UInt32(used)
        return snapshot
    end
end
"Cold restoration from `(type => byte_payload)` entries; native validation rejects malformed records."
function MetadataSnapshot(entries)
    snapshot=MetadataSnapshot()
    used=0
    for entry in entries
        type,payload=entry
        LibPipeWire.spa_meta_type_is_transport_owned(UInt32(type)) && throw(ArgumentError("transport-owned metadata cannot be retained as event facts"))
        snapshot.count < 64 || throw(ArgumentError("too many metadata records"))
        size=length(payload)
        aligned=(size+7)&~7
        used+aligned<=4096 || throw(ArgumentError("metadata exceeds the prepared byte bound"))
        0 < type <= typemax(UInt32) || throw(ArgumentError("invalid metadata type"))
        target=Ptr{UInt8}(pointer(snapshot.storage))+used
        for i in eachindex(payload); unsafe_store!(target,UInt8(payload[i]),i); end
        snapshot.count+=1
        snapshot.descriptors[snapshot.count]=LibPipeWire.spa_meta(UInt32(type),UInt32(size),Ptr{Cvoid}(target))
        used+=aligned
    end
    snapshot.used=UInt32(used)
    GC.@preserve snapshot metadata_records_valid(snapshot) || throw(ArgumentError("invalid restored metadata records"))
    return snapshot
end
"Check preservation capacity without mutating output facts or advancing scientific state."
function metadata_fits(destination,source)
    dst,src=metadata_records(destination),metadata_records(source)
    GC.@preserve destination source dst src begin
        LibPipeWire.spa_meta_records_layout_validate(dst.data,dst.count) && metadata_records_valid(src) || return false
        for i in 1:length(src)
            m=unsafe_load(src.data,i)
            LibPipeWire.spa_meta_type_is_transport_owned(m.type) && continue
            ptr=LibPipeWire.spa_meta_records_find(dst.data,dst.count,m.type)
            ptr==C_NULL && return false
            unsafe_load(ptr).size==m.size || return false
        end
        return true
    end
end
"""
    metadata_fits(destination, requirements; header=true)

Check only negotiated storage: required slots must exist; absent optional slots
are allowed, and every present declared slot must have its exact size. Header is
required by default. Recycled output fact bytes need not be valid yet.
"""
function metadata_fits(destination,requirements::Union{Tuple{Vararg{MetadataRequirement}},Vector{MetadataRequirement}};header::Bool=true)
    records=metadata_records(destination)
    GC.@preserve destination records begin
        LibPipeWire.spa_meta_records_layout_validate(records.data,records.count) || return false
        header && LibPipeWire.spa_meta_records_find(records.data,records.count,UInt32(LibPipeWire.SPA_META_Header))==C_NULL && return false
        for requirement in requirements
            record=LibPipeWire.spa_meta_records_find(records.data,records.count,requirement.type)
            if record==C_NULL
                requirement.required && return false
            else
                unsafe_load(record).size==requirement.size || return false
            end
        end
        return true
    end
end

"Publish a retained snapshot only into an already negotiated compatible output skeleton."
function copy_metadata!(destination::Union{AbstractPipeWireBuffer,NdArrayFilterBuffer{true},MetadataRecords{true}},source)
    dst,src=writable_metadata_records(destination),metadata_records(source)
    GC.@preserve destination source dst src LibPipeWire.spa_meta_records_copy(dst.data,dst.count,src.data,src.count) ||
        throw(InvalidStateException("output metadata cannot preserve all source records",:metadata))
    return destination
end

"Prepare owned zeroed record slots from a cold layout declaration."
function MetadataSnapshot(requirements::Tuple{Vararg{MetadataRequirement}})
    _metadata_requirements(requirements)
    return MetadataSnapshot((r.type=>zeros(UInt8,Int(r.size)) for r in requirements))
end
"Borrow writable views only from an exclusively owned snapshot during preparation."
writable_metadata_records(snapshot::MetadataSnapshot) = MetadataRecords{true,MetadataSnapshot}(pointer(snapshot.descriptors),snapshot.count,snapshot)
function set_buffer_header!(records::MetadataRecords{true},header::BufferHeader)
    GC.@preserve records begin
        m=unsafe_load(_writable_record(records,UInt32(LibPipeWire.SPA_META_Header)))
        unsafe_store!(Ptr{LibPipeWire.spa_meta_header}(m.data),LibPipeWire.spa_meta_header(
            header.flags,header.offset,header.pts,header.dts_offset,header.sequence))
        return records
    end
end
function buffer_header(records::MetadataRecords)
    GC.@preserve records begin
        m=_record(records,UInt32(LibPipeWire.SPA_META_Header);required=true)
        m===nothing && return nothing
        header=unsafe_load(Ptr{LibPipeWire.spa_meta_header}(m.data))
        return BufferHeader(header.flags,header.offset,header.pts,header.dts_offset,header.seq)
    end
end
buffer_header(snapshot::MetadataSnapshot)=buffer_header(metadata_records(snapshot))

"One borrowed record; optional unknown payloads remain opaque read-only bytes."
struct MetadataRecord{Owner}
    owner::Owner
    metadata::LibPipeWire.spa_meta
end
metadata_type(record::MetadataRecord)=record.metadata.type
metadata_size(record::MetadataRecord)=Int(record.metadata.size)
metadata_bytes(record::MetadataRecord)=MetadataBytes(record.owner,Ptr{UInt8}(record.metadata.data),(Int(record.metadata.size)))
Base.size(records::MetadataRecords)=(Int(records.count),)
Base.eachindex(records::MetadataRecords)=Base.OneTo(length(records))
function Base.getindex(records::MetadataRecords,index::Int)
    1 <= index <= length(records) || throw(BoundsError(records,index))
    return MetadataRecord(records,unsafe_load(records.data,index))
end
function Base.iterate(records::MetadataRecords,index::Int=1)
    index>length(records) && return nothing
    return records[index],index+1
end
function metadata_record(source,type::UInt32)
    records=metadata_records(source)
    m=_record(records,type)
    return m===nothing ? nothing : MetadataRecord(records,m)
end
"Populate one already negotiated owned slot, with exact-size bytes and native semantic validation."
function set_metadata_bytes!(records::MetadataRecords{true},type::UInt32,payload::Union{Vector{UInt8},Tuple{Vararg{UInt8}}})
    m=unsafe_load(_writable_record(records,type))
    length(payload)==m.size || throw(ArgumentError("metadata payload differs from the negotiated size"))
    storage=Ref(payload)
    GC.@preserve records payload storage begin
        data=payload isa Tuple ? Ptr{Cvoid}(Base.unsafe_convert(Ptr{typeof(payload)},storage)) : Ptr{Cvoid}(pointer(payload))
        probe=LibPipeWire.spa_meta(m.type,m.size,data)
        LibPipeWire.spa_meta_record_validate(Ref(probe),false) || throw(ArgumentError("invalid metadata payload"))
        for i in eachindex(payload); unsafe_store!(Ptr{UInt8}(m.data),payload[i],i); end
    end
    return records
end

"Explicit writable record access for a raw stream/filter buffer exclusively owned for output."
function writable_metadata_records(buffer::AbstractPipeWireBuffer)
    spa=unsafe_load(_spa_buffer(buffer))
    return MetadataRecords{true,typeof(buffer)}(spa.metas,spa.n_metas,buffer)
end
writable_metadata_records(buffer::NdArrayFilterBuffer{true})=metadata_records(buffer)
writable_metadata_records(records::MetadataRecords{true})=records
"Check an absolute clock policy before execution without claiming an event happened at that reading."
validate_absolute_clock(clock::AbsoluteClock)=(_checked_absolute_clock(clock);clock)

function metadata_records_valid(records::MetadataRecords,requirements::Vector{MetadataRequirement})
    length(requirements)<=64 || return false
    metadata_records_valid(records) || return false
    for requirement in requirements
        native=Ref(_native_requirement(requirement))
        GC.@preserve records native LibPipeWire.spa_meta_records_validate(records.data,records.count,native,UInt32(1)) || return false
    end
    return true
end

"Whether a metadata type describes mutable pool/transport state rather than scientific facts."
metadata_is_transport_owned(type::Integer)=LibPipeWire.spa_meta_type_is_transport_owned(UInt32(type))
metadata_is_transport_owned(record::MetadataRecord)=metadata_is_transport_owned(metadata_type(record))
