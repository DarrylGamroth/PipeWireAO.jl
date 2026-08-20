"Return the SPA type ID stored in an owned POD header."
function pod_type(pod::Pod)
    data = pod.data
    return GC.@preserve data unsafe_load(Ptr{LibPipeWire.spa_pod}(pointer(data))).type
end

function _pod_pointer(pod::Pod)
    return Ptr{LibPipeWire.spa_pod}(pointer(pod.data))
end

function _copy_pod(pointer::Ptr{LibPipeWire.spa_pod})
    pointer == C_NULL && return nothing
    header = unsafe_load(pointer)
    header.size < (1 << 20) || throw(ArgumentError("the SPA POD body is too large"))
    total_size = sizeof(LibPipeWire.spa_pod) + Int(header.size)
    data = copy(unsafe_wrap(Vector{UInt8}, Ptr{UInt8}(pointer), total_size; own=false))
    return Pod(data)
end

function _append_bits!(data::Vector{UInt8}, value::T) where {T}
    bytes = reinterpret(UInt8, [value])
    append!(data, bytes)
    return data
end

function _pod_from_body(type::UInt32, body)
    length(body) <= typemax(UInt32) || throw(ArgumentError("the SPA POD body is too large"))
    data = UInt8[]
    _append_bits!(data, UInt32(length(body)))
    _append_bits!(data, type)
    append!(data, body)
    return Pod(data)
end

function _scalar_pod(type::UInt32, value::T) where {T}
    data = UInt8[]
    _append_bits!(data, UInt32(sizeof(T)))
    _append_bits!(data, type)
    _append_bits!(data, value)
    return Pod(data)
end

_pod_fixed_type(::Type{Bool}) = UInt32(LibPipeWire.SPA_TYPE_Bool)
_pod_fixed_type(::Type{SPA.Id}) = UInt32(LibPipeWire.SPA_TYPE_Id)
_pod_fixed_type(::Type{Int32}) = UInt32(LibPipeWire.SPA_TYPE_Int)
_pod_fixed_type(::Type{Int64}) = UInt32(LibPipeWire.SPA_TYPE_Long)
_pod_fixed_type(::Type{Float32}) = UInt32(LibPipeWire.SPA_TYPE_Float)
_pod_fixed_type(::Type{Float64}) = UInt32(LibPipeWire.SPA_TYPE_Double)
_pod_fixed_type(::Type{SPA.Rectangle}) = UInt32(LibPipeWire.SPA_TYPE_Rectangle)
_pod_fixed_type(::Type{SPA.Fraction}) = UInt32(LibPipeWire.SPA_TYPE_Fraction)
_pod_fixed_type(::Type{SPA.Fd}) = UInt32(LibPipeWire.SPA_TYPE_Fd)
function _pod_fixed_type(::Type{T}) where {T}
    throw(ArgumentError("$T is not a fixed-size SPA POD value type"))
end

_pod_fixed_size(::Type{Bool}) = sizeof(Int32)
_pod_fixed_size(::Type{SPA.Id}) = sizeof(UInt32)
_pod_fixed_size(::Type{Int32}) = sizeof(Int32)
_pod_fixed_size(::Type{Int64}) = sizeof(Int64)
_pod_fixed_size(::Type{Float32}) = sizeof(Float32)
_pod_fixed_size(::Type{Float64}) = sizeof(Float64)
_pod_fixed_size(::Type{SPA.Rectangle}) = 2 * sizeof(UInt32)
_pod_fixed_size(::Type{SPA.Fraction}) = 2 * sizeof(UInt32)
_pod_fixed_size(::Type{SPA.Fd}) = sizeof(Int64)

_append_pod_fixed!(data::Vector{UInt8}, value::Bool) =
    _append_bits!(data, value ? Int32(1) : Int32(0))
_append_pod_fixed!(data::Vector{UInt8}, value::SPA.Id) =
    _append_bits!(data, value.value)
_append_pod_fixed!(data::Vector{UInt8}, value::Union{Int32,Int64,Float32,Float64}) =
    _append_bits!(data, value)
_append_pod_fixed!(data::Vector{UInt8}, value::SPA.Fd) =
    _append_bits!(data, value.value)
function _append_pod_fixed!(data::Vector{UInt8}, value::SPA.Rectangle)
    _append_bits!(data, value.width)
    return _append_bits!(data, value.height)
end
function _append_pod_fixed!(data::Vector{UInt8}, value::SPA.Fraction)
    _append_bits!(data, value.num)
    return _append_bits!(data, value.denom)
end

Pod(::Nothing) = _pod_from_body(UInt32(LibPipeWire.SPA_TYPE_None), UInt8[])
Pod(value::Bool) =
    _scalar_pod(UInt32(LibPipeWire.SPA_TYPE_Bool), value ? Int32(1) : Int32(0))
Pod(value::SPA.Id) = _scalar_pod(UInt32(LibPipeWire.SPA_TYPE_Id), value.value)
Pod(value::Int32) = _scalar_pod(UInt32(LibPipeWire.SPA_TYPE_Int), value)
Pod(value::Int64) = _scalar_pod(UInt32(LibPipeWire.SPA_TYPE_Long), value)
Pod(value::Float32) = _scalar_pod(UInt32(LibPipeWire.SPA_TYPE_Float), value)
Pod(value::Float64) = _scalar_pod(UInt32(LibPipeWire.SPA_TYPE_Double), value)
Pod(value::SPA.Bytes) = _pod_from_body(UInt32(LibPipeWire.SPA_TYPE_Bytes), value.data)
Pod(value::SPA.Bitmap) = _pod_from_body(UInt32(LibPipeWire.SPA_TYPE_Bitmap), value.data)
Pod(value::SPA.Fd) = _scalar_pod(UInt32(LibPipeWire.SPA_TYPE_Fd), value.value)

function Pod(value::AbstractString)
    string = _validate_c_string(String(value), "SPA string")
    body = Vector{UInt8}(codeunits(string))
    push!(body, 0)
    return _pod_from_body(UInt32(LibPipeWire.SPA_TYPE_String), body)
end

function Pod(value::SPA.Rectangle)
    body = UInt8[]
    _append_bits!(body, value.width)
    _append_bits!(body, value.height)
    return _pod_from_body(UInt32(LibPipeWire.SPA_TYPE_Rectangle), body)
end

function Pod(value::SPA.Fraction)
    body = UInt8[]
    _append_bits!(body, value.num)
    _append_bits!(body, value.denom)
    return _pod_from_body(UInt32(LibPipeWire.SPA_TYPE_Fraction), body)
end

function Pod(value::SPA.Pointer)
    body = UInt8[]
    _append_bits!(body, value.type)
    _append_bits!(body, UInt32(0))
    _append_bits!(body, UInt(value.value))
    return _pod_from_body(UInt32(LibPipeWire.SPA_TYPE_Pointer), body)
end

function Pod(value::SPA.Array{T}) where {T}
    child_type = _pod_fixed_type(T)
    child_size = _pod_fixed_size(T)
    body = UInt8[]
    _append_bits!(body, UInt32(child_size))
    _append_bits!(body, child_type)
    for element in value.values
        _append_pod_fixed!(body, element)
    end
    return _pod_from_body(UInt32(LibPipeWire.SPA_TYPE_Array), body)
end

function Pod(value::SPA.Choice{T}) where {T}
    child_type = _pod_fixed_type(T)
    child_size = _pod_fixed_size(T)
    body = UInt8[]
    _append_bits!(body, UInt32(value.kind))
    _append_bits!(body, value.flags)
    _append_bits!(body, UInt32(child_size))
    _append_bits!(body, child_type)
    for element in value.values
        _append_pod_fixed!(body, element)
    end
    return _pod_from_body(UInt32(LibPipeWire.SPA_TYPE_Choice), body)
end

function Pod(value::SPA.Struct)
    body = UInt8[]
    for child in value.values
        append!(body, child.data)
        _pad_pod!(body)
    end
    return _pod_from_body(UInt32(LibPipeWire.SPA_TYPE_Struct), body)
end

function Pod(value::SPA.Object)
    body = UInt8[]
    _append_bits!(body, value.type)
    _append_bits!(body, value.id)
    for property in value.properties
        _append_bits!(body, property.key)
        _append_bits!(body, property.flags)
        append!(body, property.value.data)
        _pad_pod!(body)
    end
    return _pod_from_body(UInt32(LibPipeWire.SPA_TYPE_Object), body)
end

Pod(value::Union{SPA.Parameter,SPA.Command,SPA.Event}) = Pod(value.object)
Base.convert(::Type{Pod}, value::Union{SPA.Parameter,SPA.Command,SPA.Event}) = Pod(value)

function Pod(value::SPA.Sequence)
    body = UInt8[]
    _append_bits!(body, value.unit)
    _append_bits!(body, UInt32(0))
    for control in value.controls
        _append_bits!(body, control.offset)
        _append_bits!(body, control.type)
        append!(body, control.value.data)
        _pad_pod!(body)
    end
    return _pod_from_body(UInt32(LibPipeWire.SPA_TYPE_Sequence), body)
end

function _check_pod_body(pod::Pod, expected_type::UInt32, expected_size::Integer)
    actual_type = pod_type(pod)
    actual_type == expected_type || throw(
        ArgumentError("expected SPA POD type $expected_type, received $actual_type"),
    )
    data = pod.data
    body_size = length(data) - sizeof(LibPipeWire.spa_pod)
    body_size == expected_size || throw(
        ArgumentError("expected SPA POD body size $expected_size, received $body_size"),
    )
    return nothing
end

function _pod_body_pointer(pod::Pod, expected_type::UInt32, expected_size::Integer)
    _check_pod_body(pod, expected_type, expected_size)
    data = pod.data
    return pointer(data) + sizeof(LibPipeWire.spa_pod)
