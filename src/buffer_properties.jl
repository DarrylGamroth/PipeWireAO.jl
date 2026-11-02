const _BufferPropertyScalar = Union{Bool,SPA.Id,Int32,Int64,UInt64,Float32,Float64,NTuple{8,UInt8},NTuple{16,UInt8}}
const BUFFER_PROPERTY_OPTICAL_CLASSIFICATION = UInt32(LibPipeWire.SPA_META_PROPERTY_opticalClassification)
const BUFFER_PROPERTY_TRIGGER_CLASSIFICATION = UInt32(LibPipeWire.SPA_META_PROPERTY_triggerClassification)

"Property key for the nonzero 16-byte acquisition authority domain."
const BUFFER_PROPERTY_ACQUISITION_DOMAIN = UInt32(LibPipeWire.SPA_META_PROPERTY_acquisitionDomain)
"Property key for the acquisition generation, encoded as eight little-endian bytes."
const BUFFER_PROPERTY_ACQUISITION_GENERATION = UInt32(LibPipeWire.SPA_META_PROPERTY_acquisitionGeneration)
"Property key for the physical acquisition counter, independent of Header publication sequence."
const BUFFER_PROPERTY_ACQUISITION_SEQUENCE = UInt32(LibPipeWire.SPA_META_PROPERTY_acquisitionSequence)
"Property key for positive exposure duration in UInt64 nanoseconds."
const BUFFER_PROPERTY_EXPOSURE_DURATION = UInt32(LibPipeWire.SPA_META_PROPERTY_exposureDuration)
"Property key for nonnegative physical exposure start in Int64 nanoseconds."
const BUFFER_PROPERTY_EXPOSURE_START = UInt32(LibPipeWire.SPA_META_PROPERTY_exposureStart)
"Property key for the exposure clock timebase, encoded as SPA.Id."
const BUFFER_PROPERTY_EXPOSURE_TIMEBASE = UInt32(LibPipeWire.SPA_META_PROPERTY_exposureTimebase)
"Property key for exposure timestamp uncertainty in UInt64 nanoseconds."
const BUFFER_PROPERTY_TIMESTAMP_UNCERTAINTY = UInt32(LibPipeWire.SPA_META_PROPERTY_timestampUncertainty)
"Property key for the eight-byte PTP grandmaster clock identity."
const BUFFER_PROPERTY_PTP_GRANDMASTER_IDENTITY = UInt32(LibPipeWire.SPA_META_PROPERTY_ptpGrandmasterIdentity)
"Property key for the PTP domain number, encoded as SPA.Id in 0–255."
const BUFFER_PROPERTY_PTP_DOMAIN_NUMBER = UInt32(LibPipeWire.SPA_META_PROPERTY_ptpDomainNumber)

_buffer_property_type(::Type{T}) where {T<:_BufferPropertyScalar} = _pod_fixed_type(T)
_buffer_property_type(::Type{UInt64}) = UInt32(LibPipeWire.SPA_TYPE_Bytes)
_buffer_property_type(::Type{NTuple{8,UInt8}}) = UInt32(LibPipeWire.SPA_TYPE_Bytes)
_buffer_property_type(::Type{NTuple{16,UInt8}}) = UInt32(LibPipeWire.SPA_TYPE_Bytes)
_buffer_property_flags(key) = UInt32(3 <= key <= 11 ? SPA.PROPERTY_MANDATORY : 0)

"A required per-buffer property key and exact SPA POD scalar type."
struct BufferPropertyRequirement
    key::UInt32
    type::UInt32
    function BufferPropertyRequirement(key::Integer, ::Type{T}) where {T<:_BufferPropertyScalar}
        0 < key <= typemax(UInt32) || throw(ArgumentError("a buffer property key must be nonzero UInt32"))
        key in (BUFFER_PROPERTY_OPTICAL_CLASSIFICATION, BUFFER_PROPERTY_TRIGGER_CLASSIFICATION) && T != SPA.Id && throw(ArgumentError(
            "optical and trigger classification require the SPA.Id POD type",
        ))
        return new(UInt32(key), _buffer_property_type(T))
    end
