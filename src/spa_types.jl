"""
    Pod(data)

An owned SPA POD value. The constructor copies `data` and validates the POD
header. `Pod` values keep format parameters alive while they are passed to
PipeWireAO.
"""
struct Pod
    data::Vector{UInt8}

    function Pod(data::AbstractVector{UInt8})
        length(data) >= sizeof(LibPipeWire.spa_pod) ||
            throw(ArgumentError("an SPA POD must contain a complete header"))
        owned = Vector{UInt8}(data)
        header = GC.@preserve owned unsafe_load(Ptr{LibPipeWire.spa_pod}(pointer(owned)))
        header.size < (1 << 20) || throw(ArgumentError("the SPA POD body is too large"))
        total_size = sizeof(LibPipeWire.spa_pod) + Int(header.size)
        total_size <= length(owned) || throw(ArgumentError("the SPA POD body is truncated"))
        resize!(owned, total_size)
        return new(owned)
    end
end

Base.:(==)(left::Pod, right::Pod) = left.data == right.data
Base.isequal(left::Pod, right::Pod) = isequal(left.data, right.data)
Base.hash(value::Pod, seed::UInt) = hash(value.data, seed)
Base.sizeof(pod::Pod) = length(pod.data)

"SPA POD value types that need wrappers to preserve their wire-level meaning."
module SPA

using ..PipeWireAO: Pod
using ..LibPipeWire

export Array,
    Bitmap,
    Bytes,
    CHOICE_ENUM,
    CHOICE_FLAGS,
    CHOICE_NONE,
    CHOICE_RANGE,
    CHOICE_STEP,
    Choice,
    ChoiceKind,
    Command,
    Control,
    Event,
    Fd,
    Fraction,
    Id,
    Object,
    PAGE_SIZE_HUGE_1GB,
    PAGE_SIZE_HUGE_2MB,
    PAGE_SIZE_HUGE_DEFAULT,
    PAGE_SIZE_NORMAL,
    Parameter,
    PageSizeHint,
    PROPERTY_DONT_FIXATE,
    PROPERTY_DROP,
    PROPERTY_HARDWARE,
    PROPERTY_HINT_DICT,
    PROPERTY_MANDATORY,
    PROPERTY_READONLY,
    Pointer,
    Property,
    Rectangle,
    Sequence,
    Struct

include("spa_ids.jl")

"A best-effort preference for the backing page size of shared buffer memory."
@enum PageSizeHint::UInt32 begin
    PAGE_SIZE_NORMAL = LibPipeWire.SPA_BUFFER_PAGE_SIZE_NORMAL
    PAGE_SIZE_HUGE_DEFAULT = LibPipeWire.SPA_BUFFER_PAGE_SIZE_HUGE_DEFAULT
    PAGE_SIZE_HUGE_2MB = LibPipeWire.SPA_BUFFER_PAGE_SIZE_HUGE_2MB
    PAGE_SIZE_HUGE_1GB = LibPipeWire.SPA_BUFFER_PAGE_SIZE_HUGE_1GB
end

"An enumerated SPA POD ID."
struct Id
    value::UInt32

    function Id(value::Integer)
        0 <= value <= typemax(UInt32) ||
            throw(ArgumentError("SPA ID is outside UInt32 range"))
        return new(UInt32(value))
    end
end

"A file descriptor value carried by an SPA POD."
struct Fd
    value::Int64

    function Fd(value::Integer)
        typemin(Int64) <= value <= typemax(Int64) ||
            throw(ArgumentError("SPA file descriptor is outside Int64 range"))
        return new(Int64(value))
    end
end

"An owned byte sequence carried by an SPA POD."
struct Bytes
    data::Vector{UInt8}

    Bytes(data) = new(Vector{UInt8}(data))
end

Base.:(==)(left::Bytes, right::Bytes) = left.data == right.data
Base.isequal(left::Bytes, right::Bytes) = isequal(left.data, right.data)
Base.hash(value::Bytes, seed::UInt) = hash(value.data, seed)