end

function _pod_scalar(::Type{T}, pod::Pod, expected_type::UInt32) where {T}
    data = pod.data
    return GC.@preserve data unsafe_load(
        Ptr{T}(_pod_body_pointer(pod, expected_type, sizeof(T))),
    )
end

_load_pod_fixed(::Type{Bool}, pointer::Ptr{UInt8}) =
    unsafe_load(Ptr{Int32}(pointer)) != 0
_load_pod_fixed(::Type{SPA.Id}, pointer::Ptr{UInt8}) =
    SPA.Id(unsafe_load(Ptr{UInt32}(pointer)))
_load_pod_fixed(::Type{Int32}, pointer::Ptr{UInt8}) = unsafe_load(Ptr{Int32}(pointer))
_load_pod_fixed(::Type{Int64}, pointer::Ptr{UInt8}) = unsafe_load(Ptr{Int64}(pointer))
_load_pod_fixed(::Type{Float32}, pointer::Ptr{UInt8}) = unsafe_load(Ptr{Float32}(pointer))
_load_pod_fixed(::Type{Float64}, pointer::Ptr{UInt8}) = unsafe_load(Ptr{Float64}(pointer))
_load_pod_fixed(::Type{SPA.Fd}, pointer::Ptr{UInt8}) =
    SPA.Fd(unsafe_load(Ptr{Int64}(pointer)))
_load_pod_fixed(::Type{SPA.Rectangle}, pointer::Ptr{UInt8}) = SPA.Rectangle(
    unsafe_load(Ptr{UInt32}(pointer)),
    unsafe_load(Ptr{UInt32}(pointer + sizeof(UInt32))),
)
_load_pod_fixed(::Type{SPA.Fraction}, pointer::Ptr{UInt8}) = SPA.Fraction(
    unsafe_load(Ptr{UInt32}(pointer)),
    unsafe_load(Ptr{UInt32}(pointer + sizeof(UInt32))),
)

"""
    pod_value(T, pod::Pod) -> T
    pod_value(pod::Pod)

Return the owned value stored in an SPA POD. Supplying `T` gives a type-stable
result and validates that the POD has the corresponding wire type. The
one-argument form selects `T` from [`pod_type`](@ref).
"""
function pod_value(::Type{Nothing}, pod::Pod)
    _check_pod_body(pod, UInt32(LibPipeWire.SPA_TYPE_None), 0)
    return nothing
end

function pod_value(::Type{Bool}, pod::Pod)
    return _pod_scalar(Int32, pod, UInt32(LibPipeWire.SPA_TYPE_Bool)) != 0
end

pod_value(::Type{SPA.Id}, pod::Pod) =
    SPA.Id(_pod_scalar(UInt32, pod, UInt32(LibPipeWire.SPA_TYPE_Id)))
pod_value(::Type{Int32}, pod::Pod) =
    _pod_scalar(Int32, pod, UInt32(LibPipeWire.SPA_TYPE_Int))
pod_value(::Type{Int64}, pod::Pod) =
    _pod_scalar(Int64, pod, UInt32(LibPipeWire.SPA_TYPE_Long))
pod_value(::Type{Float32}, pod::Pod) =
    _pod_scalar(Float32, pod, UInt32(LibPipeWire.SPA_TYPE_Float))
pod_value(::Type{Float64}, pod::Pod) =
    _pod_scalar(Float64, pod, UInt32(LibPipeWire.SPA_TYPE_Double))
pod_value(::Type{SPA.Fd}, pod::Pod) =
    SPA.Fd(_pod_scalar(Int64, pod, UInt32(LibPipeWire.SPA_TYPE_Fd)))

function pod_value(::Type{String}, pod::Pod)
    data = pod.data
    body_size = length(data) - sizeof(LibPipeWire.spa_pod)
    _check_pod_body(pod, UInt32(LibPipeWire.SPA_TYPE_String), body_size)
    body_size > 0 || throw(ArgumentError("an SPA string POD must contain a terminator"))
    body = @view data[(sizeof(LibPipeWire.spa_pod) + 1):end]
    body[end] == 0 || throw(ArgumentError("an SPA string POD is not null terminated"))
    findfirst(iszero, body) == lastindex(body) ||
        throw(ArgumentError("an SPA string POD contains an embedded null"))
    return String(body[begin:(end - 1)])
end

function pod_value(::Type{SPA.Bytes}, pod::Pod)
    data = pod.data
    body_size = length(data) - sizeof(LibPipeWire.spa_pod)
    _check_pod_body(pod, UInt32(LibPipeWire.SPA_TYPE_Bytes), body_size)
    return SPA.Bytes(@view data[(sizeof(LibPipeWire.spa_pod) + 1):end])
end

function pod_value(::Type{SPA.Bitmap}, pod::Pod)
    data = pod.data
    body_size = length(data) - sizeof(LibPipeWire.spa_pod)
    _check_pod_body(pod, UInt32(LibPipeWire.SPA_TYPE_Bitmap), body_size)
    body_size > 0 || throw(ArgumentError("an SPA bitmap POD must not be empty"))
    return SPA.Bitmap(@view data[(sizeof(LibPipeWire.spa_pod) + 1):end])
end

function pod_value(::Type{SPA.Rectangle}, pod::Pod)
    data = pod.data
    return GC.@preserve data begin
        pointer = _pod_body_pointer(
            pod,
            UInt32(LibPipeWire.SPA_TYPE_Rectangle),
            2 * sizeof(UInt32),
        )
        SPA.Rectangle(
            unsafe_load(Ptr{UInt32}(pointer)),
            unsafe_load(Ptr{UInt32}(pointer + sizeof(UInt32))),
        )
    end
end

function pod_value(::Type{SPA.Fraction}, pod::Pod)
    data = pod.data
    return GC.@preserve data begin
        pointer = _pod_body_pointer(
            pod,
            UInt32(LibPipeWire.SPA_TYPE_Fraction),
            2 * sizeof(UInt32),
        )
        SPA.Fraction(
            unsafe_load(Ptr{UInt32}(pointer)),
            unsafe_load(Ptr{UInt32}(pointer + sizeof(UInt32))),
        )
    end
end

function pod_value(::Type{SPA.Pointer{T}}, pod::Pod) where {T}
    data = pod.data
    return GC.@preserve data begin
        pointer = _pod_body_pointer(
            pod,
            UInt32(LibPipeWire.SPA_TYPE_Pointer),
            2 * sizeof(UInt32) + sizeof(UInt),
        )
        pointer_type = unsafe_load(Ptr{UInt32}(pointer))
        padding = unsafe_load(Ptr{UInt32}(pointer + sizeof(UInt32)))
        address = unsafe_load(Ptr{UInt}(pointer + 2 * sizeof(UInt32)))
        iszero(padding) || throw(ArgumentError("an SPA pointer POD has nonzero padding"))
        SPA.Pointer(pointer_type, Ptr{T}(address))
    end
end

function _pod_array_header(pod::Pod)
    actual_type = pod_type(pod)
    expected_type = UInt32(LibPipeWire.SPA_TYPE_Array)
    actual_type == expected_type || throw(
        ArgumentError("expected SPA POD type $expected_type, received $actual_type"),
    )
    data = pod.data
    header_size = sizeof(LibPipeWire.spa_pod)
    body_size = length(data) - header_size
    body_size >= header_size || throw(ArgumentError("an SPA array POD has no child header"))
    child = GC.@preserve data unsafe_load(
        Ptr{LibPipeWire.spa_pod}(pointer(data) + header_size),
    )
    return child, body_size - header_size
end

function pod_value(::Type{SPA.Array{T}}, pod::Pod) where {T}
    expected_child_type = _pod_fixed_type(T)
    expected_child_size = _pod_fixed_size(T)
    child, values_size = _pod_array_header(pod)
    child.type == expected_child_type || throw(
        ArgumentError(
            "expected SPA array child type $expected_child_type, received $(child.type)",
        ),
    )
    child.size == expected_child_size || throw(
        ArgumentError(
            "expected SPA array child size $expected_child_size, received $(child.size)",
        ),
    )
    values_size % expected_child_size == 0 ||
        throw(ArgumentError("the SPA array POD contains a partial child value"))

    values = Vector{T}(undef, values_size ÷ expected_child_size)
    data = pod.data
    values_offset = 2 * sizeof(LibPipeWire.spa_pod)
    GC.@preserve data for index in eachindex(values)
        values[index] = _load_pod_fixed(
            T,
            pointer(data) + values_offset + (index - 1) * expected_child_size,
        )
    end
    return SPA._owned_array(values)
end

function pod_value(::Type{SPA.Array}, pod::Pod)
    child, _ = _pod_array_header(pod)
    child.type == LibPipeWire.SPA_TYPE_Bool && return pod_value(SPA.Array{Bool}, pod)
    child.type == LibPipeWire.SPA_TYPE_Id && return pod_value(SPA.Array{SPA.Id}, pod)
    child.type == LibPipeWire.SPA_TYPE_Int && return pod_value(SPA.Array{Int32}, pod)
    child.type == LibPipeWire.SPA_TYPE_Long && return pod_value(SPA.Array{Int64}, pod)
    child.type == LibPipeWire.SPA_TYPE_Float && return pod_value(SPA.Array{Float32}, pod)
    child.type == LibPipeWire.SPA_TYPE_Double && return pod_value(SPA.Array{Float64}, pod)
    child.type == LibPipeWire.SPA_TYPE_Rectangle &&
        return pod_value(SPA.Array{SPA.Rectangle}, pod)
    child.type == LibPipeWire.SPA_TYPE_Fraction &&
        return pod_value(SPA.Array{SPA.Fraction}, pod)
    child.type == LibPipeWire.SPA_TYPE_Fd && return pod_value(SPA.Array{SPA.Fd}, pod)
    throw(ArgumentError("SPA array child type $(child.type) is not supported"))