end

function _buffer_property_requirements(requirements)
    native = LibPipeWire.spa_meta_property_requirement[]
    for requirement in requirements
        requirement isa BufferPropertyRequirement || throw(ArgumentError(
            "required_buffer_properties must contain BufferPropertyRequirement values",
        ))
        any(value -> value.key == requirement.key, native) && throw(ArgumentError(
            "required buffer property keys must be unique",
        ))
        push!(native, LibPipeWire.spa_meta_property_requirement(requirement.key, requirement.type))
        length(native) <= LibPipeWire.SPA_META_PROPERTIES_MAX_FIELDS || throw(ArgumentError(
            "at most 64 buffer property requirements are supported",
        ))
    end
    return native
end

function _buffer_properties_capacity(capacity::Integer; optional::Bool=false)
    optional && capacity == 0 && return UInt32(0)
    LibPipeWire.SPA_META_PROPERTIES_MIN_SIZE <= capacity <= LibPipeWire.SPA_META_PROPERTIES_MAX_SIZE && iszero(capacity % 8) || throw(ArgumentError(
        "buffer properties capacity must be an eight-byte multiple between 16 and 4096",
    ))
    return UInt32(capacity)
end

"""
    BufferProperties

A borrowed typed SPA POD object belonging to one frame buffer. The allocation
and all values borrowed from it expire when the owning callback returns or the
buffer is returned. Successful scalar reads and writes allocate no Julia heap
storage after warmup. Initialize every recycled writable output before adding
properties; keys must be added in strictly increasing order.
"""
struct BufferProperties{Writable,Requirements<:Tuple}
    metadata::LibPipeWire.spa_meta
    validated::Bool
    requirements::Requirements
end

BufferProperties{Writable}(metadata::LibPipeWire.spa_meta) where {Writable} =
    BufferProperties{Writable,Tuple{}}(metadata, false, ())

"Return borrowed Properties, or `nothing` when this buffer has no allocation."
function buffer_properties(buffer::AbstractPipeWireBuffer; required_buffer_properties::Tuple=())
    metadata = buffer_metadata(buffer, UInt32(LibPipeWire.SPA_META_Properties))
    metadata === nothing && return nothing
    return BufferProperties{true,typeof(required_buffer_properties)}(
        _native_metadata(metadata), false, required_buffer_properties)
end

function buffer_properties(buffer::NdArrayFilterBuffer{Writable}) where {Writable}
    native = _native_buffer(buffer)
    available = unsafe_load(_ndarray_buffer_field(native, Val(:metadata_available)))
    iszero(available & LibPipeWire.PW_NDARRAY_FILTER_METADATA_PROPERTIES) && return nothing
    if !Writable
        valid = unsafe_load(_ndarray_buffer_field(native, Val(:metadata_valid)))
        iszero(valid & LibPipeWire.PW_NDARRAY_FILTER_METADATA_PROPERTIES) && return nothing
    end
    metadata = unsafe_load(_ndarray_buffer_field(native, Val(:properties)))
    return BufferProperties{Writable,Tuple{}}(metadata, !Writable, ())
end

_properties_admitted(properties::BufferProperties{false}) = properties.validated
_properties_admitted(properties::BufferProperties{true}) = false
function _require_buffer_properties(properties::BufferProperties)
    (_properties_admitted(properties) || buffer_properties_valid(properties)) || throw(
        InvalidStateException("the buffer Properties are malformed or incomplete", :malformed))
    return properties
end

"Return whether Properties passed native admission or complete validation with their declared requirements."
buffer_properties_valid(properties::BufferProperties) =
    _properties_admitted(properties) || buffer_properties_valid(properties, properties.requirements)