"An owned bitmap carried by an SPA POD."
struct Bitmap
    data::Vector{UInt8}

    function Bitmap(data)
        isempty(data) && throw(ArgumentError("an SPA bitmap must not be empty"))
        return new(Vector{UInt8}(data))
    end
end

Base.:(==)(left::Bitmap, right::Bitmap) = left.data == right.data
Base.isequal(left::Bitmap, right::Bitmap) = isequal(left.data, right.data)
Base.hash(value::Bitmap, seed::UInt) = hash(value.data, seed)

"A typed borrowed pointer carried by an SPA POD."
struct Pointer{T}
    type::UInt32
    value::Ptr{T}

    function Pointer(type::Integer, value::Ptr{T}) where {T}
        0 <= type <= typemax(UInt32) ||
            throw(ArgumentError("SPA pointer type is outside UInt32 range"))
        return new{T}(UInt32(type), value)
    end
end

"An owned homogeneous SPA POD array."
struct Array{T}
    values::Vector{T}

    function Array(values::AbstractVector{T}) where {T}
        isconcretetype(T) || throw(ArgumentError("an SPA array element type must be concrete"))
        return new{T}(Vector{T}(values))
    end

    function Array{T}(values::Vector{T}, ::Nothing) where {T}
        return new{T}(values)
    end
end

Base.:(==)(left::Array, right::Array) = left.values == right.values
Base.isequal(left::Array, right::Array) = isequal(left.values, right.values)
Base.hash(value::Array, seed::UInt) = hash(value.values, seed)

_owned_array(values::Vector{T}) where {T} = Array{T}(values, nothing)

@enum ChoiceKind::UInt32 begin
    CHOICE_NONE = LibPipeWire.SPA_CHOICE_None
    CHOICE_RANGE = LibPipeWire.SPA_CHOICE_Range
    CHOICE_STEP = LibPipeWire.SPA_CHOICE_Step
    CHOICE_ENUM = LibPipeWire.SPA_CHOICE_Enum
    CHOICE_FLAGS = LibPipeWire.SPA_CHOICE_Flags
end

function _check_choice_length(kind::ChoiceKind, length::Int)
    if kind == CHOICE_ENUM
        length >= 2 || throw(
            ArgumentError("SPA choice kind $kind requires at least 2 values"),
        )
        return nothing
    end
    required = kind == CHOICE_RANGE ? 3 : kind == CHOICE_STEP ? 4 : 1
    length == required || throw(
        ArgumentError("SPA choice kind $kind requires exactly $required value(s)"),
    )
    return nothing
end

"An owned homogeneous SPA POD choice."
struct Choice{T}
    kind::ChoiceKind
    flags::UInt32
    values::Vector{T}

    function Choice(
        kind::ChoiceKind,
        values::AbstractVector{T};
        flags::Integer=0,
    ) where {T}
        isconcretetype(T) || throw(ArgumentError("an SPA choice value type must be concrete"))
        0 <= flags <= typemax(UInt32) ||
            throw(ArgumentError("SPA choice flags are outside UInt32 range"))
        _check_choice_length(kind, length(values))
        return new{T}(kind, UInt32(flags), Vector{T}(values))
    end

    function Choice{T}(
        kind::ChoiceKind,
        flags::UInt32,
        values::Vector{T},
        ::Nothing,
    ) where {T}
        return new{T}(kind, flags, values)
    end
end

Base.:(==)(left::Choice, right::Choice) =
    left.kind == right.kind && left.flags == right.flags && left.values == right.values
Base.isequal(left::Choice, right::Choice) =
    isequal(left.kind, right.kind) &&
    isequal(left.flags, right.flags) &&
    isequal(left.values, right.values)
Base.hash(value::Choice, seed::UInt) = hash((value.kind, value.flags, value.values), seed)

function _owned_choice(kind::ChoiceKind, flags::UInt32, values::Vector{T}) where {T}
    _check_choice_length(kind, length(values))
    return Choice{T}(kind, flags, values, nothing)
end