end

function _pod_choice_header(pod::Pod)
    actual_type = pod_type(pod)
    expected_type = UInt32(LibPipeWire.SPA_TYPE_Choice)
    actual_type == expected_type || throw(
        ArgumentError("expected SPA POD type $expected_type, received $actual_type"),
    )
    data = pod.data
    body_offset = sizeof(LibPipeWire.spa_pod)
    choice_header_size = 2 * sizeof(UInt32) + sizeof(LibPipeWire.spa_pod)
    body_size = length(data) - body_offset
    body_size >= choice_header_size ||
        throw(ArgumentError("an SPA choice POD has no complete choice header"))
    kind_value, flags, child = GC.@preserve data begin
        body_pointer = pointer(data) + body_offset
        (
            unsafe_load(Ptr{UInt32}(body_pointer)),
            unsafe_load(Ptr{UInt32}(body_pointer + sizeof(UInt32))),
            unsafe_load(Ptr{LibPipeWire.spa_pod}(body_pointer + 2 * sizeof(UInt32))),
        )
    end
    kind = try
        SPA.ChoiceKind(kind_value)
    catch error
        error isa ArgumentError || rethrow()
        throw(ArgumentError("unknown SPA choice kind $kind_value"))
    end
    return kind, flags, child, body_size - choice_header_size
end

function pod_value(::Type{SPA.Choice{T}}, pod::Pod) where {T}
    expected_child_type = _pod_fixed_type(T)
    expected_child_size = _pod_fixed_size(T)
    kind, flags, child, values_size = _pod_choice_header(pod)
    child.type == expected_child_type || throw(
        ArgumentError(
            "expected SPA choice child type $expected_child_type, received $(child.type)",
        ),
    )
    child.size == expected_child_size || throw(
        ArgumentError(
            "expected SPA choice child size $expected_child_size, received $(child.size)",
        ),
    )
    values_size % expected_child_size == 0 ||
        throw(ArgumentError("the SPA choice POD contains a partial child value"))

    values = Vector{T}(undef, values_size ÷ expected_child_size)
    data = pod.data
    values_offset = 3 * sizeof(LibPipeWire.spa_pod)
    GC.@preserve data for index in eachindex(values)
        values[index] = _load_pod_fixed(
            T,
            pointer(data) + values_offset + (index - 1) * expected_child_size,
        )
    end
    return SPA._owned_choice(kind, flags, values)
end

function pod_value(::Type{SPA.Choice}, pod::Pod)
    _, _, child, _ = _pod_choice_header(pod)
    child.type == LibPipeWire.SPA_TYPE_Bool && return pod_value(SPA.Choice{Bool}, pod)
    child.type == LibPipeWire.SPA_TYPE_Id && return pod_value(SPA.Choice{SPA.Id}, pod)
    child.type == LibPipeWire.SPA_TYPE_Int && return pod_value(SPA.Choice{Int32}, pod)
    child.type == LibPipeWire.SPA_TYPE_Long && return pod_value(SPA.Choice{Int64}, pod)
    child.type == LibPipeWire.SPA_TYPE_Float && return pod_value(SPA.Choice{Float32}, pod)
    child.type == LibPipeWire.SPA_TYPE_Double && return pod_value(SPA.Choice{Float64}, pod)
    child.type == LibPipeWire.SPA_TYPE_Rectangle &&
        return pod_value(SPA.Choice{SPA.Rectangle}, pod)
    child.type == LibPipeWire.SPA_TYPE_Fraction &&
        return pod_value(SPA.Choice{SPA.Fraction}, pod)
    child.type == LibPipeWire.SPA_TYPE_Fd && return pod_value(SPA.Choice{SPA.Fd}, pod)
    throw(ArgumentError("SPA choice child type $(child.type) is not supported"))
end

function pod_value(::Type{SPA.Struct}, pod::Pod)
    actual_type = pod_type(pod)
    expected_type = UInt32(LibPipeWire.SPA_TYPE_Struct)
    actual_type == expected_type || throw(
        ArgumentError("expected SPA POD type $expected_type, received $actual_type"),
    )

    data = pod.data
    offset = sizeof(LibPipeWire.spa_pod)
    values = Pod[]
    while offset < length(data)
        length(data) - offset >= sizeof(LibPipeWire.spa_pod) ||
            throw(ArgumentError("the SPA struct POD contains a partial child header"))
        child = GC.@preserve data unsafe_load(
            Ptr{LibPipeWire.spa_pod}(pointer(data) + offset),
        )
        child_size = sizeof(LibPipeWire.spa_pod) + Int(child.size)
        padded_size = (child_size + 7) & -8
        offset + padded_size <= length(data) ||
            throw(ArgumentError("the SPA struct POD contains a truncated child"))
        push!(values, Pod(@view data[(offset + 1):(offset + child_size)]))
        offset += padded_size
    end
    return SPA._owned_struct(values)
end

function pod_value(::Type{SPA.Object}, pod::Pod)
    actual_type = pod_type(pod)
    expected_type = UInt32(LibPipeWire.SPA_TYPE_Object)
    actual_type == expected_type || throw(
        ArgumentError("expected SPA POD type $expected_type, received $actual_type"),
    )

    data = pod.data
    pod_header_size = sizeof(LibPipeWire.spa_pod)
    object_body_size = 2 * sizeof(UInt32)
    length(data) >= pod_header_size + object_body_size ||
        throw(ArgumentError("an SPA object POD has no complete object header"))
    object_type, id = GC.@preserve data begin
        body_pointer = pointer(data) + pod_header_size
        (
            unsafe_load(Ptr{UInt32}(body_pointer)),
            unsafe_load(Ptr{UInt32}(body_pointer + sizeof(UInt32))),
        )
    end

    offset = pod_header_size + object_body_size
    properties = SPA.Property[]
    while offset < length(data)
        property_header_size = 2 * sizeof(UInt32) + pod_header_size
        length(data) - offset >= property_header_size ||
            throw(ArgumentError("the SPA object POD contains a partial property header"))
        key, flags, child = GC.@preserve data begin
            property_pointer = pointer(data) + offset
            (
                unsafe_load(Ptr{UInt32}(property_pointer)),
                unsafe_load(Ptr{UInt32}(property_pointer + sizeof(UInt32))),
                unsafe_load(
                    Ptr{LibPipeWire.spa_pod}(property_pointer + 2 * sizeof(UInt32)),
                ),
            )
        end
        child_size = pod_header_size + Int(child.size)
        padded_child_size = (child_size + 7) & -8
        offset + 2 * sizeof(UInt32) + padded_child_size <= length(data) ||
            throw(ArgumentError("the SPA object POD contains a truncated property value"))
        child_start = offset + 2 * sizeof(UInt32)
        value = Pod(@view data[(child_start + 1):(child_start + child_size)])
        push!(properties, SPA.Property(key, value; flags=flags))
        offset += 2 * sizeof(UInt32) + padded_child_size
    end
    return SPA._owned_object(object_type, id, properties)
end

pod_value(::Type{SPA.Parameter}, pod::Pod) = SPA.Parameter(pod_value(SPA.Object, pod))
pod_value(::Type{SPA.Command}, pod::Pod) = SPA.Command(pod_value(SPA.Object, pod))
pod_value(::Type{SPA.Event}, pod::Pod) = SPA.Event(pod_value(SPA.Object, pod))

function _parameter_int(value, description::AbstractString)
    value isa Integer || return value
    typemin(Int32) <= value <= typemax(Int32) ||
        throw(ArgumentError("$description is outside Int32 range"))
    return Int32(value)
end

function _parameter_int64(value, description::AbstractString)
    value isa Integer || return value
    typemin(Int64) <= value <= typemax(Int64) ||
        throw(ArgumentError("$description is outside Int64 range"))
    return Int64(value)
end

function _parameter_float(value, description::AbstractString)
    value isa Real || return value
    converted = Float32(value)
    isfinite(converted) || throw(ArgumentError("$description must be finite"))
    return converted
end

function _parameter_property!(properties, key, value; id::Bool=false)
    value === nothing && return properties
    converted = id && value isa Integer ? SPA.Id(value) : value
    push!(properties, SPA.Property(key, converted))
    return properties
end

"""
    buffers_param(; buffers=nothing, blocks=nothing, size=nothing,
                    stride=nothing, align=nothing, data_types=nothing,
                    metadata_types=nothing, page_size_hint=nothing,
                    id=SPA_PARAM_Buffers)

Build a typed SPA buffer-layout parameter. Integer fields use their native
`Int32` representation; callers may also supply `SPA.Choice` values for
negotiation.

`page_size_hint` is advisory. PipeWireAO falls back to ordinary pages when the
requested huge-page allocation is unavailable.
"""
function buffers_param(;
    buffers=nothing,
    blocks=nothing,
    size=nothing,
    stride=nothing,
    align=nothing,
    data_types=nothing,
    metadata_types=nothing,
    page_size_hint::Union{Nothing,SPA.PageSizeHint}=nothing,
    id::Integer=LibPipeWire.SPA_PARAM_Buffers,
)
    properties = SPA.Property[]
    for (key, value, description) in (
        (LibPipeWire.SPA_PARAM_BUFFERS_buffers, buffers, "buffer count"),
        (LibPipeWire.SPA_PARAM_BUFFERS_blocks, blocks, "buffer block count"),
        (LibPipeWire.SPA_PARAM_BUFFERS_size, size, "buffer size"),
        (LibPipeWire.SPA_PARAM_BUFFERS_stride, stride, "buffer stride"),
        (LibPipeWire.SPA_PARAM_BUFFERS_align, align, "buffer alignment"),
        (LibPipeWire.SPA_PARAM_BUFFERS_dataType, data_types, "buffer data-type mask"),
        (
            LibPipeWire.SPA_PARAM_BUFFERS_metaType,
            metadata_types,
            "buffer metadata-type mask",
        ),
    )
        _parameter_property!(properties, key, _parameter_int(value, description))
    end
    _parameter_property!(
        properties,
        LibPipeWire.SPA_PARAM_BUFFERS_pageSizeHint,
        page_size_hint === nothing ? nothing : SPA.Id(UInt32(page_size_hint)),
    )
    return SPA.Parameter(LibPipeWire.SPA_TYPE_OBJECT_ParamBuffers, id, properties)