function buffer_properties_valid(properties::BufferProperties, requirements::NTuple{N,BufferPropertyRequirement}) where {N}
    native = ntuple(index -> LibPipeWire.spa_meta_property_requirement(
        requirements[index].key, requirements[index].type,
    ), Val(N))
    storage = Ref(native)
    valid = GC.@preserve storage LibPipeWire.spa_meta_properties_is_valid(
        Ref(properties.metadata),
        N == 0 ? Ptr{LibPipeWire.spa_meta_property_requirement}(C_NULL) :
            Ptr{LibPipeWire.spa_meta_property_requirement}(Base.unsafe_convert(Ptr{typeof(native)}, storage)),
        UInt32(N),
    )
    return valid
end

"Clear writable properties to an empty object, including every recycled field."
function initialize_buffer_properties!(properties::BufferProperties{true})
    LibPipeWire.spa_meta_properties_init(Ref(properties.metadata)) || throw(InvalidStateException(
        "the buffer properties allocation cannot be initialized", :invalid,
    ))
    return properties
end

function initialize_buffer_properties!(buffer::Union{AbstractPipeWireBuffer,NdArrayFilterBuffer{true}})
    properties = buffer_properties(buffer)
    properties === nothing && throw(InvalidStateException(
        "the buffer has no properties allocation", :no_metadata,
    ))
    initialize_buffer_properties!(properties)
    if buffer isa NdArrayFilterBuffer{true}
        valid = _ndarray_buffer_field(_native_buffer(buffer), Val(:metadata_valid))
        unsafe_store!(valid, unsafe_load(valid) | LibPipeWire.PW_NDARRAY_FILTER_METADATA_PROPERTIES)
    end
    return properties
end

"Clear a recycled callback output's Header and Properties without marking either valid."
function clear_buffer_metadata!(buffer::NdArrayFilterBuffer{true})
    properties = buffer_properties(buffer)
    properties === nothing || initialize_buffer_properties!(properties)
    native = _native_buffer(buffer)
    unsafe_store!(_ndarray_buffer_field(native, Val(:header)), LibPipeWire.spa_meta_header(0, 0, 0, 0, 0))
    unsafe_store!(_ndarray_buffer_field(native, Val(:metadata_valid)), UInt32(0))
    return buffer
end

_buffer_property_decode(::Type{Bool}, pointer) = unsafe_load(Ptr{Int32}(pointer)) != 0
_buffer_property_decode(::Type{SPA.Id}, pointer) = SPA.Id(unsafe_load(Ptr{UInt32}(pointer)))
_buffer_property_decode(::Type{T}, pointer) where {T<:Union{Int32,Int64,Float32,Float64}} =
    unsafe_load(Ptr{T}(pointer))

"""
    buffer_property(properties, key, T)

Read a scalar property with its exact POD type `T`, or return `nothing` if the
key is absent. Supported scalar types are Bool, SPA.Id, Int32, Int64, Float32,
Float64, UInt64 (eight little-endian bytes), and fixed eight/sixteen-byte
tuples. Malformed objects and mismatched types are rejected.
"""
function buffer_property(properties::BufferProperties, key::Integer, ::Type{T}) where {T<:_BufferPropertyScalar}
    0 < key <= typemax(UInt32) || throw(ArgumentError("a buffer property key must be nonzero UInt32"))
    _require_buffer_properties(properties)
    pointer = LibPipeWire.spa_meta_properties_find(Ref(properties.metadata), UInt32(key))
    pointer == C_NULL && return nothing
    header = unsafe_load(pointer)
    header.type == _buffer_property_type(T) || throw(ArgumentError("the buffer property has a different POD type"))
    expected_size = T in (Bool, SPA.Id) ? 4 : sizeof(T)
    header.size == expected_size || throw(InvalidStateException(
        "the buffer property scalar size is malformed", :malformed,
    ))
    return _buffer_property_decode(T, Ptr{UInt8}(pointer) + sizeof(LibPipeWire.spa_pod))
end

