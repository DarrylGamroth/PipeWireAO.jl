const _ARRAY_IDLE = UInt8(0)
const _ARRAY_PENDING = UInt8(1)
const _ARRAY_COMPLETE = UInt8(2)
const _ARRAY_FAILED = UInt8(3)
const _ARRAY_CLOSED = UInt8(4)

mutable struct _ArrayExchangeState{T,N}
    values::Vector{T}
    format::NdArrayFormat{N}
    schema::Union{Nothing,String}
    buffer::StreamBuffer
    phase::Threads.Atomic{UInt8}
    condition::Threads.Condition
    waiting::Threads.Atomic{Bool}
    error::Any
    started::Bool
    acknowledged::Bool
    token::UInt64
    header::Union{Nothing,BufferHeader}
    identity::Union{Nothing,AcquisitionIdentity}
    duration::Union{Nothing,UInt64}
    expected::Union{UInt64,AcquisitionIdentity}
    expected_duration::Union{Nothing,UInt64}
end

_array_element_type(::Type{Float32}) = NdArray.F32_LE
_array_element_type(::Type{UInt16}) = NdArray.U16_LE
_array_element_type(::Type{Bool}) = NdArray.BOOL8
_array_element_type(::Type{T}) where {T} = throw(ArgumentError(
    "prepared ndarray exchange supports Float32, UInt16, and Bool storage",
))

function _ArrayExchangeState(storage::Vector{T}, format::NdArrayFormat{N}, schema) where {T,N}
    Base.ENDIAN_BOM == 0x04030201 || throw(ArgumentError("prepared ndarray exchange requires a little-endian host"))
    format.element_type == _array_element_type(T) || throw(ArgumentError("storage element type differs from the wire format"))
    length(storage) == element_count(format) || throw(DimensionMismatch("storage length differs from the wire shape"))
    payload_size(format) <= typemax(Int32) || throw(ArgumentError("payload exceeds the SPA buffer-size range"))
    semantic_schema = schema === nothing ? nothing : String(schema)
    _ndarray_schema_property(semantic_schema)
    return _ArrayExchangeState{T,N}(
        copy(storage), format, semantic_schema, StreamBuffer(), Threads.Atomic{UInt8}(_ARRAY_IDLE),
        Threads.Condition(), Threads.Atomic{Bool}(false), nothing, false, false,
        UInt64(0), nothing, nothing, nothing, UInt64(0), nothing,
    )
end

"""
    NdArraySource(core, name, storage::Vector{T}, format; schema=nothing, properties=nothing)
    NdArraySink(core, name, storage::Vector{T}, format; schema=nothing, properties=nothing)

Create an inactive, prepared stream endpoint with a private copy of `storage`.
Supported pairs are `Float32`/`F32_LE`, `UInt16`/`U16_LE`, and `Bool`/`BOOL8`.
Vectors contain the packed linear wire order declared by `format`; these APIs
do not reshape or transpose logical axes. Shape, layout, rate, and schema are
negotiated exactly. The owned `stream` is public for explicit link creation.
The caller owns `core` and its loop and must dispatch that loop during waits.
Julia callbacks are ordinary client callbacks and make no hard real-time claim.
"""
struct NdArraySource{T,N,S<:Stream}
    stream::S
    state::_ArrayExchangeState{T,N}
end

struct NdArraySink{T,N,S<:Stream}
    stream::S
    state::_ArrayExchangeState{T,N}
end

_array_loop_lock(f, loop::ThreadLoop) = with_thread_loop_lock(_ -> f(), loop)
_array_loop_lock(f, ::MainLoop) = f()
_array_loop_lock(f, endpoint::Union{NdArraySource,NdArraySink}) = _array_loop_lock(f, main_loop(endpoint.stream))

function _array_notify!(state::_ArrayExchangeState)
    state.waiting[] || return nothing
    lock(state.condition) do
        notify(state.condition; all=true)
    end
    return nothing
end