end

"Build a typed SPA buffer-metadata parameter."
function metadata_param(
    type;
    size=nothing,
    features=nothing,
    id::Integer=LibPipeWire.SPA_PARAM_Meta,
)
    properties = SPA.Property[]
    _parameter_property!(properties, LibPipeWire.SPA_PARAM_META_type, type; id=true)
    _parameter_property!(
        properties,
        LibPipeWire.SPA_PARAM_META_size,
        _parameter_int(size, "metadata size"),
    )
    _parameter_property!(
        properties,
        LibPipeWire.SPA_PARAM_META_features,
        _parameter_int(features, "metadata features"),
    )
    return SPA.Parameter(LibPipeWire.SPA_TYPE_OBJECT_ParamMeta, id, properties)
end

"Request native Version 1 progressive metadata on every negotiated buffer."
progressive_metadata_param(; id::Integer=LibPipeWire.SPA_PARAM_Meta) = metadata_param(
    SPA.META_PROGRESSIVE;
    size=_PROGRESSIVE_SIZE,
    features=_PROGRESSIVE_FEATURE_VERSION_1,
    id,
)

"Build a typed SPA I/O-area parameter."
function io_param(
    type;
    size=nothing,
    id::Integer=LibPipeWire.SPA_PARAM_IO,
)
    properties = SPA.Property[]
    _parameter_property!(properties, LibPipeWire.SPA_PARAM_IO_id, type; id=true)
    _parameter_property!(
        properties,
        LibPipeWire.SPA_PARAM_IO_size,
        _parameter_int(size, "I/O area size"),
    )
    return SPA.Parameter(LibPipeWire.SPA_TYPE_OBJECT_ParamIO, id, properties)
end

"Build a typed SPA latency-report parameter."
function latency_param(
    direction;
    min_quantum=nothing,
    max_quantum=nothing,
    min_rate=nothing,
    max_rate=nothing,
    min_ns=nothing,
    max_ns=nothing,
    id::Integer=LibPipeWire.SPA_PARAM_Latency,
)
    properties = SPA.Property[]
    _parameter_property!(properties, LibPipeWire.SPA_PARAM_LATENCY_direction, direction; id=true)
    _parameter_property!(
        properties,
        LibPipeWire.SPA_PARAM_LATENCY_minQuantum,
        _parameter_float(min_quantum, "minimum latency quantum"),
    )
    _parameter_property!(
        properties,
        LibPipeWire.SPA_PARAM_LATENCY_maxQuantum,
        _parameter_float(max_quantum, "maximum latency quantum"),
    )
    _parameter_property!(
        properties,
        LibPipeWire.SPA_PARAM_LATENCY_minRate,
        _parameter_int(min_rate, "minimum latency rate"),
    )
    _parameter_property!(
        properties,
        LibPipeWire.SPA_PARAM_LATENCY_maxRate,
        _parameter_int(max_rate, "maximum latency rate"),
    )
    _parameter_property!(
        properties,
        LibPipeWire.SPA_PARAM_LATENCY_minNs,
        _parameter_int64(min_ns, "minimum latency nanoseconds"),
    )
    _parameter_property!(
        properties,
        LibPipeWire.SPA_PARAM_LATENCY_maxNs,
        _parameter_int64(max_ns, "maximum latency nanoseconds"),
    )
    return SPA.Parameter(LibPipeWire.SPA_TYPE_OBJECT_ParamLatency, id, properties)
end

"Build a typed SPA processing-latency parameter."
function process_latency_param(;
    quantum=nothing,
    rate=nothing,
    ns=nothing,
    id::Integer=LibPipeWire.SPA_PARAM_ProcessLatency,
)
    properties = SPA.Property[]
    _parameter_property!(
        properties,
        LibPipeWire.SPA_PARAM_PROCESS_LATENCY_quantum,
        _parameter_float(quantum, "processing latency quantum"),
    )
    _parameter_property!(
        properties,
        LibPipeWire.SPA_PARAM_PROCESS_LATENCY_rate,
        _parameter_int(rate, "processing latency rate"),
    )
    _parameter_property!(
        properties,
        LibPipeWire.SPA_PARAM_PROCESS_LATENCY_ns,
        _parameter_int64(ns, "processing latency nanoseconds"),
    )
    return SPA.Parameter(LibPipeWire.SPA_TYPE_OBJECT_ParamProcessLatency, id, properties)
end

"Build a typed SPA direction-tag parameter from string pairs."
function tag_param(
    direction,
    entries;
    id::Integer=LibPipeWire.SPA_PARAM_Tag,
)
    pairs = collect(entries)
    length(pairs) <= typemax(Int32) || throw(ArgumentError("the SPA tag has too many entries"))
    fields = Pod[Pod(Int32(length(pairs)))]
    for entry in pairs
        push!(fields, Pod(String(first(entry))))
        push!(fields, Pod(String(last(entry))))
    end
    properties = SPA.Property[
        SPA.Property(LibPipeWire.SPA_PARAM_TAG_direction, SPA.Id(direction)),
        SPA.Property(
            LibPipeWire.SPA_PARAM_TAG_info,
            SPA.Struct(fields);
            flags=SPA.PROPERTY_HINT_DICT,
        ),
    ]
    return SPA.Parameter(LibPipeWire.SPA_TYPE_OBJECT_ParamTag, id, properties)
end

"Build an owned SPA node command."
node_command(id::Integer, properties=()) =
    SPA.Command(LibPipeWire.SPA_TYPE_COMMAND_Node, id, properties)

"Build an owned SPA device command."
device_command(id::Integer, properties=()) =
    SPA.Command(LibPipeWire.SPA_TYPE_COMMAND_Device, id, properties)

"Build an owned SPA node event."
node_event(id::Integer, properties=()) =
    SPA.Event(LibPipeWire.SPA_TYPE_EVENT_Node, id, properties)

"Build an owned SPA device event."
device_event(id::Integer, properties=()) =
    SPA.Event(LibPipeWire.SPA_TYPE_EVENT_Device, id, properties)

function pod_value(::Type{SPA.Sequence}, pod::Pod)
    actual_type = pod_type(pod)
    expected_type = UInt32(LibPipeWire.SPA_TYPE_Sequence)
    actual_type == expected_type || throw(
        ArgumentError("expected SPA POD type $expected_type, received $actual_type"),
    )

    data = pod.data
    pod_header_size = sizeof(LibPipeWire.spa_pod)
    sequence_body_size = 2 * sizeof(UInt32)
    length(data) >= pod_header_size + sequence_body_size ||
        throw(ArgumentError("an SPA sequence POD has no complete sequence header"))
    unit, padding = GC.@preserve data begin
        body_pointer = pointer(data) + pod_header_size
        (
            unsafe_load(Ptr{UInt32}(body_pointer)),
            unsafe_load(Ptr{UInt32}(body_pointer + sizeof(UInt32))),
        )
    end
    iszero(padding) || throw(ArgumentError("an SPA sequence POD has nonzero padding"))

    offset = pod_header_size + sequence_body_size
    controls = SPA.Control[]
    while offset < length(data)
        control_header_size = 2 * sizeof(UInt32) + pod_header_size
        length(data) - offset >= control_header_size ||
            throw(ArgumentError("the SPA sequence POD contains a partial control header"))
        control_offset, control_type, child = GC.@preserve data begin
            control_pointer = pointer(data) + offset
            (
                unsafe_load(Ptr{UInt32}(control_pointer)),
                unsafe_load(Ptr{UInt32}(control_pointer + sizeof(UInt32))),
                unsafe_load(
                    Ptr{LibPipeWire.spa_pod}(control_pointer + 2 * sizeof(UInt32)),
                ),
            )
        end
        child_size = pod_header_size + Int(child.size)
        padded_child_size = (child_size + 7) & -8
        offset + 2 * sizeof(UInt32) + padded_child_size <= length(data) ||
            throw(ArgumentError("the SPA sequence POD contains a truncated control value"))
        child_start = offset + 2 * sizeof(UInt32)
        value = Pod(@view data[(child_start + 1):(child_start + child_size)])
        push!(controls, SPA.Control(control_offset, control_type, value))
        offset += 2 * sizeof(UInt32) + padded_child_size
    end
    return SPA._owned_sequence(unit, controls)
end

