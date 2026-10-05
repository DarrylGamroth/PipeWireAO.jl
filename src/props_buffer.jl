"""
    PropsBuffer(names::NTuple{N,String}, values::T) where {N,T<:Tuple}

Prepare a standard `SPA_PARAM_Props` object with fixed names and scalar types.
Supported values are `Bool`, `Int32`, `Int64`, `Float32`, `Float64`, and `SPA.Id`.
Preparation owns the POD and allocates parser scratch storage. Subsequent
`props!` and `parse_props!` calls reuse that storage without heap allocation.

One caller owns the buffer; do not access it concurrently. A POD returned by
`props!` borrows the buffer until the next update. Do not mutate its bytes.
Copy with `Pod(pod.data)` outside the allocation-sensitive path to retain it.
"""
struct PropsBuffer{N,T<:Tuple}
    names::NTuple{N,String}
    pod::Pod
    offsets::NTuple{N,Int}
    prototype::T
    parsed_offsets::Vector{Int}
end

_props_wire_value(value::Bool) = value ? Int32(1) : Int32(0)
_props_wire_value(value::SPA.Id) = value.value
_props_wire_value(value::Union{Int32,Int64,Float32,Float64}) = value
_props_wire_value(value) = throw(ArgumentError("unsupported prepared Props scalar type: $(typeof(value))"))

# All callers establish the byte range before constructing a view. No native
# pointers are needed to read or update the scalar POD representation.
function _props_read(::Type{T}, data::Vector{UInt8}, offset::Int) where {T}
    return reinterpret(T, @view(data[offset:(offset + sizeof(T) - 1)]))[1]
end

function _props_write!(data::Vector{UInt8}, offset::Int, value::T) where {T}
    reinterpret(T, @view(data[offset:(offset + sizeof(T) - 1)]))[1] = value
    return nothing
end

_props_padded_size(size::Int) = (size + 7) & -8

function PropsBuffer(names::NTuple{N,String}, values::T) where {N,T<:Tuple}
    N == length(values) || throw(ArgumentError("prepared Props names and values must have equal lengths"))
    for index in 1:N
        _props_wire_value(values[index])
        for previous in 1:(index - 1)
            names[index] == names[previous] && throw(ArgumentError("prepared Props names must be unique"))
        end
    end
    pod = Pod(props_param(SPA.Props(ntuple(index -> names[index] => values[index], N))))
    offsets = Vector{Int}(undef, N)
    # Object header/body, property key/flags, and the Struct header occupy 32
    # bytes. Each name and scalar is a POD padded to an eight-byte boundary.
    cursor = 33
    for index in 1:N
        cursor += _props_padded_size(8 + ncodeunits(names[index]) + 1)
        offsets[index] = cursor + 8
        cursor += _props_padded_size(8 + sizeof(_props_wire_value(values[index])))
    end
    return PropsBuffer{N,T}(names, pod, Tuple(offsets), values, zeros(Int, N))
end

_props_update!(data, ::Tuple{}, ::Tuple{}) = nothing
function _props_update!(data, offsets::Tuple, values::Tuple)
    _props_write!(data, first(offsets), _props_wire_value(first(values)))
    _props_update!(data, Base.tail(offsets), Base.tail(values))
    return nothing
end

"""
    props!(buffer::PropsBuffer{N,T}, values::T) -> Pod

Update the prepared scalar fields and return a borrowed standard Props POD.
Names and exact scalar types remain those supplied at preparation.
"""
function props!(buffer::PropsBuffer{N,T}, values::T) where {N,T<:Tuple}
    _props_update!(buffer.pod.data, buffer.offsets, values)
    return buffer.pod
end

function _props_name_matches(name::String, data::Vector{UInt8}, offset::Int, size::Int)
    size == ncodeunits(name) + 1 || return false
    data[offset + size - 1] == 0 || return false
    for index in 1:ncodeunits(name)
        data[offset + index - 1] == codeunit(name, index) || return false
    end
    return true
end

_props_name_index(::Tuple{}, data, offset, size, index::Int) = 0
function _props_name_index(names::Tuple, data, offset, size, index::Int)
    _props_name_matches(first(names), data, offset, size) && return index
    return _props_name_index(Base.tail(names), data, offset, size, index + 1)
end