function _array_fail!(state::_ArrayExchangeState, error)
    state.phase[] >= _ARRAY_FAILED && return nothing
    state.error = error
    state.phase[] = _ARRAY_FAILED
    _array_notify!(state)
    return nothing
end

function _array_require_usable(state::_ArrayExchangeState)
    phase = state.phase[]
    phase == _ARRAY_CLOSED && throw(InvalidStateException("the ndarray endpoint is closed", :closed))
    phase == _ARRAY_FAILED && throw(state.error)
    return phase
end

struct _ArrayStateChanged{S}
    state::S
end

function (callback::_ArrayStateChanged)(stream, old, current, message)
    if current == LibPipeWire.PW_STREAM_STATE_ERROR ||
       (current == LibPipeWire.PW_STREAM_STATE_UNCONNECTED && old != current)
        _array_fail!(callback.state, InvalidStateException(
            message === nothing ? "the ndarray stream disconnected" : message, :disconnected,
        ))
    end
    _array_notify!(callback.state)
    return nothing
end

struct _ArrayParamChanged{S}
    state::S
end

struct _ArrayIOChanged{S}
    state::S
end
(callback::_ArrayIOChanged)(stream, io) = _array_notify!(callback.state)

function _array_fixed_value(::Type{T}, value::Pod) where {T}
    pod_type(value) == LibPipeWire.SPA_TYPE_Choice || return value
    return Pod(_choice_none_value(T, value))
end

function _array_fixed_format(parameter::Pod)
    object = pod_value(SPA.Parameter, parameter).object
    properties = SPA.Property[]
    for property in object.properties
        value = property.value
        if property.key in (SPA.FORMAT_MEDIA_TYPE, SPA.FORMAT_MEDIA_SUBTYPE,
            SPA.FORMAT_NDARRAY_ELEMENT_TYPE, SPA.FORMAT_NDARRAY_LAYOUT)
            value = _array_fixed_value(SPA.Id, value)
        elseif property.key == SPA.FORMAT_NDARRAY_SHAPE
            value = _array_fixed_value(SPA.Array{Int32}, value)
        elseif property.key == SPA.FORMAT_NDARRAY_RATE
            value = _array_fixed_value(SPA.Fraction, value)
        end
        push!(properties, SPA.Property(property.key, value; flags=property.flags))
    end
    return SPA.Parameter(SPA.Object(object.type, object.id, properties))
end

function (callback::_ArrayParamChanged)(stream, id, parameter)
    id == SPA.PARAM_FORMAT || return nothing
    parameter === nothing && return nothing
    state = callback.state
    try
        fixed = _array_fixed_format(parameter)
        negotiated = NdArrayFormat(fixed)
        requested = state.format
        negotiated.element_type == requested.element_type && negotiated.shape == requested.shape &&
            negotiated.layout == requested.layout && negotiated.rate == requested.rate &&
            ndarray_schema(fixed) == state.schema || throw(ArgumentError("negotiated ndarray format differs from the declaration"))
        update_params!(stream, _array_buffer_parameters(state))
    catch error
        _array_fail!(state, error)
    end
    return nothing
end

function _array_buffer_parameters(state::_ArrayExchangeState)
    # Allocation stride describes data-block memory. Native ndarray peers use
    # the packed contiguous-axis size; leave it unconstrained for negotiation.
    return (
        Pod(buffers_param(buffers=2, blocks=1, size=payload_size(state.format))),
        Pod(header_metadata_param()), Pod(acquisition_metadata_param()),
    )
end

function _array_parameters(state::_ArrayExchangeState)
    return (ndarray_format(state.format; schema=state.schema), _array_buffer_parameters(state)...)
end

function _array_packed_stride(state::_ArrayExchangeState{T}) where {T}
    format = state.format
    axis = format.layout == NdArray.ROW_MAJOR ? length(format.shape) : 1
    return Int(format.shape[axis]) * sizeof(T)
end