function pod_value(pod::Pod)
    type = pod_type(pod)
    type == LibPipeWire.SPA_TYPE_None && return pod_value(Nothing, pod)
    type == LibPipeWire.SPA_TYPE_Bool && return pod_value(Bool, pod)
    type == LibPipeWire.SPA_TYPE_Id && return pod_value(SPA.Id, pod)
    type == LibPipeWire.SPA_TYPE_Int && return pod_value(Int32, pod)
    type == LibPipeWire.SPA_TYPE_Long && return pod_value(Int64, pod)
    type == LibPipeWire.SPA_TYPE_Float && return pod_value(Float32, pod)
    type == LibPipeWire.SPA_TYPE_Double && return pod_value(Float64, pod)
    type == LibPipeWire.SPA_TYPE_String && return pod_value(String, pod)
    type == LibPipeWire.SPA_TYPE_Bytes && return pod_value(SPA.Bytes, pod)
    type == LibPipeWire.SPA_TYPE_Bitmap && return pod_value(SPA.Bitmap, pod)
    type == LibPipeWire.SPA_TYPE_Rectangle && return pod_value(SPA.Rectangle, pod)
    type == LibPipeWire.SPA_TYPE_Fraction && return pod_value(SPA.Fraction, pod)
    type == LibPipeWire.SPA_TYPE_Fd && return pod_value(SPA.Fd, pod)
    type == LibPipeWire.SPA_TYPE_Array && return pod_value(SPA.Array, pod)
    type == LibPipeWire.SPA_TYPE_Struct && return pod_value(SPA.Struct, pod)
    type == LibPipeWire.SPA_TYPE_Choice && return pod_value(SPA.Choice, pod)
    type == LibPipeWire.SPA_TYPE_Object && return pod_value(SPA.Object, pod)
    type == LibPipeWire.SPA_TYPE_Sequence && return pod_value(SPA.Sequence, pod)
    type == LibPipeWire.SPA_TYPE_Pointer && return pod_value(SPA.Pointer{Cvoid}, pod)
    throw(ArgumentError("SPA POD type $type is not a supported value"))
end

function _pad_pod!(data::Vector{UInt8})
    append!(data, zeros(UInt8, mod(-length(data), 8)))
    return data
end

function _pod_property!(data, key::UInt32, type::UInt32, value::UInt32)
    _append_bits!(data, key)
    _append_bits!(data, UInt32(0))
    _append_bits!(data, UInt32(sizeof(value)))
    _append_bits!(data, type)
    _append_bits!(data, value)
    return _pad_pod!(data)
end

function _pod_int_property!(data, key::UInt32, value::Integer)
    typemin(Int32) <= value <= typemax(Int32) ||
        throw(ArgumentError("the SPA integer property is outside Int32 range"))
    _append_bits!(data, key)
    _append_bits!(data, UInt32(0))
    _append_bits!(data, UInt32(sizeof(Int32)))
    _append_bits!(data, UInt32(LibPipeWire.SPA_TYPE_Int))
    _append_bits!(data, Int32(value))
    return _pad_pod!(data)
end

function _pod_id_array_property!(data, key::UInt32, values)
    _append_bits!(data, key)
    _append_bits!(data, UInt32(0))
    _append_bits!(data, UInt32(8 + sizeof(UInt32) * length(values)))
    _append_bits!(data, UInt32(LibPipeWire.SPA_TYPE_Array))
    _append_bits!(data, UInt32(sizeof(UInt32)))
    _append_bits!(data, UInt32(LibPipeWire.SPA_TYPE_Id))
    for value in values
        _append_bits!(data, UInt32(value))
    end
    return _pad_pod!(data)
end

function _set_pod_body_size!(data::Vector{UInt8})
    body_size = UInt32(length(data) - sizeof(LibPipeWire.spa_pod))
    GC.@preserve data unsafe_store!(Ptr{UInt32}(pointer(data)), body_size)
    return data
end

"""
    audio_format(; format=Audio.F32, rate=48000, channels=2,
                   position=nothing, id=SPA_PARAM_EnumFormat) -> Pod

Build a fixed raw-audio SPA format parameter. When `position` is omitted,
mono and stereo channel positions are supplied automatically; formats with
more channels are left unpositioned unless positions are given explicitly.
"""
function audio_format(;
    format::Audio.Format=Audio.F32,
    rate::Integer=48_000,
    channels::Integer=2,
    position=nothing,
    id::Integer=LibPipeWire.SPA_PARAM_EnumFormat,
)
    rate > 0 || throw(ArgumentError("audio sample rate must be positive"))
    channels > 0 || throw(ArgumentError("audio channel count must be positive"))
    channels <= 64 || throw(ArgumentError("at most 64 audio channels are supported"))

    positions = if position === nothing
        channels == 1 ? Audio.Channel[Audio.MONO] :
        channels == 2 ? Audio.Channel[Audio.FL, Audio.FR] : Audio.Channel[]
    else
        Audio.Channel[
            value isa Audio.Channel ? value : Audio.Channel(value) for value in position
        ]
    end
    isempty(positions) || length(positions) == channels || throw(
        ArgumentError("the number of audio channel positions must equal channels"),
    )

    data = UInt8[]
    _append_bits!(data, UInt32(0))
    _append_bits!(data, UInt32(LibPipeWire.SPA_TYPE_Object))
    _append_bits!(data, UInt32(LibPipeWire.SPA_TYPE_OBJECT_Format))
    _append_bits!(data, UInt32(id))
    _pod_property!(
        data,
        UInt32(LibPipeWire.SPA_FORMAT_mediaType),
        UInt32(LibPipeWire.SPA_TYPE_Id),
        UInt32(LibPipeWire.SPA_MEDIA_TYPE_audio),
    )
    _pod_property!(
        data,
        UInt32(LibPipeWire.SPA_FORMAT_mediaSubtype),
        UInt32(LibPipeWire.SPA_TYPE_Id),
        UInt32(LibPipeWire.SPA_MEDIA_SUBTYPE_raw),
    )
    _pod_property!(
        data,
        UInt32(LibPipeWire.SPA_FORMAT_AUDIO_format),
        UInt32(LibPipeWire.SPA_TYPE_Id),
        UInt32(format),
    )
    _pod_int_property!(data, UInt32(LibPipeWire.SPA_FORMAT_AUDIO_rate), rate)
    _pod_int_property!(data, UInt32(LibPipeWire.SPA_FORMAT_AUDIO_channels), channels)
    isempty(positions) || _pod_id_array_property!(
        data,
        UInt32(LibPipeWire.SPA_FORMAT_AUDIO_position),
        positions,
    )
    _set_pod_body_size!(data)
    return Pod(data)
end

function _video_int32(value::Integer, name::AbstractString)
    typemin(Int32) <= value <= typemax(Int32) ||
        throw(ArgumentError("$name is outside Int32 range"))
    return Int32(value)
end

function _video_property!(properties, key, value; flags=0)
    value === nothing || push!(properties, SPA.Property(key, value; flags=flags))
    return properties
end

_optional_spa_id(value::Nothing) = nothing
_optional_spa_id(value::Integer) = SPA.Id(value)

"""
    video_format(; format=Video.RGBA, size=SPA.Rectangle(640, 480),
                   framerate=SPA.Fraction(30, 1), kwargs...) -> Pod

Build a fixed raw-video SPA format parameter. Optional raw-video fields are
omitted when set to `nothing`. A supplied DRM modifier is marked mandatory, as
required by PipeWire's raw-video format builder.
"""
function video_format(;
    format::Video.Format=Video.RGBA,
    size::SPA.Rectangle=SPA.Rectangle(640, 480),
    framerate::Union{Nothing,SPA.Fraction}=SPA.Fraction(30, 1),
    modifier::Union{Nothing,Integer}=nothing,
    max_framerate::Union{Nothing,SPA.Fraction}=nothing,
    views::Union{Nothing,Integer}=nothing,
    interlace_mode::Union{Nothing,Integer}=nothing,
    pixel_aspect_ratio::Union{Nothing,SPA.Fraction}=nothing,
    multiview_mode::Union{Nothing,Integer}=nothing,
    multiview_flags::Union{Nothing,Integer}=nothing,
    chroma_site::Union{Nothing,Integer}=nothing,
    color_range::Union{Nothing,Integer}=nothing,
    color_matrix::Union{Nothing,Integer}=nothing,
    transfer_function::Union{Nothing,Integer}=nothing,
    color_primaries::Union{Nothing,Integer}=nothing,
    id::Integer=LibPipeWire.SPA_PARAM_EnumFormat,
)
    size.width > 0 && size.height > 0 ||
        throw(ArgumentError("video width and height must be positive"))
    framerate === nothing || framerate.denom > 0 ||
        throw(ArgumentError("video framerate denominator must be positive"))
    max_framerate === nothing || max_framerate.denom > 0 ||
        throw(ArgumentError("maximum video framerate denominator must be positive"))
    pixel_aspect_ratio === nothing || pixel_aspect_ratio.denom > 0 ||
        throw(ArgumentError("pixel aspect ratio denominator must be positive"))
    modifier === nothing || typemin(Int64) <= modifier <= typemax(Int64) ||
        throw(ArgumentError("video modifier is outside Int64 range"))

    properties = SPA.Property[
        SPA.Property(LibPipeWire.SPA_FORMAT_mediaType, SPA.Id(LibPipeWire.SPA_MEDIA_TYPE_video)),
        SPA.Property(
            LibPipeWire.SPA_FORMAT_mediaSubtype,
            SPA.Id(LibPipeWire.SPA_MEDIA_SUBTYPE_raw),
        ),
        SPA.Property(LibPipeWire.SPA_FORMAT_VIDEO_format, SPA.Id(UInt32(format))),
        SPA.Property(LibPipeWire.SPA_FORMAT_VIDEO_size, size),
    ]
    _video_property!(properties, LibPipeWire.SPA_FORMAT_VIDEO_framerate, framerate)
    _video_property!(
        properties,
        LibPipeWire.SPA_FORMAT_VIDEO_modifier,
        modifier === nothing ? nothing : Int64(modifier);
        flags=SPA.PROPERTY_MANDATORY,
    )
    _video_property!(properties, LibPipeWire.SPA_FORMAT_VIDEO_maxFramerate, max_framerate)
    _video_property!(
        properties,
        LibPipeWire.SPA_FORMAT_VIDEO_views,
        views === nothing ? nothing : _video_int32(views, "video view count"),
    )
    _video_property!(
        properties,
        LibPipeWire.SPA_FORMAT_VIDEO_interlaceMode,
        _optional_spa_id(interlace_mode),
    )
    _video_property!(
        properties,
        LibPipeWire.SPA_FORMAT_VIDEO_pixelAspectRatio,
        pixel_aspect_ratio,
    )
    _video_property!(
        properties,
        LibPipeWire.SPA_FORMAT_VIDEO_multiviewMode,
        _optional_spa_id(multiview_mode),
    )
    _video_property!(
        properties,
        LibPipeWire.SPA_FORMAT_VIDEO_multiviewFlags,
        _optional_spa_id(multiview_flags),
    )
    _video_property!(
        properties,
        LibPipeWire.SPA_FORMAT_VIDEO_chromaSite,
        _optional_spa_id(chroma_site),
    )
    _video_property!(
        properties,
        LibPipeWire.SPA_FORMAT_VIDEO_colorRange,
        _optional_spa_id(color_range),
    )
    _video_property!(
        properties,
        LibPipeWire.SPA_FORMAT_VIDEO_colorMatrix,
        _optional_spa_id(color_matrix),
    )
    _video_property!(
        properties,
        LibPipeWire.SPA_FORMAT_VIDEO_transferFunction,
        _optional_spa_id(transfer_function),
    )
    _video_property!(
        properties,
        LibPipeWire.SPA_FORMAT_VIDEO_colorPrimaries,
        _optional_spa_id(color_primaries),
    )
    return Pod(SPA.Object(LibPipeWire.SPA_TYPE_OBJECT_Format, id, properties))