"A width and height carried by an SPA POD."
struct Rectangle
    width::UInt32
    height::UInt32

    function Rectangle(width::Integer, height::Integer)
        0 <= width <= typemax(UInt32) ||
            throw(ArgumentError("SPA rectangle width is outside UInt32 range"))
        0 <= height <= typemax(UInt32) ||
            throw(ArgumentError("SPA rectangle height is outside UInt32 range"))
        return new(UInt32(width), UInt32(height))
    end
end

"A numerator and denominator carried by an SPA POD."
struct Fraction
    num::UInt32
    denom::UInt32

    function Fraction(num::Integer, denom::Integer)
        0 <= num <= typemax(UInt32) ||
            throw(ArgumentError("SPA fraction numerator is outside UInt32 range"))
        0 <= denom <= typemax(UInt32) ||
            throw(ArgumentError("SPA fraction denominator is outside UInt32 range"))
        return new(UInt32(num), UInt32(denom))
    end
end

"An owned heterogeneous SPA POD struct."
struct Struct
    values::Vector{Pod}

    Struct(values) = new(collect(Pod, values))

    Struct(values::Vector{Pod}, ::Nothing) = new(values)
end

Struct(values::Pod...) = Struct(values)
Base.:(==)(left::Struct, right::Struct) = left.values == right.values
Base.isequal(left::Struct, right::Struct) = isequal(left.values, right.values)
Base.hash(value::Struct, seed::UInt) = hash(value.values, seed)

_owned_struct(values::Vector{Pod}) = Struct(values, nothing)

const PROPERTY_READONLY = UInt32(1 << 0)
const PROPERTY_HARDWARE = UInt32(1 << 1)
const PROPERTY_HINT_DICT = UInt32(1 << 2)
const PROPERTY_MANDATORY = UInt32(1 << 3)
const PROPERTY_DONT_FIXATE = UInt32(1 << 4)
const PROPERTY_DROP = UInt32(1 << 5)

"An owned property carried by an SPA POD object."
struct Property
    key::UInt32
    flags::UInt32
    value::Pod

    function Property(key::Integer, value::Pod; flags::Integer=0)
        0 <= key <= typemax(UInt32) ||
            throw(ArgumentError("SPA property key is outside UInt32 range"))
        0 <= flags <= typemax(UInt32) ||
            throw(ArgumentError("SPA property flags are outside UInt32 range"))
        return new(UInt32(key), UInt32(flags), value)
    end
end

Property(key::Integer, value; flags::Integer=0) = Property(key, Pod(value); flags=flags)
Base.:(==)(left::Property, right::Property) =
    left.key == right.key && left.flags == right.flags && left.value == right.value
Base.isequal(left::Property, right::Property) =
    isequal(left.key, right.key) &&
    isequal(left.flags, right.flags) &&
    isequal(left.value, right.value)
Base.hash(value::Property, seed::UInt) = hash((value.key, value.flags, value.value), seed)

"""
An owned SPA POD object.

Use `object[key]`, `get(object, key, default)`, and `haskey(object, key)` to
access properties by their native `UInt32` key.
"""
struct Object
    type::UInt32
    id::UInt32
    properties::Vector{Property}

    function Object(type::Integer, id::Integer, properties)
        0 <= type <= typemax(UInt32) ||
            throw(ArgumentError("SPA object type is outside UInt32 range"))
        0 <= id <= typemax(UInt32) ||
            throw(ArgumentError("SPA object ID is outside UInt32 range"))
        return new(UInt32(type), UInt32(id), collect(Property, properties))
    end

    function Object(
        type::UInt32,
        id::UInt32,
        properties::Vector{Property},
        ::Nothing,
    )
        return new(type, id, properties)
    end
end

Object(type::Integer, id::Integer, properties::Property...) = Object(type, id, properties)
Base.:(==)(left::Object, right::Object) =
    left.type == right.type && left.id == right.id && left.properties == right.properties
Base.isequal(left::Object, right::Object) =
    isequal(left.type, right.type) &&
    isequal(left.id, right.id) &&
    isequal(left.properties, right.properties)