function _array_stream(core, name, state, process, source, properties)
    defaults = Dict("node.name" => String(name), "media.type" => "Application", "media.category" => "Filter", "node.reliable" => "true")
    source && merge!(defaults, Dict("node.want-driver" => "true", "priority.driver" => "100"))
    properties === nothing || merge!(defaults, Dict(properties))
    return _array_loop_lock(main_loop(core)) do
        stream = Stream(core, name; properties=defaults, on_process=process,
            on_state_changed=_ArrayStateChanged(state), on_param_changed=_ArrayParamChanged(state),
            on_io_changed=_ArrayIOChanged(state))
        try
            # Compile the exact handler before publishing the endpoint. Its
            # first native capability notification can otherwise spend the
            # link admission budget compiling the negotiated-format branch.
            # Executing that branch here would change live stream parameters.
            precompile(stream.callbacks.on_param_changed, (typeof(stream), UInt32, Pod))
            flags = STREAM_MAP_BUFFERS | STREAM_INACTIVE | STREAM_DONT_RECONNECT | STREAM_NO_CONVERT
            source && (flags |= STREAM_DRIVER)
            connect!(stream, source ? :output : :input; flags, params=_array_parameters(state))
        catch
            close(stream)
            rethrow()
        end
        return stream
    end
end

struct _ArraySourceProcess{S}
    state::S
end

function _array_write!(state::_ArrayExchangeState{T}, buffer) where {T}
    data = buffer_data(buffer)
    copyto!(reinterpret(T, buffer_memory(data, payload_size(state.format))), state.values)
    set_chunk!(data; offset=0, size=payload_size(state.format), stride=sizeof(T))
    set_buffer_size!(buffer, element_count(state.format))
    set_buffer_header!(buffer, something(state.header))
    metadata = buffer_acquisition(buffer)
    metadata === nothing && throw(InvalidStateException("the ndarray output has no acquisition metadata", :no_metadata))
    initialize_acquisition!(metadata)
    state.identity === nothing || set_acquisition_identity!(metadata, state.identity)
    state.duration === nothing || set_acquisition_exposure_duration!(metadata, state.duration)
    return nothing
end

function (callback::_ArraySourceProcess)(stream)
    state = callback.state
    state.phase[] == _ARRAY_PENDING || return nothing
    try
        dequeue_buffer!(state.buffer, stream) || return nothing
        queued = false
        try
            _array_write!(state, state.buffer)
            queue_buffer!(state.buffer, stream)
            queued = true
            state.phase[] = _ARRAY_COMPLETE
            _array_notify!(state)
        finally
            queued || return_buffer!(state.buffer, stream)
        end
    catch error
        _array_fail!(state, error)
    end
    return nothing
end

_array_expected_sequence(expected::UInt64) = expected
_array_expected_sequence(expected::AcquisitionIdentity) = expected.sequence
_array_matches_identity(::UInt64, identity) = true
_array_matches_identity(expected::AcquisitionIdentity, ::Nothing) = false
_array_matches_identity(expected::AcquisitionIdentity, identity::AcquisitionIdentity) = expected == identity