end

"A validated fixed-rank native ndarray format."
struct NdArrayFormat{N}
    element_type::NdArray.ElementType
    shape::NTuple{N,Int32}
    layout::NdArray.Layout
    rate::Union{Nothing,SPA.Fraction}

    function NdArrayFormat{N}(
        element_type::NdArray.ElementType,
        shape::NTuple{N,Int32},
        layout::NdArray.Layout,
        rate::Union{Nothing,SPA.Fraction},
        ::Val{:validated},
    ) where {N}
        return new{N}(element_type, shape, layout, rate)
    end
end

function _ndarray_element_size(element_type::NdArray.ElementType)
    element_type in (
        NdArray.BOOL8,
        NdArray.I8,
        NdArray.U8,
        NdArray.F8_E4M3FN,
        NdArray.F8_E4M3FNUZ,
        NdArray.F8_E5M2,
        NdArray.F8_E5M2FNUZ,
    ) && return 1
    element_type in (
        NdArray.I16_LE,
        NdArray.U16_LE,
        NdArray.F16_LE,
        NdArray.BF16_LE,
    ) && return 2
    element_type in (
        NdArray.I32_LE,
        NdArray.U32_LE,
        NdArray.F32_LE,
        NdArray.COMPLEX_F16_LE,
        NdArray.COMPLEX_BF16_LE,
    ) && return 4
    element_type in (
        NdArray.I64_LE,
        NdArray.U64_LE,
        NdArray.F64_LE,
        NdArray.COMPLEX_F32_LE,
    ) && return 8
    element_type in (
        NdArray.I128_LE,
        NdArray.U128_LE,
        NdArray.F128_LE,
        NdArray.COMPLEX_F64_LE,
    ) && return 16
    element_type == NdArray.COMPLEX_F128_LE && return 32
    throw(ArgumentError("unsupported ndarray element type $element_type"))
end

function _checked_ndarray_size(element_type::NdArray.ElementType, shape)
    count = 1
    try
        for dimension in shape
            count = Base.checked_mul(count, Int(dimension))
        end
        return count, Base.checked_mul(count, _ndarray_element_size(element_type))
    catch error
        error isa OverflowError || rethrow()
        throw(ArgumentError("ndarray payload size overflows Int"))
    end
end

"""
    NdArrayFormat(element_type, shape; layout, rate=nothing)

Describe a packed native ndarray. `shape` is in logical axis order and every
dimension must be positive. Version 1 supports contiguous `ROW_MAJOR` and
`COLUMN_MAJOR` storage only.
"""
function NdArrayFormat(
    element_type::NdArray.ElementType,
    shape;
    layout::NdArray.Layout,
    rate::Union{Nothing,SPA.Fraction}=nothing,
)
    dimensions = Tuple(shape)
    isempty(dimensions) && throw(ArgumentError("an ndarray must have at least one axis"))
    converted = ntuple(length(dimensions)) do axis
        dimension = dimensions[axis]
        dimension isa Integer || throw(
            ArgumentError("ndarray dimension $axis is not an integer"),
        )
        0 < dimension <= typemax(Int32) || throw(
            ArgumentError("ndarray dimension $axis must fit a positive Int32"),
        )
        Int32(dimension)
    end
    layout in (NdArray.ROW_MAJOR, NdArray.COLUMN_MAJOR) ||
        throw(ArgumentError("unsupported ndarray layout $layout"))
    rate === nothing || (rate.num > 0 && rate.denom > 0) ||
        throw(ArgumentError("ndarray rate must be a positive fraction"))
    _checked_ndarray_size(element_type, converted)
    return NdArrayFormat{length(converted)}(
        element_type,
        converted,
        layout,
        rate,
        Val(:validated),
    )
end

"A rank-one ndarray profile with canonical row-major layout."
struct VectorFormat
    element_type::NdArray.ElementType
    length::Int32
    rate::Union{Nothing,SPA.Fraction}

    function VectorFormat(
        element_type::NdArray.ElementType,
        length::Integer;
        rate::Union{Nothing,SPA.Fraction}=nothing,
    )
        format = NdArrayFormat(element_type, (length,); layout=NdArray.ROW_MAJOR, rate)
        return new(format.element_type, only(format.shape), format.rate)
    end
end

"A rank-two ndarray profile whose shape is `(rows, columns)`."
struct MatrixFormat
    element_type::NdArray.ElementType
    rows::Int32
    columns::Int32
    layout::NdArray.Layout
    rate::Union{Nothing,SPA.Fraction}

    function MatrixFormat(
        element_type::NdArray.ElementType,
        rows::Integer,
        columns::Integer;
        layout::NdArray.Layout=NdArray.COLUMN_MAJOR,
        rate::Union{Nothing,SPA.Fraction}=nothing,
    )
        format = NdArrayFormat(element_type, (rows, columns); layout, rate)
        return new(
            format.element_type,
            format.shape[1],
            format.shape[2],
            format.layout,
            format.rate,
        )
    end
end

NdArrayFormat(format::VectorFormat) = NdArrayFormat(
    format.element_type,
    (format.length,);
    layout=NdArray.ROW_MAJOR,
    rate=format.rate,
)
NdArrayFormat(format::MatrixFormat) = NdArrayFormat(
    format.element_type,
    (format.rows, format.columns);
    layout=format.layout,
    rate=format.rate,
)

"""
    NdArrayRateChoice(kind, values)

Describe additional rates for an enumerated ndarray format. `kind` must be
`SPA.CHOICE_ENUM`, `SPA.CHOICE_RANGE`, or `SPA.CHOICE_STEP`. Enum values are
additional discrete alternatives; range values are `(min, max)`; step values
are `(min, max, step)`. The default rate comes from the fixed format.
"""
struct NdArrayRateChoice
    kind::SPA.ChoiceKind
    values::Vector{SPA.Fraction}

    function NdArrayRateChoice(kind::SPA.ChoiceKind, values)
        kind in (SPA.CHOICE_ENUM, SPA.CHOICE_RANGE, SPA.CHOICE_STEP) || throw(
            ArgumentError("unsupported ndarray rate choice $kind"),
        )
        converted = collect(SPA.Fraction, values)
        if kind == SPA.CHOICE_ENUM
            isempty(converted) && throw(
                ArgumentError("an enumerated ndarray rate choice requires an alternative"),
            )
        else
            required = kind == SPA.CHOICE_RANGE ? 2 : 3
            length(converted) == required || throw(
                ArgumentError("ndarray rate choice $kind requires $required values"),
            )
        end
        all(rate -> rate.num > 0 && rate.denom > 0, converted) || throw(
            ArgumentError("ndarray rate choices must contain positive fractions"),
        )
        return new(kind, converted)
    end
end

function _fraction_compare(left::SPA.Fraction, right::SPA.Fraction)
    left_product = UInt64(left.num) * UInt64(right.denom)
    right_product = UInt64(right.num) * UInt64(left.denom)
    return cmp(left_product, right_product)
end

function _validate_ndarray_rate_choice(
    rate::Union{Nothing,SPA.Fraction},
    choice::Union{Nothing,NdArrayRateChoice},
)
    choice === nothing && return nothing
    rate === nothing && throw(ArgumentError("an ndarray rate choice requires a default rate"))
    if choice.kind in (SPA.CHOICE_RANGE, SPA.CHOICE_STEP)
        minimum, maximum = choice.values[1:2]
        _fraction_compare(minimum, rate) <= 0 &&
            _fraction_compare(rate, maximum) <= 0 || throw(
            ArgumentError("the default ndarray rate is outside the offered range"),
        )
    end
    return nothing
end