_buffer_property_wire(value) = _props_wire_value(value)
_buffer_property_wire(value::NTuple{N,UInt8}) where {N} = value
_buffer_property_decode(::Type{NTuple{N,UInt8}}, pointer) where {N} = unsafe_load(Ptr{NTuple{N,UInt8}}(pointer))
function buffer_property(properties::BufferProperties, key::Integer, ::Type{UInt64})
    0 < key <= typemax(UInt32) || throw(ArgumentError("a buffer property key must be nonzero UInt32"))
    _require_buffer_properties(properties)
    pointer = LibPipeWire.spa_meta_properties_find(Ref(properties.metadata), UInt32(key))
    pointer == C_NULL && return nothing
    header = unsafe_load(pointer)
    header.type == _buffer_property_type(UInt64) || throw(ArgumentError("the buffer property has a different POD type"))
    header.size == sizeof(UInt64) || throw(InvalidStateException(
        "the buffer property scalar size is malformed", :malformed,
    ))
    value = Ref{UInt64}(0)
    LibPipeWire.spa_meta_properties_get_uint64(Ref(properties.metadata),UInt32(key),value) ||
        throw(InvalidStateException("the buffer property UInt64 is malformed", :malformed))
    return value[]
end
function set_buffer_property!(properties::BufferProperties{true}, key::Integer, value::UInt64)
    0 < key <= typemax(UInt32) || throw(ArgumentError("a buffer property key must be nonzero UInt32"))
    LibPipeWire.spa_meta_properties_add_uint64(Ref(properties.metadata),UInt32(key),_buffer_property_flags(key),value) ||
        throw(ArgumentError("the buffer property is invalid, unordered, duplicate, or exceeds capacity"))
    return properties
end

"Append one typed scalar property; reject duplicate, unordered, or oversized fields."
function set_buffer_property!(properties::BufferProperties{true}, key::Integer, value::T) where {T<:_BufferPropertyScalar}
    0 < key <= typemax(UInt32) || throw(ArgumentError("a buffer property key must be nonzero UInt32"))
    wire = Ref(_buffer_property_wire(value))
    LibPipeWire.spa_meta_properties_add(
        Ref(properties.metadata), UInt32(key), _buffer_property_flags(key), _buffer_property_type(T), UInt32(sizeof(wire[])), wire,
    ) || throw(ArgumentError("the buffer property is invalid, unordered, duplicate, or exceeds capacity"))
    return properties
end

"Whole-exposure optical classification, independent of electrical trigger state."
@enum OpticalClassification::UInt32 begin
    OPTICAL_ABSENT = LibPipeWire.SPA_META_OPTICAL_ABSENT
    OPTICAL_UNFRINGED = LibPipeWire.SPA_META_OPTICAL_UNFRINGED
    OPTICAL_FRINGED = LibPipeWire.SPA_META_OPTICAL_FRINGED
    OPTICAL_MIXED = LibPipeWire.SPA_META_OPTICAL_MIXED
end

"Return the optical classification, or `nothing` when its typed field is absent."
function optical_classification(properties::BufferProperties)
    value = buffer_property(properties, BUFFER_PROPERTY_OPTICAL_CLASSIFICATION, SPA.Id)
    return value === nothing ? nothing : OpticalClassification(value.value)
end

"Set optical classification independently of electrical trigger state."
set_optical_classification!(properties::BufferProperties{true}, value::OpticalClassification) =
    set_buffer_property!(properties, BUFFER_PROPERTY_OPTICAL_CLASSIFICATION, SPA.Id(UInt32(value)))

"Read typed electrical trigger classification, or `nothing` when its field is absent."
function trigger_classification(properties::BufferProperties)
    value = buffer_property(properties, BUFFER_PROPERTY_TRIGGER_CLASSIFICATION, SPA.Id)
    return value === nothing ? nothing : AcquisitionTriggerState(value.value)
end