_props_scalar_matches(::Tuple{}, index::Int, type::UInt32, size::Int) = false
function _props_scalar_matches(prototype::Tuple, index::Int, type::UInt32, size::Int)
    if index == 1
        value = first(prototype)
        return type == _pod_fixed_type(typeof(value)) && size == sizeof(_props_wire_value(value))
    end
    return _props_scalar_matches(Base.tail(prototype), index - 1, type, size)
end

_props_decode(::Bool, data, offset) = _props_read(Int32, data, offset) != 0
_props_decode(::SPA.Id, data, offset) = SPA.Id(_props_read(UInt32, data, offset))
_props_decode(::T, data, offset) where {T<:Union{Int32,Int64,Float32,Float64}} =
    _props_read(T, data, offset)

_props_decode_values(::Tuple{}, data, offsets, index::Int) = ()
function _props_decode_values(prototype::Tuple, data, offsets, index::Int)
    return (
        _props_decode(first(prototype), data, offsets[index]),
        _props_decode_values(Base.tail(prototype), data, offsets, index + 1)...,
    )
end

"""
    parse_props!(destination::Ref{T}, buffer::PropsBuffer{N,T}, pod::Pod)::Cint

Validate and parse exactly the prepared names and scalar POD types, accepting
any pair order. Return zero on success, `-ENOENT` for missing fields, and
`-EINVAL` for malformed PODs, extra or duplicate fields, or mismatched names
or types. The destination is valid only on success. Schema versions and other
semantic checks belong to the caller. The buffer is not safe for concurrent use.
"""
function parse_props!(destination::Ref{T}, buffer::PropsBuffer{N,T}, pod::Pod)::Cint where {N,T<:Tuple}
    invalid = Cint(-Base.Libc.EINVAL)
    missing = Cint(-Base.Libc.ENOENT)
    data = pod.data
    total = length(data)
    16 <= total < (1 << 20) + 8 || return invalid
    _props_read(UInt32, data, 1) == total - 8 || return invalid
    _props_read(UInt32, data, 5) == UInt32(LibPipeWire.SPA_TYPE_Object) || return invalid
    _props_read(UInt32, data, 9) == UInt32(SPA.OBJECT_PROPS) || return invalid
    _props_read(UInt32, data, 13) == UInt32(SPA.PARAM_PROPS) || return invalid
    total == 16 && return missing
    total >= 32 || return invalid
    _props_read(UInt32, data, 17) == UInt32(SPA.PROP_PARAMS) || return invalid
    _props_read(UInt32, data, 29) == UInt32(LibPipeWire.SPA_TYPE_Struct) || return invalid
    struct_size_word = _props_read(UInt32, data, 25)
    struct_size_word <= total - 32 || return invalid
    struct_size = Int(struct_size_word)
    # The only property is params. Reject further properties and any missing
    # alignment padding rather than following an unbounded nested length.
    _props_padded_size(16 + struct_size) == total - 16 || return invalid
    limit = 32 + struct_size
    cursor = 33
    offsets = buffer.parsed_offsets
    fill!(offsets, 0)
    while cursor <= limit
        limit - cursor + 1 >= 8 || return invalid
        name_size_word = _props_read(UInt32, data, cursor)
        _props_read(UInt32, data, cursor + 4) == UInt32(LibPipeWire.SPA_TYPE_String) || return invalid
        name_size_word >= 1 && name_size_word <= limit - cursor - 7 || return invalid
        name_size = Int(name_size_word)
        name_stride = _props_padded_size(8 + name_size)
        name_stride <= limit - cursor + 1 || return invalid
        index = _props_name_index(buffer.names, data, cursor + 8, name_size, 1)
        index != 0 || return invalid
        offsets[index] == 0 || return invalid
        cursor += name_stride
        limit - cursor + 1 >= 8 || return invalid
        scalar_size_word = _props_read(UInt32, data, cursor)
        scalar_type = _props_read(UInt32, data, cursor + 4)
        scalar_size_word <= limit - cursor - 7 || return invalid
        scalar_size = Int(scalar_size_word)
        scalar_stride = _props_padded_size(8 + scalar_size)
        scalar_stride <= limit - cursor + 1 || return invalid
        _props_scalar_matches(buffer.prototype, index, scalar_type, scalar_size) || return invalid
        offsets[index] = cursor + 8
        cursor += scalar_stride
    end
    for offset in offsets
        offset != 0 || return missing
    end
    destination[] = _props_decode_values(buffer.prototype, data, offsets, 1)
    return Cint(0)
end