"""
    NdArrayEnumFormat(default; element_type_alternatives=[],
                      layout_alternatives=[], rate_choice=nothing)

Describe one exact ndarray shape with negotiable element type, layout, and
rate. Alternatives are validated before a POD is built. Offer a separate
`NdArrayEnumFormat` for every supported shape.
"""
struct NdArrayEnumFormat{N}
    default::NdArrayFormat{N}
    element_type_alternatives::Vector{NdArray.ElementType}
    layout_alternatives::Vector{NdArray.Layout}
    rate_choice::Union{Nothing,NdArrayRateChoice}

    function NdArrayEnumFormat(
        default::NdArrayFormat{N};
        element_type_alternatives=NdArray.ElementType[],
        layout_alternatives=NdArray.Layout[],
        rate_choice::Union{Nothing,NdArrayRateChoice}=nothing,
    ) where {N}
        elements = collect(NdArray.ElementType, element_type_alternatives)
        foreach(_ndarray_element_size, elements)
        layouts = collect(NdArray.Layout, layout_alternatives)
        all(layout -> layout in (NdArray.ROW_MAJOR, NdArray.COLUMN_MAJOR), layouts) ||
            throw(ArgumentError("an ndarray layout alternative is unsupported"))
        _validate_ndarray_rate_choice(default.rate, rate_choice)
        return new{N}(default, elements, layouts, rate_choice)
    end
end

"""
    VectorEnumFormat(default; element_type_alternatives=[], rate_choice=nothing)

Describe an enumerated vector profile. Its layout remains canonical row-major;
only element type and rate can vary.
"""
struct VectorEnumFormat
    format::NdArrayEnumFormat{1}

    function VectorEnumFormat(
        default::VectorFormat;
        element_type_alternatives=NdArray.ElementType[],
        rate_choice::Union{Nothing,NdArrayRateChoice}=nothing,
    )
        format = NdArrayEnumFormat(
            NdArrayFormat(default);
            element_type_alternatives,
            rate_choice,
        )
        return new(format)
    end
end

"""
    MatrixEnumFormat(default; element_type_alternatives=[],
                     layout_alternatives=[], rate_choice=nothing)

Describe an enumerated matrix profile with explicit row- or column-major
layout alternatives.
"""
struct MatrixEnumFormat
    format::NdArrayEnumFormat{2}

    function MatrixEnumFormat(
        default::MatrixFormat;
        element_type_alternatives=NdArray.ElementType[],
        layout_alternatives=NdArray.Layout[],
        rate_choice::Union{Nothing,NdArrayRateChoice}=nothing,
    )
        format = NdArrayEnumFormat(
            NdArrayFormat(default);
            element_type_alternatives,
            layout_alternatives,
            rate_choice,
        )
        return new(format)
    end
end

element_count(format::NdArrayFormat) = first(_checked_ndarray_size(format.element_type, format.shape))
element_count(format::Union{VectorFormat,MatrixFormat}) = element_count(NdArrayFormat(format))
payload_size(format::NdArrayFormat) = last(_checked_ndarray_size(format.element_type, format.shape))
payload_size(format::Union{VectorFormat,MatrixFormat}) = payload_size(NdArrayFormat(format))

function _ndarray_property(object::SPA.Object, key::UInt32; required::Bool=true)
    matching = filter(property -> property.key == key, object.properties)
    length(matching) <= 1 || throw(ArgumentError("duplicate ndarray property $key"))
    isempty(matching) && required && throw(ArgumentError("missing ndarray property $key"))
    return isempty(matching) ? nothing : only(matching)
end

"Parse a fixed native ndarray format parameter. Application properties are ignored."
function NdArrayFormat(parameter::SPA.Parameter)
    object = parameter.object
    object.type == LibPipeWire.SPA_TYPE_OBJECT_Format ||
        throw(ArgumentError("the SPA parameter is not a format object"))
    media_type = pod_value(SPA.Id, _ndarray_property(object, SPA.FORMAT_MEDIA_TYPE).value)
    media_type.value == SPA.MEDIA_TYPE_APPLICATION ||
        throw(ArgumentError("the format media type is not application"))
    media_subtype = pod_value(SPA.Id, _ndarray_property(object, SPA.FORMAT_MEDIA_SUBTYPE).value)
    media_subtype.value == SPA.MEDIA_SUBTYPE_NDARRAY ||
        throw(ArgumentError("the format media subtype is not ndarray"))
    element_type = NdArray.ElementType(
        pod_value(SPA.Id, _ndarray_property(object, SPA.FORMAT_NDARRAY_ELEMENT_TYPE).value).value,
    )
    shape = pod_value(
        SPA.Array{Int32},
        _ndarray_property(object, SPA.FORMAT_NDARRAY_SHAPE).value,
    ).values
    layout = NdArray.Layout(
        pod_value(SPA.Id, _ndarray_property(object, SPA.FORMAT_NDARRAY_LAYOUT).value).value,
    )
    rate_property = _ndarray_property(object, SPA.FORMAT_NDARRAY_RATE; required=false)
    rate = rate_property === nothing ? nothing : pod_value(SPA.Fraction, rate_property.value)
    return NdArrayFormat(element_type, shape; layout, rate)
end

NdArrayFormat(pod::Pod) = NdArrayFormat(pod_value(SPA.Parameter, pod))

function VectorFormat(format::NdArrayFormat{1})
    format.layout == NdArray.ROW_MAJOR || throw(
        ArgumentError("a vector must use the canonical row-major layout"),
    )
    return VectorFormat(format.element_type, only(format.shape); rate=format.rate)
end
VectorFormat(parameter::SPA.Parameter) = VectorFormat(NdArrayFormat(parameter))
VectorFormat(pod::Pod) = VectorFormat(NdArrayFormat(pod))

MatrixFormat(format::NdArrayFormat{2}) = MatrixFormat(
    format.element_type,
    format.shape[1],
    format.shape[2];
    layout=format.layout,
    rate=format.rate,
)
MatrixFormat(parameter::SPA.Parameter) = MatrixFormat(NdArrayFormat(parameter))
MatrixFormat(pod::Pod) = MatrixFormat(NdArrayFormat(pod))

function ndarray_format(format::NdArrayFormat; id::Integer=LibPipeWire.SPA_PARAM_EnumFormat)
    properties = SPA.Property[
        SPA.Property(SPA.FORMAT_MEDIA_TYPE, SPA.Id(SPA.MEDIA_TYPE_APPLICATION)),
        SPA.Property(SPA.FORMAT_MEDIA_SUBTYPE, SPA.Id(SPA.MEDIA_SUBTYPE_NDARRAY)),
        SPA.Property(SPA.FORMAT_NDARRAY_ELEMENT_TYPE, SPA.Id(UInt32(format.element_type))),
        SPA.Property(SPA.FORMAT_NDARRAY_SHAPE, SPA.Array(collect(format.shape))),
        SPA.Property(SPA.FORMAT_NDARRAY_LAYOUT, SPA.Id(UInt32(format.layout))),
    ]
    format.rate === nothing ||
        push!(properties, SPA.Property(SPA.FORMAT_NDARRAY_RATE, format.rate))
    return Pod(SPA.Object(LibPipeWire.SPA_TYPE_OBJECT_Format, id, properties))
end

function _ndarray_enum_id(default::Integer, alternatives)
    values = SPA.Id[SPA.Id(default), SPA.Id(default)]
    append!(values, SPA.Id(UInt32(value)) for value in alternatives)
    return SPA.Choice(SPA.CHOICE_ENUM, values)
end

function _ndarray_enum_rate(default::SPA.Fraction, choice::NdArrayRateChoice)
    values = if choice.kind == SPA.CHOICE_ENUM
        SPA.Fraction[default, default, choice.values...]
    else
        SPA.Fraction[default, choice.values...]
    end
    return SPA.Choice(choice.kind, values)
end

function ndarray_format(
    format::NdArrayEnumFormat;
    id::Integer=LibPipeWire.SPA_PARAM_EnumFormat,
)
    default = format.default
    element_type = isempty(format.element_type_alternatives) ?
                   SPA.Id(UInt32(default.element_type)) :
                   _ndarray_enum_id(
        UInt32(default.element_type),
        format.element_type_alternatives,
    )
    layout = isempty(format.layout_alternatives) ?
             SPA.Id(UInt32(default.layout)) :
             _ndarray_enum_id(UInt32(default.layout), format.layout_alternatives)
    properties = SPA.Property[
        SPA.Property(SPA.FORMAT_MEDIA_TYPE, SPA.Id(SPA.MEDIA_TYPE_APPLICATION)),
        SPA.Property(SPA.FORMAT_MEDIA_SUBTYPE, SPA.Id(SPA.MEDIA_SUBTYPE_NDARRAY)),
        SPA.Property(SPA.FORMAT_NDARRAY_ELEMENT_TYPE, element_type),
        SPA.Property(SPA.FORMAT_NDARRAY_SHAPE, SPA.Array(collect(default.shape))),
        SPA.Property(SPA.FORMAT_NDARRAY_LAYOUT, layout),
    ]
    if default.rate !== nothing
        rate = format.rate_choice === nothing ?
               default.rate :
               _ndarray_enum_rate(default.rate, format.rate_choice)
        push!(properties, SPA.Property(SPA.FORMAT_NDARRAY_RATE, rate))
    end
    return Pod(SPA.Object(LibPipeWire.SPA_TYPE_OBJECT_Format, id, properties))
end

ndarray_format(format::Union{VectorEnumFormat,MatrixEnumFormat}; kwargs...) =
    ndarray_format(format.format; kwargs...)

ndarray_format(format::Union{VectorFormat,MatrixFormat}; kwargs...) =
    ndarray_format(NdArrayFormat(format); kwargs...)
function ndarray_format(
    element_type::NdArray.ElementType,
    shape;
    layout::NdArray.Layout,
    rate::Union{Nothing,SPA.Fraction}=nothing,
    id::Integer=LibPipeWire.SPA_PARAM_EnumFormat,
)
    return ndarray_format(NdArrayFormat(element_type, shape; layout, rate); id)
end