function _array_read!(state::_ArrayExchangeState{T}, buffer) where {T}
    header = buffer_header(buffer)
    header === nothing && throw(InvalidStateException("the ndarray input has no Header", :no_metadata))
    header.sequence == _array_expected_sequence(state.expected) || throw(ArgumentError("the ndarray Header sequence differs from the armed sequence"))
    header.flags & (SPA.META_HEADER_FLAG_CORRUPTED | SPA.META_HEADER_FLAG_GAP) == 0 || throw(ArgumentError("the ndarray Header marks invalid data"))
    metadata = buffer_acquisition(buffer)
    identity = metadata === nothing ? nothing : acquisition_identity(metadata)
    duration = metadata === nothing ? nothing : acquisition_exposure_duration(metadata)
    _array_matches_identity(state.expected, identity) || throw(ArgumentError("the ndarray acquisition identity differs from the armed identity"))
    identity === nothing || identity.sequence == header.sequence || throw(ArgumentError("the ndarray Header and acquisition sequence differ"))
    state.expected_duration === nothing || duration == state.expected_duration || throw(ArgumentError("the ndarray exposure duration differs from the armed duration"))
    data = buffer_data(buffer)
    chunk = chunk_info(data)
    # Fixed ndarray Format defines packed storage even when a native graph
    # leaves chunk stride unspecified (zero). No padded payload is accepted.
    chunk.offset == 0 && chunk.size == payload_size(state.format) &&
        chunk.stride in (0, sizeof(T), _array_packed_stride(state)) && chunk.flags == 0 || throw(ArgumentError(
            "the ndarray input chunk is not the declared packed payload: offset=$(chunk.offset), size=$(chunk.size), stride=$(chunk.stride), flags=$(chunk.flags)",
        ))
    memory = buffer_memory(data, payload_size(state.format))
    _array_validate_encoding(T, memory)
    copyto!(state.values, reinterpret(T, memory))
    state.header = header
    state.identity = identity
    state.duration = duration
    return nothing
end

_array_validate_encoding(::Type{T}, memory) where {T} = nothing
function _array_validate_encoding(::Type{Bool}, memory)
    for value in memory
        value <= 1 || throw(ArgumentError("BOOL8 payload contains a noncanonical Boolean"))
    end
    return nothing
end

struct _ArraySinkProcess{S}
    state::S
end

function (callback::_ArraySinkProcess)(stream)
    state = callback.state
    state.phase[] >= _ARRAY_FAILED && return nothing
    try
        dequeue_buffer!(state.buffer, stream) || return nothing
        queued = false
        try
            state.phase[] == _ARRAY_PENDING || throw(InvalidStateException("the ndarray input arrived without an armed slot", :unarmed))
            _array_read!(state, state.buffer)
            queue_buffer!(state.buffer, stream)
            queued = true
            state.phase[] = _ARRAY_COMPLETE
            _array_notify!(state)
        finally
            queued || queue_buffer!(state.buffer, stream)
        end
    catch error
        _array_fail!(state, error)
    end
    return nothing
end

function NdArraySource(core::CoreConnection, name::AbstractString, storage::Vector{T}, format::NdArrayFormat{N}; schema=nothing, properties=nothing) where {T,N}
    state = _ArrayExchangeState(storage, format, schema)
    stream = _array_stream(core, name, state, _ArraySourceProcess(state), true, properties)
    return NdArraySource{T,N,typeof(stream)}(stream, state)
end

function NdArraySink(core::CoreConnection, name::AbstractString, storage::Vector{T}, format::NdArrayFormat{N}; schema=nothing, properties=nothing) where {T,N}
    state = _ArrayExchangeState(storage, format, schema)
    stream = _array_stream(core, name, state, _ArraySinkProcess(state), false, properties)
    return NdArraySink{T,N,typeof(stream)}(stream, state)
end

main_loop(endpoint::Union{NdArraySource,NdArraySink}) = main_loop(endpoint.stream)
node_id(endpoint::Union{NdArraySource,NdArraySink}) = _array_loop_lock(() -> node_id(endpoint.stream), endpoint)
Base.isopen(endpoint::Union{NdArraySource,NdArraySink}) = endpoint.state.phase[] != _ARRAY_CLOSED
isrunning(endpoint::Union{NdArraySource,NdArraySink}) = _array_loop_lock(endpoint) do
    endpoint.state.started && endpoint.state.phase[] < _ARRAY_FAILED
end

function start!(endpoint::Union{NdArraySource,NdArraySink})
    _array_loop_lock(endpoint) do
        state = endpoint.state
        _array_require_usable(state) == _ARRAY_PENDING && throw(InvalidStateException("an ndarray exchange is pending", :pending))
        set_active!(endpoint.stream, true)
        state.started = true
    end
    return endpoint
end