Base.hash(value::Object, seed::UInt) = hash((value.type, value.id, value.properties), seed)

function Base.get(object::Object, key::Integer, default)
    0 <= key <= typemax(UInt32) || return default
    native_key = UInt32(key)
    for property in object.properties
        property.key == native_key && return property
    end
    return default
end

function Base.getindex(object::Object, key::Integer)
    property = get(object, key, nothing)
    property === nothing && throw(KeyError(key))
    return property
end

Base.haskey(object::Object, key::Integer) = get(object, key, nothing) !== nothing

_owned_object(type::UInt32, id::UInt32, properties::Vector{Property}) =
    Object(type, id, properties, nothing)

"An owned, validated SPA parameter object."
struct Parameter
    object::Object

    function Parameter(object::Object)
        LibPipeWire.SPA_TYPE_OBJECT_START <= object.type <
        LibPipeWire._SPA_TYPE_OBJECT_LAST ||
            throw(ArgumentError("the SPA object type is not a parameter type"))
        object.id <= LibPipeWire.SPA_PARAM_PeerCapability ||
            throw(ArgumentError("the SPA object ID is not a parameter ID"))
        return new(object)
    end
end

Parameter(type::Integer, id::Integer, properties) = Parameter(Object(type, id, properties))
Parameter(type::Integer, id::Integer, properties::Property...) =
    Parameter(Object(type, id, properties))

"An owned, validated SPA command object."
struct Command
    object::Object

    function Command(object::Object)
        LibPipeWire.SPA_TYPE_COMMAND_START < object.type <
        LibPipeWire._SPA_TYPE_COMMAND_LAST ||
            throw(ArgumentError("the SPA object type is not a command type"))
        return new(object)
    end
end

Command(type::Integer, id::Integer, properties) = Command(Object(type, id, properties))
Command(type::Integer, id::Integer, properties::Property...) =
    Command(Object(type, id, properties))

"An owned, validated SPA event object."
struct Event
    object::Object

    function Event(object::Object)
        LibPipeWire.SPA_TYPE_EVENT_START < object.type < LibPipeWire._SPA_TYPE_EVENT_LAST ||
            throw(ArgumentError("the SPA object type is not an event type"))
        return new(object)
    end
end

Event(type::Integer, id::Integer, properties) = Event(Object(type, id, properties))
Event(type::Integer, id::Integer, properties::Property...) = Event(Object(type, id, properties))

for Type in (Parameter, Command, Event)
    @eval begin
        Base.:(==)(left::$Type, right::$Type) = left.object == right.object
        Base.isequal(left::$Type, right::$Type) = isequal(left.object, right.object)
        Base.hash(value::$Type, seed::UInt) = hash(value.object, seed)
    end
end

"An owned timed control carried by an SPA POD sequence."
struct Control
    offset::UInt32
    type::UInt32
    value::Pod

    function Control(offset::Integer, type::Integer, value::Pod)
        0 <= offset <= typemax(UInt32) ||
            throw(ArgumentError("SPA control offset is outside UInt32 range"))
        0 <= type <= typemax(UInt32) ||
            throw(ArgumentError("SPA control type is outside UInt32 range"))
        return new(UInt32(offset), UInt32(type), value)
    end
end

Control(offset::Integer, type::Integer, value) = Control(offset, type, Pod(value))
Base.:(==)(left::Control, right::Control) =
    left.offset == right.offset && left.type == right.type && left.value == right.value
Base.isequal(left::Control, right::Control) =
    isequal(left.offset, right.offset) &&
    isequal(left.type, right.type) &&
    isequal(left.value, right.value)
Base.hash(value::Control, seed::UInt) = hash((value.offset, value.type, value.value), seed)

"An owned SPA POD sequence of timed controls."
struct Sequence
    unit::UInt32
    controls::Vector{Control}

    function Sequence(unit::Integer, controls)
        0 <= unit <= typemax(UInt32) ||
            throw(ArgumentError("SPA sequence unit is outside UInt32 range"))
        return new(UInt32(unit), collect(Control, controls))
    end

    function Sequence(unit::UInt32, controls::Vector{Control}, ::Nothing)
        return new(unit, controls)
    end