vector_format(format::VectorFormat; kwargs...) = ndarray_format(format; kwargs...)
vector_format(format::VectorEnumFormat; kwargs...) = ndarray_format(format; kwargs...)
function vector_format(
    element_type::NdArray.ElementType,
    length::Integer;
    rate::Union{Nothing,SPA.Fraction}=nothing,
    id::Integer=LibPipeWire.SPA_PARAM_EnumFormat,
)
    return vector_format(VectorFormat(element_type, length; rate); id)
end

matrix_format(format::MatrixFormat; kwargs...) = ndarray_format(format; kwargs...)
matrix_format(format::MatrixEnumFormat; kwargs...) = ndarray_format(format; kwargs...)
function matrix_format(
    element_type::NdArray.ElementType,
    rows::Integer,
    columns::Integer;
    layout::NdArray.Layout=NdArray.COLUMN_MAJOR,
    rate::Union{Nothing,SPA.Fraction}=nothing,
    id::Integer=LibPipeWire.SPA_PARAM_EnumFormat,
)
    return matrix_format(MatrixFormat(element_type, rows, columns; layout, rate); id)
end

"Build a typed SPA raw-audio format parameter."
audio_format_param(; kwargs...) = pod_value(SPA.Parameter, audio_format(; kwargs...))

"Build a typed SPA raw-video format parameter."
video_format_param(; kwargs...) = pod_value(SPA.Parameter, video_format(; kwargs...))

"Build a typed native ndarray format parameter."
ndarray_format_param(args...; kwargs...) = pod_value(SPA.Parameter, ndarray_format(args...; kwargs...))

"Build a typed native vector format parameter."
vector_format_param(args...; kwargs...) = pod_value(SPA.Parameter, vector_format(args...; kwargs...))

"Build a typed native matrix format parameter."
matrix_format_param(args...; kwargs...) = pod_value(SPA.Parameter, matrix_format(args...; kwargs...))


"""
    AudioInfoRaw(format::Pod)
    AudioInfoRaw(format::SPA.Parameter)

Parse a fixed raw-audio format into an owned snapshot corresponding to
PipeWire's `spa_audio_info_raw`. `format` and `position` retain their native
numeric values so formats and channel positions added by newer PipeWire
versions remain representable. Compare them with `UInt32(Audio.F32)` and
`UInt32(Audio.FL)`, for example.

When the position property is absent or does not contain exactly `channels`
entries, [`Audio.FLAG_UNPOSITIONED`](@ref) is set and `position` contains one
zero value per channel.
"""
struct AudioInfoRaw
    format::UInt32
    flags::UInt32
    rate::UInt32
    channels::UInt32
    position::Vector{UInt32}
end

Base.:(==)(left::AudioInfoRaw, right::AudioInfoRaw) =
    left.format == right.format &&
    left.flags == right.flags &&
    left.rate == right.rate &&
    left.channels == right.channels &&
    left.position == right.position
Base.isequal(left::AudioInfoRaw, right::AudioInfoRaw) =
    isequal(left.format, right.format) &&
    isequal(left.flags, right.flags) &&
    isequal(left.rate, right.rate) &&
    isequal(left.channels, right.channels) &&
    isequal(left.position, right.position)
Base.hash(value::AudioInfoRaw, seed::UInt) = hash(
    (value.format, value.flags, value.rate, value.channels, value.position),
    seed,
)


"""
    VideoInfoRaw(format::Pod)
    VideoInfoRaw(format::SPA.Parameter)

Parse a fixed raw-video format into an owned snapshot corresponding to
PipeWire's `spa_video_info_raw`. Numeric enum fields retain their native values
so values introduced by newer PipeWire versions remain representable.
"""
struct VideoInfoRaw
    format::UInt32
    flags::UInt32
    modifier::UInt64
    size::SPA.Rectangle
    framerate::SPA.Fraction
    max_framerate::SPA.Fraction
    views::UInt32
    interlace_mode::UInt32
    pixel_aspect_ratio::SPA.Fraction
    multiview_mode::UInt32
    multiview_flags::UInt32
    chroma_site::UInt32
    color_range::UInt32
    color_matrix::UInt32
    transfer_function::UInt32
    color_primaries::UInt32
end

Base.:(==)(left::VideoInfoRaw, right::VideoInfoRaw) = left === right
Base.isequal(left::VideoInfoRaw, right::VideoInfoRaw) = left === right
Base.hash(value::VideoInfoRaw, seed::UInt) = hash(
    ntuple(index -> getfield(value, index), fieldcount(VideoInfoRaw)),
    seed,
)


function _format_property(object::SPA.Object, key::Integer)
    return get(object, key, nothing)
end


function _format_value(::Type{T}, object::SPA.Object, key::Integer, default::T) where {T}
    property = _format_property(object, key)
    property === nothing && return default
    return pod_value(T, property.value)
end


function _format_id(object::SPA.Object, key::Integer, default::UInt32=UInt32(0))
    value = _format_value(SPA.Id, object, key, SPA.Id(default))
    return value.value
end


function _raw_format_object(format::Pod, media_type::UInt32)
    object = pod_value(SPA.Object, format)
    object.type == LibPipeWire.SPA_TYPE_OBJECT_Format || throw(
        ArgumentError("the SPA object is not a format"),
    )
    actual_media_type = _format_id(object, LibPipeWire.SPA_FORMAT_mediaType)
    actual_media_type == media_type || throw(
        ArgumentError("the SPA format has the wrong media type"),
    )
    media_subtype = _format_id(object, LibPipeWire.SPA_FORMAT_mediaSubtype)
    media_subtype == LibPipeWire.SPA_MEDIA_SUBTYPE_raw || throw(
        ArgumentError("the SPA format media subtype is not raw"),
    )
    return object
end


function AudioInfoRaw(format::Pod)
    object = _raw_format_object(format, UInt32(LibPipeWire.SPA_MEDIA_TYPE_audio))
    native_format = _format_id(object, LibPipeWire.SPA_FORMAT_AUDIO_format)
    rate_value = _format_value(
        Int32,
        object,
        LibPipeWire.SPA_FORMAT_AUDIO_rate,
        Int32(0),
    )
    channel_value = _format_value(
        Int32,
        object,
        LibPipeWire.SPA_FORMAT_AUDIO_channels,
        Int32(0),
    )
    rate_value >= 0 || throw(ArgumentError("the raw-audio sample rate is negative"))
    channel_value >= 0 || throw(ArgumentError("the raw-audio channel count is negative"))
    channels = UInt32(channel_value)

    property = _format_property(object, LibPipeWire.SPA_FORMAT_AUDIO_position)
    positioned = property !== nothing
    positions = if positioned
        values = pod_value(SPA.Array{SPA.Id}, property.value).values
        positioned = length(values) == channels
        positioned ? UInt32[value.value for value in values] : zeros(UInt32, channels)
    else
        zeros(UInt32, channels)
    end
    flags = positioned ? UInt32(0) : Audio.FLAG_UNPOSITIONED
    return AudioInfoRaw(native_format, flags, UInt32(rate_value), channels, positions)
end


AudioInfoRaw(format::SPA.Parameter) = AudioInfoRaw(Pod(format))


function VideoInfoRaw(format::Pod)
    object = _raw_format_object(format, UInt32(LibPipeWire.SPA_MEDIA_TYPE_video))
    modifier_property = _format_property(object, LibPipeWire.SPA_FORMAT_VIDEO_modifier)
    modifier = if modifier_property === nothing
        UInt64(0)
    else
        reinterpret(UInt64, pod_value(Int64, modifier_property.value))
    end
    flags = if modifier_property === nothing
        UInt32(0)
    else
        result = Video.FLAG_MODIFIER
        modifier_property.flags & SPA.PROPERTY_DONT_FIXATE == 0 ||
            (result |= Video.FLAG_MODIFIER_FIXATION_REQUIRED)
        result
    end

    views_value = _format_value(
        Int32,
        object,
        LibPipeWire.SPA_FORMAT_VIDEO_views,
        Int32(0),
    )
    views_value >= 0 || throw(ArgumentError("the raw-video view count is negative"))
    return VideoInfoRaw(
        _format_id(object, LibPipeWire.SPA_FORMAT_VIDEO_format),
        flags,
        modifier,
        _format_value(
            SPA.Rectangle,
            object,
            LibPipeWire.SPA_FORMAT_VIDEO_size,
            SPA.Rectangle(0, 0),
        ),
        _format_value(
            SPA.Fraction,
            object,
            LibPipeWire.SPA_FORMAT_VIDEO_framerate,
            SPA.Fraction(0, 0),
        ),
        _format_value(
            SPA.Fraction,
            object,
            LibPipeWire.SPA_FORMAT_VIDEO_maxFramerate,
            SPA.Fraction(0, 0),
        ),
        UInt32(views_value),
        _format_id(object, LibPipeWire.SPA_FORMAT_VIDEO_interlaceMode),
        _format_value(
            SPA.Fraction,
            object,
            LibPipeWire.SPA_FORMAT_VIDEO_pixelAspectRatio,
            SPA.Fraction(0, 0),
        ),
        _format_id(object, LibPipeWire.SPA_FORMAT_VIDEO_multiviewMode),
        _format_id(object, LibPipeWire.SPA_FORMAT_VIDEO_multiviewFlags),
        _format_id(object, LibPipeWire.SPA_FORMAT_VIDEO_chromaSite),
        _format_id(object, LibPipeWire.SPA_FORMAT_VIDEO_colorRange),
        _format_id(object, LibPipeWire.SPA_FORMAT_VIDEO_colorMatrix),
        _format_id(object, LibPipeWire.SPA_FORMAT_VIDEO_transferFunction),
        _format_id(object, LibPipeWire.SPA_FORMAT_VIDEO_colorPrimaries),
    )
end


VideoInfoRaw(format::SPA.Parameter) = VideoInfoRaw(Pod(format))