function Base.close(endpoint::Union{NdArraySource,NdArraySink})
    endpoint.state.phase[] == _ARRAY_CLOSED && return nothing
    _array_loop_lock(endpoint) do
        state = endpoint.state
        state.phase[] = _ARRAY_CLOSED
        state.started = false
        close(endpoint.stream)
        _array_notify!(state)
    end
    return nothing
end

function _array_duration(value::Integer)
    0 < value <= typemax(UInt64) || throw(ArgumentError("exposure duration must fit positive UInt64 nanoseconds"))
    return UInt64(value)
end
_array_duration(::Nothing) = nothing

_array_trigger_retryable(error) = false
_array_trigger_retryable(error::PipeWireError) = error.code in (-Base.Libc.EIO, -Base.Libc.EAGAIN)

function _array_trigger!(source::NdArraySource)
    source.state.phase[] == _ARRAY_PENDING || return nothing
    stream_state(source.stream) == LibPipeWire.PW_STREAM_STATE_STREAMING || return nothing
    is_driving(source.stream) || return nothing
    try
        trigger_process!(source.stream)
    catch error
        _array_trigger_retryable(error) || rethrow()
    end
    return nothing
end

"""
    submit_array!(source, values::AbstractVector{T}, header;
                  identity=nothing, exposure_duration_ns=nothing) -> UInt64

Stage a private payload copy and request native processing promptly. One submit
may be outstanding; acknowledge publication with `wait_array_source!` before
submitting again. The positive lifetime token is independent of Header sequence,
so a new acquisition generation may restart its Header sequence at one.
"""
function submit_array!(source::NdArraySource{T}, values::AbstractVector{T}, header::BufferHeader;
    identity::Union{Nothing,AcquisitionIdentity}=nothing, exposure_duration_ns=nothing) where {T}
    length(values) == length(source.state.values) || throw(DimensionMismatch("submitted payload length differs from the wire shape"))
    header.sequence > 0 || throw(ArgumentError("Header sequence must be positive"))
    identity === nothing || identity.sequence == header.sequence || throw(ArgumentError("Header and acquisition sequences must match"))
    duration = _array_duration(exposure_duration_ns)
    return _array_loop_lock(source) do
        state = source.state
        _array_require_usable(state) == _ARRAY_IDLE || throw(InvalidStateException("the previous ndarray publication is unacknowledged", :pending))
        state.waiting[] && throw(InvalidStateException("the previous ndarray publication waiter is active", :waiting))
        state.started || throw(InvalidStateException("the ndarray source is inactive", :inactive))
        state.token < typemax(UInt64) || throw(InvalidStateException("the ndarray publication token is exhausted", :exhausted))
        for (index, value) in enumerate(values)
            state.values[index] = value
        end
        state.header = header
        state.identity = identity
        state.duration = duration
        state.token += 1
        state.phase[] = _ARRAY_PENDING
        try
            _array_trigger!(source)
        catch error
            _array_fail!(state, error)
            rethrow()
        end
        return state.token
    end
end

"""
    arm_array_sink!(sink, expected::Union{UInt64,AcquisitionIdentity}; exposure_duration_ns=nothing)

Arm one receive slot. A sequence expectation matches Header sequence; an
acquisition expectation also requires complete valid domain/generation/sequence
metadata. An optional duration must match exactly. After `wait_array_sink!`,
read or copy the values and receipt before rearming. Unexpected, duplicate, or
unarmed input permanently fails the endpoint.
"""
function arm_array_sink!(sink::NdArraySink, expected::Union{UInt64,AcquisitionIdentity}; exposure_duration_ns=nothing)
    _array_expected_sequence(expected) > 0 || throw(ArgumentError("expected sequence must be positive"))
    duration = _array_duration(exposure_duration_ns)
    _array_loop_lock(sink) do
        state = sink.state
        phase = _array_require_usable(state)
        (phase == _ARRAY_IDLE || (phase == _ARRAY_COMPLETE && state.acknowledged)) || throw(InvalidStateException("the previous ndarray receive is pending or unacknowledged", :pending))
        state.waiting[] && throw(InvalidStateException("the previous ndarray receive waiter is active", :waiting))
        state.started || throw(InvalidStateException("the ndarray sink is inactive", :inactive))
        state.expected = expected
        state.expected_duration = duration
        state.acknowledged = false
        state.phase[] = _ARRAY_PENDING
    end
    return sink