"Set electrical trigger classification independently of optical facts."
set_trigger_classification!(properties::BufferProperties{true}, value::AcquisitionTriggerState) =
    set_buffer_property!(properties, BUFFER_PROPERTY_TRIGGER_CLASSIFICATION, SPA.Id(UInt32(value)))

"Request a bounded properties object on every negotiated stream or filter buffer."
buffer_properties_metadata_param(capacity::Integer; id::Integer=LibPipeWire.SPA_PARAM_Meta) =
    metadata_param(UInt32(LibPipeWire.SPA_META_Properties);
        size=_buffer_properties_capacity(capacity),
        features=Int32(LibPipeWire.SPA_META_FEATURE_PROPERTIES_VERSION_1), id)

function _propagate_buffer_properties!(output, input)
    source = buffer_properties(input)
    destination = buffer_properties(output)
    destination === nothing && return output
    initialize_buffer_properties!(destination)
    source === nothing && return output
    _require_buffer_properties(source)
    header = unsafe_load(Ptr{LibPipeWire.spa_pod}(source.metadata.data))
    size = sizeof(LibPipeWire.spa_pod) + Int(header.size)
    size <= destination.metadata.size || throw(ArgumentError(
        "the output buffer properties allocation is too small for metadata propagation",
    ))
    unsafe_copyto!(Ptr{UInt8}(destination.metadata.data), Ptr{UInt8}(source.metadata.data), size)
    return output
end

"Return the full physical acquisition identity, independently of Header publication sequence."
function acquisition_identity(properties::BufferProperties)
    _require_buffer_properties(properties)
    value=Ref{LibPipeWire.spa_acquisition_identity}()
    LibPipeWire.spa_meta_properties_get_acquisition_identity(Ref(properties.metadata),value) || return nothing
    identity=value[]
    return AcquisitionIdentity(AcquisitionDomain(identity.domain),identity.generation,identity.sequence)
end

function _properties_exposure_start(properties::BufferProperties)
    _require_buffer_properties(properties)
    value=Ref{LibPipeWire.spa_exposure_start}()
    LibPipeWire.spa_meta_properties_get_exposure_start(Ref(properties.metadata),value) || return nothing
    return value[]
end

"Return physical exposure start and uncertainty, or `nothing` when absent."
function acquisition_exposure_start(properties::BufferProperties)
    start=_properties_exposure_start(properties)
    return start===nothing ? nothing : AcquisitionExposureStart(start.nsec,start.uncertainty_nsec)
end

"Return the physical exposure clock domain, or `nothing` when absent."
function acquisition_timebase(properties::BufferProperties)
    start=_properties_exposure_start(properties)
    return start===nothing ? nothing : AcquisitionTimebase(start.timebase)
end

"Return the qualified PTP authority, or `nothing` for absent or monotonic exposure time."
function acquisition_ptp_reference(properties::BufferProperties)
    start=_properties_exposure_start(properties)
    (start===nothing || start.timebase!=UInt32(ACQUISITION_TIMEBASE_TAI)) && return nothing
    return AcquisitionPtpReference(PtpClockIdentity(start.ptp_grandmaster_identity),start.ptp_domain_number)
end

"Return positive exposure duration in nanoseconds, or `nothing` when absent."
function acquisition_exposure_duration(properties::BufferProperties)
    _require_buffer_properties(properties)
    value=Ref{UInt64}(0)
    LibPipeWire.spa_meta_properties_get_exposure_duration(Ref(properties.metadata),value) || return nothing
    return value[]
end

"Append the complete identity group after any optical/electrical classification keys."
function set_acquisition_identity!(properties::BufferProperties{true},identity::AcquisitionIdentity)
    set_buffer_property!(properties,BUFFER_PROPERTY_ACQUISITION_DOMAIN,identity.domain.bytes)
    set_buffer_property!(properties,BUFFER_PROPERTY_ACQUISITION_GENERATION,identity.generation)
    set_buffer_property!(properties,BUFFER_PROPERTY_ACQUISITION_SEQUENCE,identity.sequence)
    return properties
