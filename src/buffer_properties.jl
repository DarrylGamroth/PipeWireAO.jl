const _BufferPropertyScalar = Union{Bool,SPA.Id,Int32,Int64,Float32,Float64}
const BUFFER_PROPERTY_OPTICAL_CLASSIFICATION = UInt32(LibPipeWire.SPA_META_PROPERTY_opticalClassification)

"A required per-buffer property key and exact SPA POD scalar type."
struct BufferPropertyRequirement
    key::UInt32
    type::UInt32
    function BufferPropertyRequirement(key::Integer, ::Type{T}) where {T<:_BufferPropertyScalar}
        0 < key <= typemax(UInt32) || throw(ArgumentError("a buffer property key must be nonzero UInt32"))
        key == BUFFER_PROPERTY_OPTICAL_CLASSIFICATION && T != SPA.Id && throw(ArgumentError(
            "optical classification requires the SPA.Id POD type",
        ))
        return new(UInt32(key), _pod_fixed_type(T))
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

"Return borrowed properties, or `nothing` if this frame has no properties allocation."
function buffer_properties(buffer::AbstractPipeWireBuffer; required_buffer_properties::Tuple=())
    metadata = buffer_metadata(buffer, UInt32(LibPipeWire.SPA_META_Properties))
    metadata === nothing && return nothing
    return BufferProperties{true,typeof(required_buffer_properties)}(
        _native_metadata(metadata), false, required_buffer_properties,
    )
end

function buffer_properties(buffer::NdArrayFilterBuffer{Writable}) where {Writable}
    buffer.filter == C_NULL && return nothing
    metadata = Ref(LibPipeWire.spa_meta(UInt32(0), UInt32(0), C_NULL))
    result = LibPipeWire.pw_ndarray_filter_get_buffer_properties(
        Ptr{LibPipeWire.pw_ndarray_filter}(buffer.filter), buffer.direction, buffer.index, metadata,
    )
    result in (-Base.Libc.ENOENT, -Base.Libc.EOPNOTSUPP) && return nothing
    _check_result(:pw_ndarray_filter_get_buffer_properties, result)
    return BufferProperties{Writable,Tuple{}}(metadata[], true, ())
end

"Return whether the complete bounded per-buffer properties object is valid."
buffer_properties_valid(properties::BufferProperties) =
    buffer_properties_valid(properties, properties.requirements)

function buffer_properties_valid(properties::BufferProperties, requirements::NTuple{N,BufferPropertyRequirement}) where {N}
    native = ntuple(index -> LibPipeWire.spa_meta_property_requirement(
        requirements[index].key, requirements[index].type,
    ), Val(N))
    storage = Ref(native)
    GC.@preserve storage return LibPipeWire.spa_meta_properties_is_valid(
        Ref(properties.metadata),
        N == 0 ? Ptr{LibPipeWire.spa_meta_property_requirement}(C_NULL) :
            Ptr{LibPipeWire.spa_meta_property_requirement}(Base.unsafe_convert(Ptr{typeof(native)}, storage)),
        UInt32(N),
    )
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
    return initialize_buffer_properties!(properties)
end

_buffer_property_decode(::Type{Bool}, pointer) = unsafe_load(Ptr{Int32}(pointer)) != 0
_buffer_property_decode(::Type{SPA.Id}, pointer) = SPA.Id(unsafe_load(Ptr{UInt32}(pointer)))
_buffer_property_decode(::Type{T}, pointer) where {T<:Union{Int32,Int64,Float32,Float64}} =
    unsafe_load(Ptr{T}(pointer))

"""
    buffer_property(properties, key, T)

Read a scalar property with its exact POD type `T`, or return `nothing` if the
key is absent. Supported scalar types are Bool, SPA.Id, Int32, Int64, Float32,
and Float64. Malformed objects and mismatched types are rejected.
"""
function buffer_property(properties::BufferProperties, key::Integer, ::Type{T}) where {T<:_BufferPropertyScalar}
    0 < key <= typemax(UInt32) || throw(ArgumentError("a buffer property key must be nonzero UInt32"))
    (properties.validated || buffer_properties_valid(properties)) || throw(InvalidStateException(
        "the buffer properties object is malformed", :malformed,
    ))
    pointer = LibPipeWire.spa_meta_properties_find(Ref(properties.metadata), UInt32(key))
    pointer == C_NULL && return nothing
    header = unsafe_load(pointer)
    header.type == _pod_fixed_type(T) || throw(ArgumentError("the buffer property has a different POD type"))
    expected_size = T in (Bool, SPA.Id) ? 4 : sizeof(T)
    header.size == expected_size || throw(InvalidStateException(
        "the buffer property scalar size is malformed", :malformed,
    ))
    return _buffer_property_decode(T, Ptr{UInt8}(pointer) + sizeof(LibPipeWire.spa_pod))
end

"Append one typed scalar property; reject duplicate, unordered, or oversized fields."
function set_buffer_property!(properties::BufferProperties{true}, key::Integer, value::T) where {T<:_BufferPropertyScalar}
    0 < key <= typemax(UInt32) || throw(ArgumentError("a buffer property key must be nonzero UInt32"))
    wire = Ref(_props_wire_value(value))
    LibPipeWire.spa_meta_properties_add(
        Ref(properties.metadata), UInt32(key), _pod_fixed_type(T), UInt32(sizeof(wire[])), wire,
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

"Set optical classification without changing Acquisition v3 electrical trigger metadata."
set_optical_classification!(properties::BufferProperties{true}, value::OpticalClassification) =
    set_buffer_property!(properties, BUFFER_PROPERTY_OPTICAL_CLASSIFICATION, SPA.Id(UInt32(value)))

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
    (source.validated || buffer_properties_valid(source)) || throw(InvalidStateException(
        "the input buffer properties object is malformed", :malformed,
    ))
    header = unsafe_load(Ptr{LibPipeWire.spa_pod}(source.metadata.data))
    size = sizeof(LibPipeWire.spa_pod) + Int(header.size)
    size <= destination.metadata.size || throw(ArgumentError(
        "the output buffer properties allocation is too small for metadata propagation",
    ))
    unsafe_copyto!(Ptr{UInt8}(destination.metadata.data), Ptr{UInt8}(source.metadata.data), size)
    return output
end