end

Sequence(unit::Integer, controls::Control...) = Sequence(unit, controls)
Base.:(==)(left::Sequence, right::Sequence) =
    left.unit == right.unit && left.controls == right.controls
Base.isequal(left::Sequence, right::Sequence) =
    isequal(left.unit, right.unit) && isequal(left.controls, right.controls)
Base.hash(value::Sequence, seed::UInt) = hash((value.unit, value.controls), seed)

_owned_sequence(unit::UInt32, controls::Vector{Control}) = Sequence(unit, controls, nothing)

end # module SPA

"""
Audio sample formats and channel positions used by [`audio_format`](@ref).

For example, `Audio.F32` is native-endian 32-bit floating-point audio and
`Audio.FL`/`Audio.FR` are the front-left and front-right channel positions.
"""
module Audio

using ..LibPipeWire

"Set when raw-audio channel positions are unspecified."
const FLAG_UNPOSITIONED = UInt32(1 << 0)

@enum Format::UInt32 begin
    UNKNOWN = LibPipeWire.SPA_AUDIO_FORMAT_UNKNOWN
    S8 = LibPipeWire.SPA_AUDIO_FORMAT_S8
    U8 = LibPipeWire.SPA_AUDIO_FORMAT_U8
    S16 = LibPipeWire.SPA_AUDIO_FORMAT_S16
    S24 = LibPipeWire.SPA_AUDIO_FORMAT_S24
    S32 = LibPipeWire.SPA_AUDIO_FORMAT_S32
    F32 = LibPipeWire.SPA_AUDIO_FORMAT_F32
    F64 = LibPipeWire.SPA_AUDIO_FORMAT_F64
    U8P = LibPipeWire.SPA_AUDIO_FORMAT_U8P
    S16P = LibPipeWire.SPA_AUDIO_FORMAT_S16P
    S24P = LibPipeWire.SPA_AUDIO_FORMAT_S24P
    S32P = LibPipeWire.SPA_AUDIO_FORMAT_S32P
    F32P = LibPipeWire.SPA_AUDIO_FORMAT_F32P
    F64P = LibPipeWire.SPA_AUDIO_FORMAT_F64P
end

@enum Channel::UInt32 begin
    CHANNEL_UNKNOWN = LibPipeWire.SPA_AUDIO_CHANNEL_UNKNOWN
    NA = LibPipeWire.SPA_AUDIO_CHANNEL_NA
    MONO = LibPipeWire.SPA_AUDIO_CHANNEL_MONO
    FL = LibPipeWire.SPA_AUDIO_CHANNEL_FL
    FR = LibPipeWire.SPA_AUDIO_CHANNEL_FR
    FC = LibPipeWire.SPA_AUDIO_CHANNEL_FC
    LFE = LibPipeWire.SPA_AUDIO_CHANNEL_LFE
    SL = LibPipeWire.SPA_AUDIO_CHANNEL_SL
    SR = LibPipeWire.SPA_AUDIO_CHANNEL_SR
    RL = LibPipeWire.SPA_AUDIO_CHANNEL_RL
    RR = LibPipeWire.SPA_AUDIO_CHANNEL_RR
end

end # module Audio

"""
Native element representations and contiguous layouts used by
[`ndarray_format`](@ref).

Shapes are always expressed in logical axis order. `ROW_MAJOR` makes the last
axis contiguous; `COLUMN_MAJOR` makes the first axis contiguous and therefore
matches ordinary Julia arrays.
"""
module NdArray

using ..LibPipeWire