end

"Append a positive exposure duration before exposure-start properties."
function set_acquisition_exposure_duration!(properties::BufferProperties{true},nanoseconds::Integer)
    value=_checked_acquisition_uint64(nanoseconds,"exposure duration")
    value>0 || throw(ArgumentError("exposure duration must be positive"))
    return set_buffer_property!(properties,BUFFER_PROPERTY_EXPOSURE_DURATION,value)
end

"Append a complete host-local monotonic exposure-start group."
function set_acquisition_exposure_start!(properties::BufferProperties{true},nanoseconds::Integer,uncertainty_nanoseconds::Integer)
    start=_checked_acquisition_int64(nanoseconds,"exposure start")
    uncertainty=_checked_acquisition_uint64(uncertainty_nanoseconds,"timestamp uncertainty")
    set_buffer_property!(properties,BUFFER_PROPERTY_EXPOSURE_START,start)
    set_buffer_property!(properties,BUFFER_PROPERTY_EXPOSURE_TIMEBASE,SPA.Id(UInt32(ACQUISITION_TIMEBASE_MONOTONIC)))
    set_buffer_property!(properties,BUFFER_PROPERTY_TIMESTAMP_UNCERTAINTY,uncertainty)
    return properties
end

"Append a complete TAI exposure-start group with its PTP authority."
function set_acquisition_exposure_start_ptp!(properties::BufferProperties{true},nanoseconds::Integer,
        uncertainty_nanoseconds::Integer,reference::AcquisitionPtpReference)
    start=_checked_acquisition_int64(nanoseconds,"exposure start")
    uncertainty=_checked_acquisition_uint64(uncertainty_nanoseconds,"timestamp uncertainty")
    set_buffer_property!(properties,BUFFER_PROPERTY_EXPOSURE_START,start)
    set_buffer_property!(properties,BUFFER_PROPERTY_EXPOSURE_TIMEBASE,SPA.Id(UInt32(ACQUISITION_TIMEBASE_TAI)))
    set_buffer_property!(properties,BUFFER_PROPERTY_TIMESTAMP_UNCERTAINTY,uncertainty)
    set_buffer_property!(properties,BUFFER_PROPERTY_PTP_GRANDMASTER_IDENTITY,reference.grandmaster.bytes)
    set_buffer_property!(properties,BUFFER_PROPERTY_PTP_DOMAIN_NUMBER,SPA.Id(UInt32(reference.domain_number)))
    return properties
end

"Compare complete acquisition identities; missing identity never matches."
function acquisition_identity_equal(a::BufferProperties,b::BufferProperties)
    left,right=acquisition_identity(a),acquisition_identity(b)
    return left!==nothing && right!==nothing && left.domain.bytes==right.domain.bytes &&
        left.generation==right.generation && left.sequence==right.sequence
end

"Compare qualified TAI exposure starts, returning difference and saturated combined uncertainty."
function acquisition_time_difference(a::BufferProperties,b::BufferProperties)
    left,right=_properties_exposure_start(a),_properties_exposure_start(b)
    (left===nothing || right===nothing) && return nothing
    difference=Ref{Int64}(0); uncertainty=Ref{UInt64}(0)
    valid=LibPipeWire.spa_exposure_start_time_difference(Ref(left),Ref(right),difference,uncertainty)
    return valid ? (difference[],uncertainty[]) : nothing
end

"Test qualified exposure-time overlap with a saturating unsigned tolerance."
function acquisition_times_match(a::BufferProperties,b::BufferProperties,tolerance_nanoseconds::Integer)
    tolerance=_checked_acquisition_uint64(tolerance_nanoseconds,"timestamp tolerance")
    left,right=_properties_exposure_start(a),_properties_exposure_start(b)
    (left===nothing || right===nothing) && return false
    return LibPipeWire.spa_exposure_start_times_match(Ref(left),Ref(right),tolerance)
end