end

function _array_wait(endpoint, timeout_ns::Integer, retrigger::Bool)
    0 < timeout_ns <= typemax(Int64) || throw(ArgumentError("timeout must fit positive Int64 nanoseconds"))
    timeout = UInt64(timeout_ns)
    state = endpoint.state
    started = time_ns()
    timer = nothing
    try
        timer = Timer(_ -> _array_notify!(state), 0.001; interval=retrigger ? 0.001 : cld(timeout, UInt64(1_000_000)) / 1000)
        while true
            complete = lock(state.condition) do
                phase = _array_require_usable(state)
                time_ns() - started < timeout || throw(InvalidStateException("the ndarray completion deadline expired", :timeout))
                phase == _ARRAY_COMPLETE && return true
                phase == _ARRAY_PENDING || throw(InvalidStateException("no ndarray exchange is pending", :idle))
                wait(state.condition)
                return false
            end
            complete && return nothing
            if retrigger && time_ns() - started < timeout
                _array_loop_lock(endpoint) do
                    _array_trigger!(endpoint)
                end
            end
        end
    catch error
        _array_loop_lock(endpoint) do
            _array_fail!(state, error)
        end
        rethrow()
    finally
        timer === nothing || close(timer)
    end
end

"Wait for native source queue publication of `token`, bounded by `timeout_ns`."
function wait_array_source!(source::NdArraySource, token::UInt64; timeout_ns::Integer)
    _array_loop_lock(source) do
        _array_require_usable(source.state)
        source.state.token == token && token > 0 || throw(ArgumentError("the publication token is not current"))
        Threads.atomic_cas!(source.state.waiting, false, true) && throw(InvalidStateException("an ndarray completion waiter is already active", :waiting))
    end
    try
        _array_wait(source, timeout_ns, true)
        _array_loop_lock(source) do
            _array_require_usable(source.state) == _ARRAY_COMPLETE || throw(InvalidStateException("source publication is unavailable", :unavailable))
            source.state.token == token || throw(ArgumentError("the publication token is no longer current"))
            source.state.phase[] = _ARRAY_IDLE
        end
        return token
    finally
        source.state.waiting[] = false
    end
end

"Wait for one validated, captured sink payload, bounded by `timeout_ns`."
function wait_array_sink!(sink::NdArraySink; timeout_ns::Integer)
    Threads.atomic_cas!(sink.state.waiting, false, true) && throw(InvalidStateException("an ndarray completion waiter is already active", :waiting))
    try
        _array_wait(sink, timeout_ns, false)
        return _array_loop_lock(sink) do
            _array_require_usable(sink.state) == _ARRAY_COMPLETE || throw(InvalidStateException("sink receipt is unavailable", :unavailable))
            sink.state.acknowledged = true
            return array_receipt(sink)
        end
    finally
        sink.state.waiting[] = false
    end
end

function _array_require_receipt(sink::NdArraySink)
    _array_require_usable(sink.state) == _ARRAY_COMPLETE && sink.state.acknowledged || throw(InvalidStateException("the ndarray receive has not been acknowledged", :unavailable))
    return nothing
end

"Return the sink-owned linear values without copying, valid until rearm or close."
function array_values(sink::NdArraySink)
    _array_require_receipt(sink)
    return sink.state.values
end

"Return an immutable captured receipt without retaining borrowed metadata."
function array_receipt(sink::NdArraySink)
    _array_require_receipt(sink)
    state = sink.state
    return NamedTuple{(:header, :identity, :exposure_duration_ns),
        Tuple{BufferHeader,Union{Nothing,AcquisitionIdentity},Union{Nothing,UInt64}}}(
        (something(state.header), state.identity, state.duration),
    )
end