@enum ElementType::UInt32 begin
    UNKNOWN = LibPipeWire.SPA_ELEMENT_TYPE_UNKNOWN
    BOOL8 = LibPipeWire.SPA_ELEMENT_TYPE_BOOL8
    I8 = LibPipeWire.SPA_ELEMENT_TYPE_I8
    U8 = LibPipeWire.SPA_ELEMENT_TYPE_U8
    I16_LE = LibPipeWire.SPA_ELEMENT_TYPE_I16_LE
    U16_LE = LibPipeWire.SPA_ELEMENT_TYPE_U16_LE
    I32_LE = LibPipeWire.SPA_ELEMENT_TYPE_I32_LE
    U32_LE = LibPipeWire.SPA_ELEMENT_TYPE_U32_LE
    I64_LE = LibPipeWire.SPA_ELEMENT_TYPE_I64_LE
    U64_LE = LibPipeWire.SPA_ELEMENT_TYPE_U64_LE
    I128_LE = LibPipeWire.SPA_ELEMENT_TYPE_I128_LE
    U128_LE = LibPipeWire.SPA_ELEMENT_TYPE_U128_LE
    F8_E4M3FN = LibPipeWire.SPA_ELEMENT_TYPE_F8_E4M3FN
    F8_E4M3FNUZ = LibPipeWire.SPA_ELEMENT_TYPE_F8_E4M3FNUZ
    F8_E5M2 = LibPipeWire.SPA_ELEMENT_TYPE_F8_E5M2
    F8_E5M2FNUZ = LibPipeWire.SPA_ELEMENT_TYPE_F8_E5M2FNUZ
    F16_LE = LibPipeWire.SPA_ELEMENT_TYPE_F16_LE
    BF16_LE = LibPipeWire.SPA_ELEMENT_TYPE_BF16_LE
    F32_LE = LibPipeWire.SPA_ELEMENT_TYPE_F32_LE
    F64_LE = LibPipeWire.SPA_ELEMENT_TYPE_F64_LE
    F128_LE = LibPipeWire.SPA_ELEMENT_TYPE_F128_LE
    COMPLEX_F16_LE = LibPipeWire.SPA_ELEMENT_TYPE_COMPLEX_F16_LE
    COMPLEX_BF16_LE = LibPipeWire.SPA_ELEMENT_TYPE_COMPLEX_BF16_LE
    COMPLEX_F32_LE = LibPipeWire.SPA_ELEMENT_TYPE_COMPLEX_F32_LE
    COMPLEX_F64_LE = LibPipeWire.SPA_ELEMENT_TYPE_COMPLEX_F64_LE
    COMPLEX_F128_LE = LibPipeWire.SPA_ELEMENT_TYPE_COMPLEX_F128_LE
    START_CUSTOM = LibPipeWire.SPA_ELEMENT_TYPE_START_CUSTOM
end

@enum Layout::UInt32 begin
    LAYOUT_UNKNOWN = LibPipeWire.SPA_NDARRAY_LAYOUT_UNKNOWN
    ROW_MAJOR = LibPipeWire.SPA_NDARRAY_LAYOUT_ROW_MAJOR
    COLUMN_MAJOR = LibPipeWire.SPA_NDARRAY_LAYOUT_COLUMN_MAJOR
end

end # module NdArray

"""
Raw video pixel formats used by [`video_format`](@ref).
"""
module Video

using ..LibPipeWire

const FLAG_VARIABLE_FPS = UInt32(LibPipeWire.SPA_VIDEO_FLAG_VARIABLE_FPS)
const FLAG_PREMULTIPLIED_ALPHA =
    UInt32(LibPipeWire.SPA_VIDEO_FLAG_PREMULTIPLIED_ALPHA)
const FLAG_MODIFIER = UInt32(LibPipeWire.SPA_VIDEO_FLAG_MODIFIER)
const FLAG_MODIFIER_FIXATION_REQUIRED =
    UInt32(LibPipeWire.SPA_VIDEO_FLAG_MODIFIER_FIXATION_REQUIRED)

@enum Format::UInt32 begin
    UNKNOWN = LibPipeWire.SPA_VIDEO_FORMAT_UNKNOWN
    ENCODED = LibPipeWire.SPA_VIDEO_FORMAT_ENCODED
    I420 = LibPipeWire.SPA_VIDEO_FORMAT_I420
    YV12 = LibPipeWire.SPA_VIDEO_FORMAT_YV12
    YUY2 = LibPipeWire.SPA_VIDEO_FORMAT_YUY2
    UYVY = LibPipeWire.SPA_VIDEO_FORMAT_UYVY
    AYUV = LibPipeWire.SPA_VIDEO_FORMAT_AYUV
    RGBx = LibPipeWire.SPA_VIDEO_FORMAT_RGBx
    BGRx = LibPipeWire.SPA_VIDEO_FORMAT_BGRx
    xRGB = LibPipeWire.SPA_VIDEO_FORMAT_xRGB
    xBGR = LibPipeWire.SPA_VIDEO_FORMAT_xBGR
    RGBA = LibPipeWire.SPA_VIDEO_FORMAT_RGBA
    BGRA = LibPipeWire.SPA_VIDEO_FORMAT_BGRA
    ARGB = LibPipeWire.SPA_VIDEO_FORMAT_ARGB
    ABGR = LibPipeWire.SPA_VIDEO_FORMAT_ABGR
    RGB = LibPipeWire.SPA_VIDEO_FORMAT_RGB
    BGR = LibPipeWire.SPA_VIDEO_FORMAT_BGR
    Y41B = LibPipeWire.SPA_VIDEO_FORMAT_Y41B
    Y42B = LibPipeWire.SPA_VIDEO_FORMAT_Y42B
    YVYU = LibPipeWire.SPA_VIDEO_FORMAT_YVYU
    Y444 = LibPipeWire.SPA_VIDEO_FORMAT_Y444
    v210 = LibPipeWire.SPA_VIDEO_FORMAT_v210
    v216 = LibPipeWire.SPA_VIDEO_FORMAT_v216
    NV12 = LibPipeWire.SPA_VIDEO_FORMAT_NV12
    NV21 = LibPipeWire.SPA_VIDEO_FORMAT_NV21
    GRAY8 = LibPipeWire.SPA_VIDEO_FORMAT_GRAY8
    GRAY16_BE = LibPipeWire.SPA_VIDEO_FORMAT_GRAY16_BE
    GRAY16_LE = LibPipeWire.SPA_VIDEO_FORMAT_GRAY16_LE
    v308 = LibPipeWire.SPA_VIDEO_FORMAT_v308
    RGB16 = LibPipeWire.SPA_VIDEO_FORMAT_RGB16
    BGR16 = LibPipeWire.SPA_VIDEO_FORMAT_BGR16
    RGB15 = LibPipeWire.SPA_VIDEO_FORMAT_RGB15
    BGR15 = LibPipeWire.SPA_VIDEO_FORMAT_BGR15
    UYVP = LibPipeWire.SPA_VIDEO_FORMAT_UYVP
    A420 = LibPipeWire.SPA_VIDEO_FORMAT_A420
    RGB8P = LibPipeWire.SPA_VIDEO_FORMAT_RGB8P
    YUV9 = LibPipeWire.SPA_VIDEO_FORMAT_YUV9
    YVU9 = LibPipeWire.SPA_VIDEO_FORMAT_YVU9
    IYU1 = LibPipeWire.SPA_VIDEO_FORMAT_IYU1
    ARGB64 = LibPipeWire.SPA_VIDEO_FORMAT_ARGB64
    AYUV64 = LibPipeWire.SPA_VIDEO_FORMAT_AYUV64
    r210 = LibPipeWire.SPA_VIDEO_FORMAT_r210
    I420_10BE = LibPipeWire.SPA_VIDEO_FORMAT_I420_10BE
    I420_10LE = LibPipeWire.SPA_VIDEO_FORMAT_I420_10LE
    I422_10BE = LibPipeWire.SPA_VIDEO_FORMAT_I422_10BE
    I422_10LE = LibPipeWire.SPA_VIDEO_FORMAT_I422_10LE
    Y444_10BE = LibPipeWire.SPA_VIDEO_FORMAT_Y444_10BE
    Y444_10LE = LibPipeWire.SPA_VIDEO_FORMAT_Y444_10LE
    GBR = LibPipeWire.SPA_VIDEO_FORMAT_GBR
    GBR_10BE = LibPipeWire.SPA_VIDEO_FORMAT_GBR_10BE
    GBR_10LE = LibPipeWire.SPA_VIDEO_FORMAT_GBR_10LE
    NV16 = LibPipeWire.SPA_VIDEO_FORMAT_NV16
    NV24 = LibPipeWire.SPA_VIDEO_FORMAT_NV24
    NV12_64Z32 = LibPipeWire.SPA_VIDEO_FORMAT_NV12_64Z32
    A420_10BE = LibPipeWire.SPA_VIDEO_FORMAT_A420_10BE
    A420_10LE = LibPipeWire.SPA_VIDEO_FORMAT_A420_10LE
    A422_10BE = LibPipeWire.SPA_VIDEO_FORMAT_A422_10BE
    A422_10LE = LibPipeWire.SPA_VIDEO_FORMAT_A422_10LE
    A444_10BE = LibPipeWire.SPA_VIDEO_FORMAT_A444_10BE
    A444_10LE = LibPipeWire.SPA_VIDEO_FORMAT_A444_10LE
    NV61 = LibPipeWire.SPA_VIDEO_FORMAT_NV61
    P010_10BE = LibPipeWire.SPA_VIDEO_FORMAT_P010_10BE
    P010_10LE = LibPipeWire.SPA_VIDEO_FORMAT_P010_10LE
    IYU2 = LibPipeWire.SPA_VIDEO_FORMAT_IYU2
    VYUY = LibPipeWire.SPA_VIDEO_FORMAT_VYUY
    GBRA = LibPipeWire.SPA_VIDEO_FORMAT_GBRA
    GBRA_10BE = LibPipeWire.SPA_VIDEO_FORMAT_GBRA_10BE
    GBRA_10LE = LibPipeWire.SPA_VIDEO_FORMAT_GBRA_10LE
    GBR_12BE = LibPipeWire.SPA_VIDEO_FORMAT_GBR_12BE
    GBR_12LE = LibPipeWire.SPA_VIDEO_FORMAT_GBR_12LE
    GBRA_12BE = LibPipeWire.SPA_VIDEO_FORMAT_GBRA_12BE
    GBRA_12LE = LibPipeWire.SPA_VIDEO_FORMAT_GBRA_12LE
    I420_12BE = LibPipeWire.SPA_VIDEO_FORMAT_I420_12BE
    I420_12LE = LibPipeWire.SPA_VIDEO_FORMAT_I420_12LE
    I422_12BE = LibPipeWire.SPA_VIDEO_FORMAT_I422_12BE
    I422_12LE = LibPipeWire.SPA_VIDEO_FORMAT_I422_12LE
    Y444_12BE = LibPipeWire.SPA_VIDEO_FORMAT_Y444_12BE
    Y444_12LE = LibPipeWire.SPA_VIDEO_FORMAT_Y444_12LE
    RGBA_F16 = LibPipeWire.SPA_VIDEO_FORMAT_RGBA_F16
    RGBA_F32 = LibPipeWire.SPA_VIDEO_FORMAT_RGBA_F32
    xRGB_210LE = LibPipeWire.SPA_VIDEO_FORMAT_xRGB_210LE
    xBGR_210LE = LibPipeWire.SPA_VIDEO_FORMAT_xBGR_210LE
    RGBx_102LE = LibPipeWire.SPA_VIDEO_FORMAT_RGBx_102LE
    BGRx_102LE = LibPipeWire.SPA_VIDEO_FORMAT_BGRx_102LE
    ARGB_210LE = LibPipeWire.SPA_VIDEO_FORMAT_ARGB_210LE
    ABGR_210LE = LibPipeWire.SPA_VIDEO_FORMAT_ABGR_210LE
    RGBA_102LE = LibPipeWire.SPA_VIDEO_FORMAT_RGBA_102LE
    BGRA_102LE = LibPipeWire.SPA_VIDEO_FORMAT_BGRA_102LE
end

const DSP_F32 = RGBA_F32

end # module Video
