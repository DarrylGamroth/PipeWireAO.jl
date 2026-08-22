"Automatically connect a stream to a compatible target."
const STREAM_AUTOCONNECT = LibPipeWire.PW_STREAM_FLAG_AUTOCONNECT
"Create a stream in the inactive state."
const STREAM_INACTIVE = LibPipeWire.PW_STREAM_FLAG_INACTIVE
"Request memory-mapped stream buffers."
const STREAM_MAP_BUFFERS = LibPipeWire.PW_STREAM_FLAG_MAP_BUFFERS

abstract type AbstractPipeWireBuffer end
abstract type AbstractPipeWireData end
"Make a stream a graph driver when permitted."
const STREAM_DRIVER = LibPipeWire.PW_STREAM_FLAG_DRIVER
"Disable format conversion for a stream."
const STREAM_NO_CONVERT = LibPipeWire.PW_STREAM_FLAG_NO_CONVERT
"Require exclusive access to the stream target."
const STREAM_EXCLUSIVE = LibPipeWire.PW_STREAM_FLAG_EXCLUSIVE
"Do not reconnect automatically when the target disappears."
const STREAM_DONT_RECONNECT = LibPipeWire.PW_STREAM_FLAG_DONT_RECONNECT
"Let the application allocate stream-buffer memory."
const STREAM_ALLOC_BUFFERS = LibPipeWire.PW_STREAM_FLAG_ALLOC_BUFFERS
"Enable explicit stream processing triggers."
const STREAM_TRIGGER = LibPipeWire.PW_STREAM_FLAG_TRIGGER
"Require scheduler-independent latest-buffer transport on every stream link."
const STREAM_BUFFER_LATEST = LibPipeWire.PW_STREAM_FLAG_BUFFER_LATEST
"Dequeue and queue buffers outside the real-time process callback."
const STREAM_ASYNC = LibPipeWire.PW_STREAM_FLAG_ASYNC
"Request process callbacks as soon as playback buffers are available."
const STREAM_EARLY_PROCESS = LibPipeWire.PW_STREAM_FLAG_EARLY_PROCESS
const _PW_ID_ANY = typemax(UInt32)

"A copied snapshot of a PipeWire stream control."
struct StreamControl
    name::String
    flags::UInt32
    default::Float32
    minimum::Float32
    maximum::Float32
    values::Vector{Float32}
    max_values::UInt32
end

Base.:(==)(left::StreamControl, right::StreamControl) =
    left.name == right.name &&
    left.flags == right.flags &&
    left.default == right.default &&
    left.minimum == right.minimum &&
    left.maximum == right.maximum &&
    left.values == right.values &&
    left.max_values == right.max_values
Base.isequal(left::StreamControl, right::StreamControl) =
    isequal(left.name, right.name) &&
    isequal(left.flags, right.flags) &&
    isequal(left.default, right.default) &&
    isequal(left.minimum, right.minimum) &&
    isequal(left.maximum, right.maximum) &&
    isequal(left.values, right.values) &&
    isequal(left.max_values, right.max_values)
Base.hash(value::StreamControl, seed::UInt) = hash(
    (
        value.name,
        value.flags,
        value.default,
        value.minimum,
        value.maximum,
        value.values,
        value.max_values,
    ),
    seed,
)

"A borrowed I/O area reported by a stream I/O-change callback."
struct StreamIO
    id::UInt32
    area::Ptr{Cvoid}
    size::UInt32
end

"A concrete snapshot of PipeWire stream timing and queue state."
struct StreamTime
    now::Int64
    rate::SPA.Fraction
    ticks::UInt64
    delay::Int64
    queued::UInt64
    buffered::UInt64
    queued_buffers::UInt32
    available_buffers::UInt32
    size::UInt64
end

function _copy_stream_control(pointer::Ptr{LibPipeWire.pw_stream_control})
    pointer == C_NULL && return nothing
    native = unsafe_load(pointer)
    name = native.name == C_NULL ? "" : unsafe_string(native.name)
    values = if native.values == C_NULL || native.n_values == 0
        Float32[]
    else
        copy(unsafe_wrap(Vector{Float32}, native.values, Int(native.n_values); own=false))
    end
    return StreamControl(
        name,
        native.flags,
        native.def,
        native.min,
        native.max,
        values,
        native.max_values,
    )
end

"""
    Stream(core, name; properties=nothing, on_state_changed=nothing,
           on_control_info=nothing, on_io_changed=nothing,
           on_param_changed=nothing, on_process=nothing,
           on_buffer_added=nothing, on_buffer_removed=nothing,
           on_drained=nothing, on_command=nothing, on_trigger_done=nothing)

Create an owning PipeWire stream. Callback functions run on the thread that
dispatches the PipeWire loop. They are suitable for ordinary Julia client code,
but are not hard-real-time safe and must not be used with PipeWire's
`RT_PROCESS` stream flag.

`properties` may be a [`Properties`](@ref) value or any iterable of string
pairs. A `Properties` argument is copied and remains open. Callback types are
part of the concrete `Stream` type. After warmup, dispatching `on_process`
allocates zero bytes when the callback itself does not allocate. Callback error
paths and the owned POD copy passed to `on_param_changed` are outside that
steady-state allocation contract.
"""
mutable struct Stream{CoreType<:CoreConnection,Callbacks}
    handle::Ptr{LibPipeWire.pw_stream}
    core::CoreType
    state_lock::ReentrantLock
    callback_lock::ReentrantLock
    listener::Base.RefValue{LibPipeWire.spa_hook}
    events::Base.RefValue{LibPipeWire.pw_stream_events}
    callbacks::Callbacks
    callback_error::Base.RefValue{Any}
    buffer_owners::Dict{Ptr{LibPipeWire.pw_buffer},Vector{Vector{UInt8}}}
    callbacks_active::Bool
    connected::Bool
    image_source_count::Int
end

function _stream_control_info(
    stream::Stream,
    id::UInt32,
    control::Ptr{LibPipeWire.pw_stream_control},
)::Cvoid
    try
        _invoke_stream_callback(stream, Val(:on_control_info), id, _copy_stream_control(control))
    catch error
        lock(stream.callback_lock) do
            stream.callback_error[] === nothing && (stream.callback_error[] = error)
        end
        _stop_after_callback(stream.core.callback_state, error)
    end
    return nothing
end

function _stream_io_changed(
    stream::Stream,
    id::UInt32,
    area::Ptr{Cvoid},
    size::UInt32,
)::Cvoid
    _invoke_stream_callback(stream, Val(:on_io_changed), StreamIO(id, area, size))
    return nothing
end

function _invoke_stream_callback(stream::Stream, ::Val{Field}, args...) where {Field}
    lock(stream.callback_lock)
    if !stream.callbacks_active
        unlock(stream.callback_lock)
        return nothing
    end
    callback = getfield(stream.callbacks, Field)
    unlock(stream.callback_lock)
    callback === nothing && return nothing
    try
        callback(stream, args...)
    catch error
        lock(stream.callback_lock) do
            stream.callback_error[] === nothing && (stream.callback_error[] = error)
        end
        _stop_after_callback(stream.core.callback_state, error)
    end
    return nothing
end

function _stream_state_changed(
    stream::Stream,
    old::Int32,
    current::Int32,
    message::Cstring,
)::Cvoid
    detail = message == C_NULL ? nothing : unsafe_string(message)
    _invoke_stream_callback(stream, Val(:on_state_changed), old, current, detail)
    return nothing
end

function _stream_param_changed(
    stream::Stream,
    id::UInt32,
    param::Ptr{LibPipeWire.spa_pod},
)::Cvoid
    try
        _invoke_stream_callback(stream, Val(:on_param_changed), id, _copy_pod(param))
    catch error
        lock(stream.callback_lock) do
            stream.callback_error[] === nothing && (stream.callback_error[] = error)
        end
        _stop_after_callback(stream.core.callback_state, error)
    end
    return nothing
end

function _stream_process(stream::Stream)::Cvoid
    _invoke_stream_callback(stream, Val(:on_process))
    return nothing
end

function _stream_buffer_added(
    stream::Stream,
    buffer::Ptr{LibPipeWire.pw_buffer},
)::Cvoid
    _invoke_stream_callback(stream, Val(:on_buffer_added), buffer)
    return nothing
end

function _stream_buffer_removed(
    stream::Stream,
    buffer::Ptr{LibPipeWire.pw_buffer},
)::Cvoid
    try
        _invoke_stream_callback(stream, Val(:on_buffer_removed), buffer)
    finally
        lock(stream.state_lock) do
            pop!(stream.buffer_owners, buffer, nothing)
        end
    end
    return nothing
end

function _stream_drained(stream::Stream)::Cvoid
    _invoke_stream_callback(stream, Val(:on_drained))
    return nothing
end

function _stream_command(
    stream::Stream,
    command::Ptr{LibPipeWire.spa_command},
)::Cvoid
    try
        _invoke_stream_callback(
            stream,
            Val(:on_command),
            _copy_pod(Ptr{LibPipeWire.spa_pod}(command)),
        )
    catch error
        lock(stream.callback_lock) do
            stream.callback_error[] === nothing && (stream.callback_error[] = error)
        end
        _stop_after_callback(stream.core.callback_state, error)
    end
    return nothing
end

function _stream_trigger_done(stream::Stream)::Cvoid
    _invoke_stream_callback(stream, Val(:on_trigger_done))
    return nothing
end

function _stream_events(::T) where {T<:Stream}
    state_changed = @cfunction(
        _stream_state_changed,
        Cvoid,
        (Ref{T}, Int32, Int32, Cstring),
    )
    control_info = @cfunction(
        _stream_control_info,
        Cvoid,
        (Ref{T}, UInt32, Ptr{LibPipeWire.pw_stream_control}),
    )
    io_changed = @cfunction(
        _stream_io_changed,
        Cvoid,
        (Ref{T}, UInt32, Ptr{Cvoid}, UInt32),
    )
    param_changed = @cfunction(
        _stream_param_changed,
        Cvoid,
        (Ref{T}, UInt32, Ptr{LibPipeWire.spa_pod}),
    )
    process = @cfunction(_stream_process, Cvoid, (Ref{T},))
    buffer_added = @cfunction(
        _stream_buffer_added,
        Cvoid,
        (Ref{T}, Ptr{LibPipeWire.pw_buffer}),
    )
    buffer_removed = @cfunction(
        _stream_buffer_removed,
        Cvoid,
        (Ref{T}, Ptr{LibPipeWire.pw_buffer}),
    )
    drained = @cfunction(_stream_drained, Cvoid, (Ref{T},))
    command = @cfunction(
        _stream_command,
        Cvoid,
        (Ref{T}, Ptr{LibPipeWire.spa_command}),
    )
    trigger_done = @cfunction(_stream_trigger_done, Cvoid, (Ref{T},))
    return LibPipeWire.pw_stream_events(
        UInt32(2),
        _NULL_CALLBACK,
        state_changed,
        control_info,
        io_changed,
        param_changed,
        buffer_added,
        buffer_removed,
        process,
        drained,
        command,
        trigger_done,
    )
end

function Stream(
    core::CoreConnection,
    name::AbstractString;
    properties=nothing,
    on_state_changed=nothing,
    on_control_info=nothing,
    on_io_changed=nothing,
    on_param_changed=nothing,
    on_process=nothing,
    on_buffer_added=nothing,
    on_buffer_removed=nothing,
    on_drained=nothing,
    on_command=nothing,
    on_trigger_done=nothing,
)
    name_string = String(name)
    contains(name_string, '\0') && throw(ArgumentError("a PipeWire stream name cannot contain NUL"))
    core_handle = _retain_stream(core)
    native_properties = try
        _owned_native_properties(properties)
    catch
        _release_stream(core)
        rethrow()
    end
    handle = GC.@preserve name_string LibPipeWire.pw_stream_new(
        core_handle,
        pointer(name_string),
        native_properties,
    )
    if handle == C_NULL
        _release_stream(core)
        throw(PipeWireError(:pw_stream_new, -Base.Libc.errno()))
    end

    callbacks = (
        on_state_changed=on_state_changed,
        on_control_info=on_control_info,
        on_io_changed=on_io_changed,
        on_param_changed=on_param_changed,
        on_process=on_process,
        on_buffer_added=on_buffer_added,
        on_buffer_removed=on_buffer_removed,
        on_drained=on_drained,
        on_command=on_command,
        on_trigger_done=on_trigger_done,
    )
    listener = Ref(_zero_hook())
    events = Ref{LibPipeWire.pw_stream_events}()
    stream = Stream(
        handle,
        core,
        ReentrantLock(),
        ReentrantLock(),
        listener,
        events,
        callbacks,
        Ref{Any}(nothing),
        Dict{Ptr{LibPipeWire.pw_buffer},Vector{Vector{UInt8}}}(),
        true,
        false,
        0,
    )
    try
        events[] = _stream_events(stream)
    catch
        close(stream)
        rethrow()
    end
    GC.@preserve stream listener events begin
        LibPipeWire.pw_stream_add_listener(
            handle,
            Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener),
            Base.unsafe_convert(Ptr{LibPipeWire.pw_stream_events}, events),
            pointer_from_objref(stream),
        )
    end
    finalizer(close, stream)
    return stream
end

main_loop(stream::Stream) = main_loop(stream.core)

function _require_open(stream::Stream)
    stream.handle == C_NULL &&
        throw(InvalidStateException("the PipeWire stream is closed", :closed))
    return stream.handle
end

function _check_callback_error(stream::Stream)
    error = lock(stream.callback_lock) do
        stream.callback_error[]
    end
    error === nothing || throw(error)
    return nothing
end

function Base.isopen(stream::Stream)
    return lock(stream.state_lock) do
        stream.handle != C_NULL
    end
end

function Base.close(stream::Stream)
    handle = lock(stream.state_lock) do
        stream.handle == C_NULL && return C_NULL
        stream.image_source_count == 0 || throw(
            InvalidStateException(
                "close every image source before closing its PipeWire stream",
                :image_sources,
            ),
        )
        handle = stream.handle
        stream.handle = Ptr{LibPipeWire.pw_stream}(C_NULL)
        stream.connected = false
        return handle
    end
    handle == C_NULL && return nothing
    lock(stream.callback_lock) do
        stream.callbacks_active = false
    end
    LibPipeWire.pw_stream_destroy(handle)
    empty!(stream.buffer_owners)
    _release_stream(stream.core)
    return nothing
end

"Return the current native state of `stream`, throwing a reported stream error."
function stream_state(stream::Stream)
    _check_callback_error(stream)
    error_pointer = Ref{Cstring}(C_NULL)
    value = lock(stream.state_lock) do
        LibPipeWire.pw_stream_get_state(_require_open(stream), error_pointer)
    end
    if value == LibPipeWire.PW_STREAM_STATE_ERROR
        detail = error_pointer[] == C_NULL ? nothing : unsafe_string(error_pointer[])
        throw(PipeWireError(:pw_stream, Cint(-Base.Libc.errno()), detail))
    end
    return value
end

"Return the bound PipeWire node ID for `stream`."
function node_id(stream::Stream)
    _check_callback_error(stream)
    return lock(stream.state_lock) do
        LibPipeWire.pw_stream_get_node_id(_require_open(stream))
    end
end

"Return the stream's native name as an owned Julia string."
function stream_name(stream::Stream)
    _check_callback_error(stream)
    return lock(stream.state_lock) do
        pointer = LibPipeWire.pw_stream_get_name(_require_open(stream))
        return pointer == C_NULL ? "" : unsafe_string(pointer)
    end
end

"Return a copied property snapshot for `stream`."
function stream_properties(stream::Stream)
    _check_callback_error(stream)
    return lock(stream.state_lock) do
        pointer = LibPipeWire.pw_stream_get_properties(_require_open(stream))
        pointer == C_NULL && return Dict{String,String}()
        native = unsafe_load(pointer)
        dictionary = Ref(native.dict)
        return GC.@preserve dictionary _copy_properties(
            Base.unsafe_convert(Ptr{LibPipeWire.spa_dict}, dictionary),
        )
    end
end

"Update stream properties and return `stream`."
function update_properties!(stream::Stream, properties)
    _check_callback_error(stream)
    _with_properties_dict(properties) do dictionary
        result = lock(stream.state_lock) do
            LibPipeWire.pw_stream_update_properties(_require_open(stream), dictionary)
        end
        _check_result(:pw_stream_update_properties, result)
    end
    return stream
end

function _stream_params(params)
    native = Pod[pod for pod in params]
    length(native) <= typemax(UInt32) ||
        throw(ArgumentError("stream has too many parameters"))
    pointers = Ptr{LibPipeWire.spa_pod}[_pod_pointer(pod) for pod in native]
    return native, pointers
end

"Update the parameters exposed by `stream` and return it."
function update_params!(stream::Stream, params)
    _check_callback_error(stream)
    native, pointers = _stream_params(params)
    result = GC.@preserve native pointers lock(stream.state_lock) do
        LibPipeWire.pw_stream_update_params(
            _require_open(stream),
            isempty(pointers) ? C_NULL : pointer(pointers),
            UInt32(length(pointers)),
        )
    end
    _check_result(:pw_stream_update_params, result)
    return stream
end

"Set one stream parameter, or clear it with `param=nothing`."
function set_param!(stream::Stream, id::Integer, param::Union{Nothing,Pod})
    _check_callback_error(stream)
    parameter_id = _core_uint32(id, "parameter ID")
    result = if param === nothing
        lock(stream.state_lock) do
            LibPipeWire.pw_stream_set_param(_require_open(stream), parameter_id, C_NULL)
        end
    else
        GC.@preserve param lock(stream.state_lock) do
            LibPipeWire.pw_stream_set_param(
                _require_open(stream),
                parameter_id,
                _pod_pointer(param),
            )
        end
    end
    _check_result(:pw_stream_set_param, result)
    return stream
end

"Return a copied stream-control snapshot, or `nothing` when it is unavailable."
function stream_control(stream::Stream, id::Integer)
    _check_callback_error(stream)
    control_id = _core_uint32(id, "control ID")
    return lock(stream.state_lock) do
        pointer = LibPipeWire.pw_stream_get_control(_require_open(stream), control_id)
        return _copy_stream_control(pointer)
    end
end

"Set the floating-point values for a stream control and return `stream`."
function set_control!(stream::Stream, id::Integer, values)
    _check_callback_error(stream)
    control_id = _core_uint32(id, "control ID")
    native_values = collect(Float32, values)
    length(native_values) <= typemax(UInt32) ||
        throw(ArgumentError("stream control has too many values"))
    result = GC.@preserve native_values lock(stream.state_lock) do
        LibPipeWire.pw_stream_set_control(
            _require_open(stream),
            control_id,
            UInt32(length(native_values)),
            isempty(native_values) ? C_NULL : pointer(native_values),
            UInt32(0),
        )
    end
    _check_result(:pw_stream_set_control, result)
    return stream
end

set_control!(stream::Stream, id::Integer, value::Real) =
    set_control!(stream, id, (Float32(value),))

"Return a concrete timing snapshot for a running stream."
function stream_time(stream::Stream)
    _check_callback_error(stream)
    native = Ref{LibPipeWire.pw_time}()
    result = lock(stream.state_lock) do
        LibPipeWire.pw_stream_get_time_n(
            _require_open(stream),
            native,
            sizeof(LibPipeWire.pw_time),
        )
    end
    _check_result(:pw_stream_get_time_n, result)
    value = native[]
    return StreamTime(
        value.now,
        SPA.Fraction(value.rate.num, value.rate.denom),
        value.ticks,
        value.delay,
        value.queued,
        value.buffered,
        value.queued_buffers,
        value.avail_buffers,
        value.size,
    )
end

"Return the stream's current native monotonic time in nanoseconds."
function stream_nsec(stream::Stream)
    _check_callback_error(stream)
    return lock(stream.state_lock) do
        LibPipeWire.pw_stream_get_nsec(_require_open(stream))
    end
end

"Return whether a driver stream is currently driving the graph."
function is_driving(stream::Stream)
    _check_callback_error(stream)
    return lock(stream.state_lock) do
        handle = _require_open(stream)
        stream.connected && LibPipeWire.pw_stream_is_driving(handle)
    end
end

"Return whether the graph uses lazy scheduling for `stream`."
function is_lazy(stream::Stream)
    _check_callback_error(stream)
    return lock(stream.state_lock) do
        handle = _require_open(stream)
        stream.connected && LibPipeWire.pw_stream_is_lazy(handle)
    end
end

"Adjust an adaptive stream resampler's rate and return `stream`."
function set_rate!(stream::Stream, rate::Real)
    _check_callback_error(stream)
    value = Float64(rate)
    isfinite(value) || throw(ArgumentError("stream rate must be finite"))
    result = lock(stream.state_lock) do
        LibPipeWire.pw_stream_set_rate(_require_open(stream), value)
    end
    _check_result(:pw_stream_set_rate, result)
    return stream
end

"Emit an owned SPA event POD from `stream` and return it."
function emit_event!(stream::Stream, event::Pod)
    _check_callback_error(stream)
    object = pod_value(SPA.Object, event)
    LibPipeWire.SPA_TYPE_EVENT_START <= object.type < LibPipeWire._SPA_TYPE_EVENT_LAST ||
        throw(ArgumentError("the POD is not an SPA event object"))
    result = GC.@preserve event lock(stream.state_lock) do
        LibPipeWire.pw_stream_emit_event(
            _require_open(stream),
            Ptr{LibPipeWire.spa_event}(_pod_pointer(event)),
        )
    end
    _check_result(:pw_stream_emit_event, result)
    return stream
end

emit_event!(stream::Stream, event::SPA.Event) = emit_event!(stream, Pod(event))

"""
    set_error!(stream, result, message)

Move `stream` to PipeWire's error state. `result` must be a negative
errno-style `Cint` value.
"""
function set_error!(stream::Stream, result::Integer, message::AbstractString)
    typemin(Cint) <= result < 0 ||
        throw(ArgumentError("a PipeWire stream error result must be a negative Cint"))
    text = _validate_c_string(String(message), "stream error message")
    format = "%s"
    GC.@preserve text format lock(stream.state_lock) do
        LibPipeWire.pw_stream_set_error(
            _require_open(stream),
            Cint(result),
            pointer(format),
            pointer(text),
        )
    end
    return stream
end

"""
    connect!(stream, direction; target=typemax(UInt32), flags=..., params=())

Connect a stream in the `:input` or `:output` direction and return it.
"""
function connect!(
    stream::Stream,
    direction::Symbol;
    target::Integer=_PW_ID_ANY,
    flags::Integer=STREAM_AUTOCONNECT | STREAM_MAP_BUFFERS,
    params=Pod[],
)
    native_direction = if direction === :input
        LibPipeWire.SPA_DIRECTION_INPUT
    elseif direction === :output
        LibPipeWire.SPA_DIRECTION_OUTPUT
    else
        throw(ArgumentError("stream direction must be :input or :output"))
    end
    target_id = _core_uint32(target, "stream target ID")
    native_flags = _core_uint32(flags, "stream flags")
    native_flags & LibPipeWire.PW_STREAM_FLAG_RT_PROCESS == 0 || throw(
        ArgumentError(
            "Julia stream callbacks are not hard-real-time safe; RT_PROCESS is unsupported",
        ),
    )
    native_flags & LibPipeWire.PW_STREAM_FLAG_RT_TRIGGER_DONE == 0 || throw(
        ArgumentError(
            "Julia stream callbacks are not hard-real-time safe; RT_TRIGGER_DONE is unsupported",
        ),
    )
    native_params, param_pointers = _stream_params(params)
    result = GC.@preserve native_params param_pointers begin
        lock(stream.state_lock) do
            stream.connected && throw(
                InvalidStateException("the PipeWire stream is already connected", :connected),
            )
            result = LibPipeWire.pw_stream_connect(
                _require_open(stream),
                native_direction,
                target_id,
                native_flags,
                isempty(param_pointers) ? C_NULL : pointer(param_pointers),
                UInt32(length(param_pointers)),
            )
            result >= 0 && (stream.connected = true)
            result
        end
    end
    _check_result(:pw_stream_connect, result)
    return stream
end

"Disconnect `stream` and return it."
function disconnect!(stream::Stream)
    result = lock(stream.state_lock) do
        handle = _require_open(stream)
        stream.connected || return Cint(0)
        result = LibPipeWire.pw_stream_disconnect(handle)
        result >= 0 && (stream.connected = false)
        result
    end
    _check_result(:pw_stream_disconnect, result)
    return stream
end

"Set whether `stream` is active and return it."
function set_active!(stream::Stream, active::Bool=true)
    _check_callback_error(stream)
    result = lock(stream.state_lock) do
        LibPipeWire.pw_stream_set_active(_require_open(stream), active)
    end
    _check_result(:pw_stream_set_active, result)
    return stream
end

"Flush queued buffers, optionally draining them first, and return `stream`."
function flush!(stream::Stream; drain::Bool=false)
    _check_callback_error(stream)
    result = lock(stream.state_lock) do
        LibPipeWire.pw_stream_flush(_require_open(stream), drain)
    end
    _check_result(:pw_stream_flush, result)
    return stream
end

"Request processing for a trigger-driven stream and return it."
function trigger_process!(stream::Stream)
    _check_callback_error(stream)
    result = lock(stream.state_lock) do
        LibPipeWire.pw_stream_trigger_process(_require_open(stream))
    end
    _check_result(:pw_stream_trigger_process, result)
    return stream
end

"""
    StreamBuffer

A dequeued, borrowed PipeWire stream buffer. Exactly one of
`queue_buffer!(buffer, stream)` or `return_buffer!(buffer, stream)` must be
called before the buffer can be dequeued again. Construct `StreamBuffer()` once
and use [`dequeue_buffer!`](@ref) to avoid allocations in a process callback.
"""
mutable struct StreamBuffer <: AbstractPipeWireBuffer
    handle::Ptr{LibPipeWire.pw_buffer}
end

StreamBuffer() = StreamBuffer(Ptr{LibPipeWire.pw_buffer}(C_NULL))

"A concrete snapshot of the accounting fields attached to a PipeWire buffer."
struct BufferInfo
    user_data::Ptr{Cvoid}
    size::UInt64
    requested::UInt64
    time::UInt64
end

const StreamBufferInfo = BufferInfo

"A borrowed metadata entry belonging to a PipeWire buffer."
struct BufferMetadata{BufferType<:AbstractPipeWireBuffer}
    buffer::BufferType
    index::Int
end

const StreamMetadata = BufferMetadata{StreamBuffer}

"Number of bytes in an opaque PipeWireAO acquisition-domain identifier."
const ACQUISITION_DOMAIN_SIZE = Int(LibPipeWire.SPA_META_ACQUISITION_DOMAIN_SIZE)

"""
    AcquisitionDomain(bytes)

Construct a nonzero opaque acquisition-domain identifier from exactly
`ACQUISITION_DOMAIN_SIZE` bytes.
"""
struct AcquisitionDomain
    bytes::NTuple{ACQUISITION_DOMAIN_SIZE,UInt8}

    function AcquisitionDomain(bytes::NTuple{ACQUISITION_DOMAIN_SIZE,UInt8})
        all(iszero, bytes) && throw(ArgumentError("the acquisition domain must be nonzero"))
        return new(bytes)
    end
end

"""
    AcquisitionIdentity(domain, generation, sequence)

Represent the indivisible physical-acquisition identity tuple.
"""
struct AcquisitionIdentity
    domain::AcquisitionDomain
    generation::UInt64
    sequence::UInt64
end

"""
    AcquisitionExposureStart(nanoseconds, uncertainty_nanoseconds)

Represent exposure start in local `CLOCK_MONOTONIC` nanoseconds and its
inclusive uncertainty bound.
"""
struct AcquisitionExposureStart
    nanoseconds::Int64
    uncertainty_nanoseconds::UInt64
end

"A borrowed Version 1 acquisition metadata allocation belonging to a buffer."
struct AcquisitionMetadata{BufferType<:AbstractPipeWireBuffer}
    metadata::BufferMetadata{BufferType}
end

"Acquisition identity is valid."
const ACQUISITION_FLAG_IDENTITY_VALID =
    LibPipeWire.SPA_META_ACQUISITION_FLAG_IDENTITY_VALID
"Exposure start and timestamp uncertainty are valid."
const ACQUISITION_FLAG_EXPOSURE_START_VALID =
    LibPipeWire.SPA_META_ACQUISITION_FLAG_EXPOSURE_START_VALID
"Exposure duration is valid."
const ACQUISITION_FLAG_EXPOSURE_DURATION_VALID =
    LibPipeWire.SPA_META_ACQUISITION_FLAG_EXPOSURE_DURATION_VALID

const _ACQUISITION_SIZE = Int32(LibPipeWire.SPA_META_ACQUISITION_SIZE)
const _ACQUISITION_FEATURE_VERSION_1 =
    Int32(LibPipeWire.SPA_META_FEATURE_ACQUISITION_VERSION_1)

@inline function _acquisition_storage_pointer(metadata::AcquisitionMetadata)
    native = _native_metadata(metadata.metadata)
    native.type == SPA.META_ACQUISITION || throw(
        InvalidStateException("the metadata entry is not acquisition metadata", :wrong_type),
    )
    native.size >= UInt32(_ACQUISITION_SIZE) || throw(
        InvalidStateException("the acquisition metadata payload is truncated", :truncated),
    )
    native.data == C_NULL && throw(
        InvalidStateException("the acquisition metadata payload is unavailable", :unavailable),
    )
    pointer = Ptr{LibPipeWire.spa_meta_acquisition}(native.data)
    UInt(pointer) & UInt(7) == 0 || throw(
        InvalidStateException("the acquisition metadata payload is misaligned", :misaligned),
    )
    return pointer
end

@inline function _checked_acquisition_int64(value::Integer, description::AbstractString)
    typemin(Int64) <= value <= typemax(Int64) ||
        throw(ArgumentError("$description is outside Int64 range"))
    return Int64(value)
end

@inline function _checked_acquisition_uint64(value::Integer, description::AbstractString)
    0 <= value <= typemax(UInt64) ||
        throw(ArgumentError("$description is outside UInt64 range"))
    return UInt64(value)
end

"Producer lifecycle state carried by a progressive metadata snapshot."
@enum ProgressiveState::UInt32 begin
    PROGRESSIVE_PREPARED = LibPipeWire.SPA_META_PROGRESSIVE_STATE_PREPARED
    PROGRESSIVE_ACTIVE = LibPipeWire.SPA_META_PROGRESSIVE_STATE_ACTIVE
    PROGRESSIVE_COMPLETE = LibPipeWire.SPA_META_PROGRESSIVE_STATE_COMPLETE
    PROGRESSIVE_ABORTED = LibPipeWire.SPA_META_PROGRESSIVE_STATE_ABORTED
end

"One atomic view of the immutable payload prefix and producer lifecycle state."
struct ProgressiveSnapshot
    committed_bytes::UInt32
    state::ProgressiveState
end

"An acquire-observed progressive snapshot; flags are zero before producer quiescence."
struct ProgressiveObservation
    snapshot::ProgressiveSnapshot
    terminal_flags::UInt32
end

"A borrowed Version 1 progressive metadata allocation belonging to a buffer."
struct ProgressiveMetadata{BufferType<:AbstractPipeWireBuffer}
    metadata::BufferMetadata{BufferType}
end

"The producer stopped before publishing the complete payload."
const PROGRESSIVE_FLAG_INCOMPLETE = UInt32(1 << 0)
"The producer detected an invalid negotiated payload layout."
const PROGRESSIVE_FLAG_INVALID_LAYOUT = UInt32(1 << 1)
"Progressive production was cancelled."
const PROGRESSIVE_FLAG_CANCELLED = UInt32(1 << 2)
"A device failed while producing the payload."
const PROGRESSIVE_FLAG_DEVICE_ERROR = UInt32(1 << 3)
"The producer detected corrupt payload data."
const PROGRESSIVE_FLAG_CORRUPTED = UInt32(1 << 4)
"The producer detected a progressive protocol violation."
const PROGRESSIVE_FLAG_PROTOCOL_ERROR = UInt32(1 << 5)

const _PROGRESSIVE_FLAG_ALL = UInt32((1 << 6) - 1)
const _PROGRESSIVE_SIZE = UInt32(48)
const _PROGRESSIVE_FEATURE_VERSION_1 = Int32(1 << 0)

@inline function _progressive_storage_pointer(metadata::ProgressiveMetadata)
    native = _native_metadata(metadata.metadata)
    native.type == SPA.META_PROGRESSIVE || throw(
        InvalidStateException("the metadata entry is not progressive metadata", :wrong_type),
    )
    native.size >= _PROGRESSIVE_SIZE || throw(
        InvalidStateException("the progressive metadata payload is truncated", :truncated),
    )
    native.data == C_NULL && throw(
        InvalidStateException("the progressive metadata payload is unavailable", :unavailable),
    )
    pointer = Ptr{LibPipeWire.spa_meta_progressive}(native.data)
    UInt(pointer) & UInt(7) == 0 || throw(
        InvalidStateException("the progressive metadata payload is misaligned", :misaligned),
    )
    return pointer
end

@inline function _decode_progressive_snapshot(value::UInt64)
    committed = Ref{UInt32}()
    state = Ref{UInt32}()
    LibPipeWire.spa_meta_progressive_snapshot_decode(value, committed, state) || return nothing
    return ProgressiveSnapshot(committed[], ProgressiveState(state[]))
end

@inline function _progressive_observation_pointer(
    pointer::Ptr{LibPipeWire.spa_meta_progressive},
)
    value = LibPipeWire.spa_meta_progressive_load_acquire(pointer)
    snapshot = _decode_progressive_snapshot(value)
    snapshot === nothing && return nothing

    terminal_flags = if snapshot.state in (PROGRESSIVE_COMPLETE, PROGRESSIVE_ABORTED)
        unsafe_load(pointer.terminal_flags)
    else
        UInt32(0)
    end
    return ProgressiveObservation(snapshot, terminal_flags)
end

@inline function _checked_progressive_uint32(value::Integer, description::AbstractString)
    0 <= value <= typemax(UInt32) || throw(
        ArgumentError("$description is outside UInt32 range"),
    )
    return UInt32(value)
end

@inline function _progressive_snapshot_value(snapshot::ProgressiveSnapshot)
    return LibPipeWire.spa_meta_progressive_snapshot_encode(
        snapshot.committed_bytes,
        UInt32(snapshot.state),
    )
end

"An owned snapshot of a SPA buffer chunk."
struct BufferChunk
    offset::UInt32
    size::UInt32
    stride::Int32
    flags::Int32
end

"An owned snapshot of SPA header metadata."
struct BufferHeader
    flags::UInt32
    offset::UInt32
    pts::Int64
    dts_offset::Int64
    sequence::UInt64
end

"An owned rectangular metadata region."
struct BufferRegion
    x::Int32
    y::Int32
    width::UInt32
    height::UInt32
end

"An owned inline-bitmap metadata snapshot."
struct BufferBitmap
    format::UInt32
    width::UInt32
    height::UInt32
    stride::Int32
    data::Vector{UInt8}
end

Base.:(==)(left::BufferBitmap, right::BufferBitmap) =
    left.format == right.format &&
    left.width == right.width &&
    left.height == right.height &&
    left.stride == right.stride &&
    left.data == right.data
Base.isequal(left::BufferBitmap, right::BufferBitmap) =
    isequal(left.format, right.format) &&
    isequal(left.width, right.width) &&
    isequal(left.height, right.height) &&
    isequal(left.stride, right.stride) &&
    isequal(left.data, right.data)
Base.hash(value::BufferBitmap, seed::UInt) =
    hash((value.format, value.width, value.height, value.stride, value.data), seed)

"An owned cursor metadata snapshot with an optional inline bitmap."
struct BufferCursor{Bitmap}
    id::UInt32
    flags::UInt32
    x::Int32
    y::Int32
    hotspot_x::Int32
    hotspot_y::Int32
    bitmap::Bitmap
end

function BufferCursor(
    id::Integer,
    flags::Integer,
    x::Integer,
    y::Integer,
    hotspot_x::Integer,
    hotspot_y::Integer,
    bitmap,
)
    object_id = _core_uint32(id, "cursor ID")
    native_flags = _core_uint32(flags, "cursor flags")
    values = (x, y, hotspot_x, hotspot_y)
    all(value -> typemin(Int32) <= value <= typemax(Int32), values) ||
        throw(ArgumentError("a cursor coordinate is outside Int32 range"))
    return BufferCursor(
        object_id,
        native_flags,
        Int32(x),
        Int32(y),
        Int32(hotspot_x),
        Int32(hotspot_y),
        bitmap,
    )
end

"An owned busy-counter metadata snapshot."
struct BufferBusy
    flags::UInt32
    count::UInt32
end

"An owned explicit-synchronization timeline snapshot."
struct BufferSyncTimeline
    flags::UInt32
    acquire_point::UInt64
    release_point::UInt64
end

function _require_available(buffer::StreamBuffer)
    buffer.handle == C_NULL &&
        throw(InvalidStateException("the PipeWire stream buffer was already returned", :returned))
    return buffer.handle
end

function _spa_buffer(buffer::AbstractPipeWireBuffer)
    pointer = unsafe_load(_require_available(buffer)).buffer
    pointer == C_NULL &&
        throw(InvalidStateException("the PipeWire buffer has no SPA buffer", :no_buffer))
    return pointer
end

"Copy the mutable accounting fields attached to a PipeWire buffer."
function buffer_info(buffer::AbstractPipeWireBuffer)
    native = unsafe_load(_require_available(buffer))
    return BufferInfo(native.user_data, native.size, native.requested, native.time)
end

"Set the application-defined size accounting field on an available buffer."
function set_buffer_size!(buffer::AbstractPipeWireBuffer, size::Integer)
    0 <= size <= typemax(UInt64) ||
        throw(ArgumentError("buffer size is outside UInt64 range"))
    pointer = _require_available(buffer)
    native = unsafe_load(pointer)
    unsafe_store!(
        pointer,
        LibPipeWire.pw_buffer(
            native.buffer,
            native.user_data,
            UInt64(size),
            native.requested,
            native.time,
        ),
    )
    return buffer
end

"Return the number of metadata entries attached to a PipeWire buffer."
metadata_count(buffer::AbstractPipeWireBuffer) = Int(unsafe_load(_spa_buffer(buffer)).n_metas)

"Return a borrowed metadata entry by one-based index."
function buffer_metadata(buffer::AbstractPipeWireBuffer, index::Integer)
    count = metadata_count(buffer)
    1 <= index <= count || throw(BoundsError(1:count, index))
    return BufferMetadata(buffer, Int(index))
end

"Return the first borrowed metadata entry of `type`, or `nothing`."
function buffer_metadata(buffer::AbstractPipeWireBuffer, type::UInt32)
    count = metadata_count(buffer)
    for index in 1:count
        metadata = BufferMetadata(buffer, index)
        metadata_type(metadata) == type && return metadata
    end
    return nothing
end

function _native_metadata_pointer(metadata::BufferMetadata)
    buffer = unsafe_load(_spa_buffer(metadata.buffer))
    1 <= metadata.index <= Int(buffer.n_metas) ||
        throw(InvalidStateException("the metadata entry is unavailable", :unavailable))
    buffer.metas == C_NULL &&
        throw(InvalidStateException("the PipeWire buffer has no metadata array", :no_metadata))
    return buffer.metas + (metadata.index - 1) * sizeof(LibPipeWire.spa_meta)
end

_native_metadata(metadata::BufferMetadata) = unsafe_load(_native_metadata_pointer(metadata))

metadata_type(metadata::BufferMetadata) = _native_metadata(metadata).type
metadata_size(metadata::BufferMetadata) = Int(_native_metadata(metadata).size)
metadata_pointer(metadata::BufferMetadata) = _native_metadata(metadata).data

"""
    buffer_acquisition(buffer)

Return borrowed Version 1 acquisition metadata, or `nothing` when absent.
Reject a present allocation that is undersized, unavailable, or misaligned.
"""
function buffer_acquisition(buffer::AbstractPipeWireBuffer)
    metadata = buffer_metadata(buffer, SPA.META_ACQUISITION)
    metadata === nothing && return nothing
    acquisition = AcquisitionMetadata(metadata)
    _acquisition_storage_pointer(acquisition)
    return acquisition
end

"""
    acquisition_valid(metadata)

Return whether acquisition metadata satisfies the native Version 1 contract.
"""
function acquisition_valid(metadata::AcquisitionMetadata)
    return LibPipeWire.spa_meta_acquisition_is_valid(
        _native_metadata_pointer(metadata.metadata),
    )
end

"""
    acquisition_flags(metadata)

Return the validated acquisition validity flags.
"""
function acquisition_flags(metadata::AcquisitionMetadata)
    acquisition_valid(metadata) || throw(
        InvalidStateException("the acquisition metadata is malformed", :malformed),
    )
    return unsafe_load(_acquisition_storage_pointer(metadata).flags)
end

"""
    acquisition_identity(metadata)

Return the complete validated acquisition identity, or `nothing` when absent.
"""
function acquisition_identity(metadata::AcquisitionMetadata)
    flags = acquisition_flags(metadata)
    flags & ACQUISITION_FLAG_IDENTITY_VALID == 0 && return nothing
    pointer = _acquisition_storage_pointer(metadata)
    return AcquisitionIdentity(
        AcquisitionDomain(unsafe_load(pointer.domain)),
        unsafe_load(pointer.generation),
        unsafe_load(pointer.sequence),
    )
end

"""
    acquisition_exposure_start(metadata)

Return validated exposure start and uncertainty, or `nothing` when absent.
The timestamp uses the local Linux `CLOCK_MONOTONIC` domain.
"""
function acquisition_exposure_start(metadata::AcquisitionMetadata)
    flags = acquisition_flags(metadata)
    flags & ACQUISITION_FLAG_EXPOSURE_START_VALID == 0 && return nothing
    pointer = _acquisition_storage_pointer(metadata)
    return AcquisitionExposureStart(
        unsafe_load(pointer.exposure_start_nsec),
        unsafe_load(pointer.timestamp_uncertainty_nsec),
    )
end

"""
    acquisition_exposure_duration(metadata)

Return the validated exposure duration in nanoseconds, or `nothing` when absent.
"""
function acquisition_exposure_duration(metadata::AcquisitionMetadata)
    flags = acquisition_flags(metadata)
    flags & ACQUISITION_FLAG_EXPOSURE_DURATION_VALID == 0 && return nothing
    return unsafe_load(_acquisition_storage_pointer(metadata).exposure_duration_nsec)
end

"""
    initialize_acquisition!(metadata)

Clear reusable acquisition metadata to its valid, empty Version 1 state.
"""
function initialize_acquisition!(metadata::AcquisitionMetadata)
    LibPipeWire.spa_meta_acquisition_init(_acquisition_storage_pointer(metadata)) ||
        throw(InvalidStateException("the acquisition metadata cannot be initialized", :invalid))
    return metadata
end

"""
    set_acquisition_identity!(metadata, identity)

Establish the complete acquisition identity tuple.
"""
function set_acquisition_identity!(
    metadata::AcquisitionMetadata,
    identity::AcquisitionIdentity,
)
    domain = Ref(identity.domain.bytes)
    domain_pointer = Ptr{UInt8}(Base.unsafe_convert(Ptr{typeof(identity.domain.bytes)}, domain))
    valid = GC.@preserve domain LibPipeWire.spa_meta_acquisition_set_identity(
        _acquisition_storage_pointer(metadata),
        domain_pointer,
        identity.generation,
        identity.sequence,
    )
    valid || throw(ArgumentError("the acquisition identity is invalid"))
    return metadata
end

"""
    set_acquisition_exposure_start!(metadata, nanoseconds, uncertainty_nanoseconds)

Establish exposure start in local `CLOCK_MONOTONIC` nanoseconds and its
inclusive uncertainty bound.
"""
function set_acquisition_exposure_start!(
    metadata::AcquisitionMetadata,
    nanoseconds::Integer,
    uncertainty_nanoseconds::Integer,
)
    valid = LibPipeWire.spa_meta_acquisition_set_exposure_start(
        _acquisition_storage_pointer(metadata),
        _checked_acquisition_int64(nanoseconds, "exposure start"),
        _checked_acquisition_uint64(uncertainty_nanoseconds, "timestamp uncertainty"),
    )
    valid || throw(ArgumentError("the acquisition exposure start is invalid"))
    return metadata
end

"""
    set_acquisition_exposure_duration!(metadata, nanoseconds)

Establish a positive exposure duration in nanoseconds.
"""
function set_acquisition_exposure_duration!(
    metadata::AcquisitionMetadata,
    nanoseconds::Integer,
)
    valid = LibPipeWire.spa_meta_acquisition_set_exposure_duration(
        _acquisition_storage_pointer(metadata),
        _checked_acquisition_uint64(nanoseconds, "exposure duration"),
    )
    valid || throw(ArgumentError("the acquisition exposure duration is invalid"))
    return metadata
end

"""
    acquisition_identity_equal(a, b)

Return whether two allocations contain the same complete, valid acquisition
identity. Return `false` when either allocation is malformed or lacks identity.
"""
function acquisition_identity_equal(a::AcquisitionMetadata, b::AcquisitionMetadata)
    return LibPipeWire.spa_meta_acquisition_identity_equal(
        _acquisition_storage_pointer(a),
        _acquisition_storage_pointer(b),
    )
end

"Return borrowed Version 1 progressive metadata, or `nothing` when absent."
function buffer_progressive(buffer::AbstractPipeWireBuffer)
    metadata = buffer_metadata(buffer, SPA.META_PROGRESSIVE)
    metadata === nothing && return nothing
    progressive = ProgressiveMetadata(metadata)
    _progressive_storage_pointer(progressive)
    return progressive
end

"Return the zero-based native data-plane index described by progressive metadata."
progressive_data_index(metadata::ProgressiveMetadata) =
    unsafe_load(_progressive_storage_pointer(metadata).data_index)

"Return the byte offset of the progressive payload in its data plane."
progressive_payload_offset(metadata::ProgressiveMetadata) =
    unsafe_load(_progressive_storage_pointer(metadata).payload_offset)

"Return the total byte length of the progressive payload."
progressive_payload_size(metadata::ProgressiveMetadata) =
    unsafe_load(_progressive_storage_pointer(metadata).payload_size)

"Return the negotiated byte increment for non-final progressive commits."
progressive_commit_granularity(metadata::ProgressiveMetadata) =
    unsafe_load(_progressive_storage_pointer(metadata).commit_granularity)

"Return whether a progressive metadata allocation contains a valid Version 1 state."
function progressive_valid(metadata::ProgressiveMetadata)
    return LibPipeWire.spa_meta_progressive_is_valid(
        _native_metadata_pointer(metadata.metadata),
    )
end

"Acquire-load and validate the current progressive snapshot."
function progressive_snapshot(metadata::ProgressiveMetadata)
    progressive_valid(metadata) || throw(
        InvalidStateException("the progressive metadata is malformed", :malformed),
    )
    observation = _progressive_observation_pointer(_progressive_storage_pointer(metadata))
    observation === nothing && throw(
        InvalidStateException("the progressive metadata is malformed", :malformed),
    )
    return observation.snapshot
end

"Acquire-load progressive state and read flags only after producer quiescence."
function progressive_observation(metadata::ProgressiveMetadata)
    progressive_valid(metadata) || throw(
        InvalidStateException("the progressive metadata is malformed", :malformed),
    )
    observation = _progressive_observation_pointer(_progressive_storage_pointer(metadata))
    observation === nothing && throw(
        InvalidStateException("the progressive metadata is malformed", :malformed),
    )
    return observation
end

"""
    initialize_progressive!(metadata, data_index, payload_offset,
                            payload_size, commit_granularity)

Initialize a borrowed metadata allocation in `Prepared`. `data_index` is the
zero-based native SPA data-plane index. Call this before announcing the buffer
to a consumer.
"""
function initialize_progressive!(
    metadata::ProgressiveMetadata,
    data_index::Integer,
    payload_offset::Integer,
    payload_size::Integer,
    commit_granularity::Integer,
)
    return _initialize_progressive!(
        metadata,
        _checked_progressive_uint32(data_index, "progressive data index"),
        _checked_progressive_uint32(payload_offset, "progressive payload offset"),
        _checked_progressive_uint32(payload_size, "progressive payload size"),
        _checked_progressive_uint32(
            commit_granularity,
            "progressive commit granularity",
        ),
    )
end

@inline function _initialize_progressive!(
    metadata::ProgressiveMetadata,
    data_index::UInt32,
    payload_offset::UInt32,
    payload_size::UInt32,
    commit_granularity::UInt32,
)
    pointer = _progressive_storage_pointer(metadata)
    LibPipeWire.spa_meta_progressive_init(
        pointer,
        data_index,
        payload_offset,
        payload_size,
        commit_granularity,
    ) || throw(ArgumentError("the progressive metadata layout is invalid"))
    return metadata
end

"""
    set_progressive_terminal_flags!(metadata, flags)

Set terminal outcome flags while the producer is in `Prepared` or `Active`.
Publish `Complete` or `Aborted` afterward so the release-store makes these
flags visible to consumers.
"""
function set_progressive_terminal_flags!(metadata::ProgressiveMetadata, flags::Integer)
    return _set_progressive_terminal_flags!(
        metadata,
        _checked_progressive_uint32(flags, "progressive terminal flags"),
    )
end

@inline function _set_progressive_terminal_flags!(
    metadata::ProgressiveMetadata,
    flags::UInt32,
)
    flags & ~_PROGRESSIVE_FLAG_ALL == 0 || throw(
        ArgumentError("progressive terminal flags contain reserved bits"),
    )
    progressive_valid(metadata) || throw(
        InvalidStateException("the progressive metadata is malformed", :malformed),
    )
    pointer = _progressive_storage_pointer(metadata)
    observation = _progressive_observation_pointer(pointer)
    observation === nothing && throw(
        InvalidStateException("the progressive metadata is malformed", :malformed),
    )
    observation.snapshot.state in (PROGRESSIVE_PREPARED, PROGRESSIVE_ACTIVE) || throw(
        InvalidStateException("the progressive producer is already terminal", :terminal),
    )
    unsafe_store!(pointer.terminal_flags, flags)
    return metadata
end

"""
    publish_progressive!(metadata, committed, state=PROGRESSIVE_ACTIVE)

Release-publish a monotonic committed byte prefix and lifecycle transition.
The valid transitions are `Prepared -> Active` and `Active -> Active`,
`Complete`, or `Aborted`. A `Complete` publication requires the whole payload.
"""
function publish_progressive!(
    metadata::ProgressiveMetadata,
    committed::Integer,
    state::ProgressiveState=PROGRESSIVE_ACTIVE,
)
    return _publish_progressive!(
        metadata,
        _checked_progressive_uint32(committed, "progressive committed prefix"),
        state,
    )
end

@inline function _publish_progressive!(
    metadata::ProgressiveMetadata,
    committed::UInt32,
    state::ProgressiveState,
)
    progressive_valid(metadata) || throw(
        InvalidStateException("the progressive metadata is malformed", :malformed),
    )
    pointer = _progressive_storage_pointer(metadata)
    observation = _progressive_observation_pointer(pointer)
    observation === nothing && throw(
        InvalidStateException("the progressive metadata is malformed", :malformed),
    )
    current = observation.snapshot
    if current.state == PROGRESSIVE_PREPARED
        state == PROGRESSIVE_ACTIVE || throw(
            InvalidStateException("progressive metadata must become active first", :prepared),
        )
    elseif current.state == PROGRESSIVE_ACTIVE
        state in (PROGRESSIVE_ACTIVE, PROGRESSIVE_COMPLETE, PROGRESSIVE_ABORTED) || throw(
            InvalidStateException("the progressive state transition is invalid", :invalid),
        )
    else
        throw(InvalidStateException("the progressive producer is already terminal", :terminal))
    end

    payload_size = unsafe_load(pointer.payload_size)
    granularity = unsafe_load(pointer.commit_granularity)
    current.committed_bytes <= committed <= payload_size || throw(
        InvalidStateException("the progressive prefix is not monotonic", :nonmonotonic),
    )
    (committed == payload_size || committed % granularity == 0) || throw(
        InvalidStateException("the progressive prefix is not on a commit boundary", :unaligned),
    )
    state != PROGRESSIVE_COMPLETE || committed == payload_size || throw(
        InvalidStateException("a complete progressive payload must be fully committed", :incomplete),
    )

    LibPipeWire.spa_meta_progressive_store_release(
        pointer,
        _progressive_snapshot_value(ProgressiveSnapshot(committed, state)),
    )
    return metadata
end

"Return a borrowed byte view of a metadata payload."
function metadata_bytes(metadata::BufferMetadata)
    native = _native_metadata(metadata)
    return UnsafeArray(Ptr{UInt8}(native.data), (Int(native.size),))
end

function _typed_metadata(buffer::AbstractPipeWireBuffer, type::UInt32, ::Type{T}) where {T}
    metadata = buffer_metadata(buffer, type)
    metadata === nothing && return nothing
    native = _native_metadata(metadata)
    native.size >= sizeof(T) || throw(
        InvalidStateException("the buffer metadata payload is truncated", :truncated),
    )
    native.data == C_NULL &&
        throw(InvalidStateException("the buffer metadata payload is unavailable", :unavailable))
    return unsafe_load(Ptr{T}(native.data))
end

"Return copied SPA header metadata, or `nothing` when absent."
function buffer_header(buffer::AbstractPipeWireBuffer)
    native = _typed_metadata(
        buffer,
        LibPipeWire.SPA_META_Header,
        LibPipeWire.spa_meta_header,
    )
    native === nothing && return nothing
    return BufferHeader(
        native.flags,
        native.offset,
        native.pts,
        native.dts_offset,
        native.seq,
    )
end

"""
    set_buffer_header!(buffer, header)

Overwrite the existing SPA header metadata on an available PipeWire buffer.
The buffer must contain a complete, writable `SPA_META_Header` payload.
"""
function set_buffer_header!(buffer::AbstractPipeWireBuffer, header::BufferHeader)
    metadata = buffer_metadata(buffer, LibPipeWire.SPA_META_Header)
    metadata === nothing && throw(
        InvalidStateException("the PipeWire buffer has no header metadata", :no_metadata),
    )
    native = _native_metadata(metadata)
    native.size >= sizeof(LibPipeWire.spa_meta_header) || throw(
        InvalidStateException("the buffer metadata payload is truncated", :truncated),
    )
    native.data == C_NULL && throw(
        InvalidStateException("the buffer metadata payload is unavailable", :unavailable),
    )
    unsafe_store!(
        Ptr{LibPipeWire.spa_meta_header}(native.data),
        LibPipeWire.spa_meta_header(
            header.flags,
            header.offset,
            header.pts,
            header.dts_offset,
            header.sequence,
        ),
    )
    return buffer
end

function _buffer_region(native::LibPipeWire.spa_meta_region)
    return BufferRegion(
        native.region.position.x,
        native.region.position.y,
        native.region.size.width,
        native.region.size.height,
    )
end

"Return copied video-crop metadata, or `nothing` when absent."
function video_crop(buffer::AbstractPipeWireBuffer)
    native = _typed_metadata(
        buffer,
        LibPipeWire.SPA_META_VideoCrop,
        LibPipeWire.spa_meta_region,
    )
    return native === nothing ? nothing : _buffer_region(native)
end

"Return all valid copied video-damage regions."
function video_damage(buffer::AbstractPipeWireBuffer)
    metadata = buffer_metadata(buffer, LibPipeWire.SPA_META_VideoDamage)
    metadata === nothing && return BufferRegion[]
    native = _native_metadata(metadata)
    count = Int(native.size) ÷ sizeof(LibPipeWire.spa_meta_region)
    native.data == C_NULL && return BufferRegion[]
    regions = BufferRegion[]
    sizehint!(regions, count)
    pointer = Ptr{LibPipeWire.spa_meta_region}(native.data)
    for index in 1:count
        region = _buffer_region(unsafe_load(pointer, index))
        (region.width == 0 || region.height == 0) && break
        push!(regions, region)
    end
    return regions
end

function _copy_buffer_bitmap(pointer::Ptr{Cvoid}, available::Int)
    available >= sizeof(LibPipeWire.spa_meta_bitmap) || throw(
        InvalidStateException("the bitmap metadata payload is truncated", :truncated),
    )
    native = unsafe_load(Ptr{LibPipeWire.spa_meta_bitmap}(pointer))
    data = if native.offset == 0
        UInt8[]
    else
        sizeof(LibPipeWire.spa_meta_bitmap) <= native.offset <= available || throw(
            InvalidStateException("the bitmap metadata offset is invalid", :invalid_offset),
        )
        copy(
            unsafe_wrap(
                Vector{UInt8},
                Ptr{UInt8}(pointer) + Int(native.offset),
                available - Int(native.offset);
                own=false,
            ),
        )
    end
    return BufferBitmap(
        native.format,
        native.size.width,
        native.size.height,
        native.stride,
        data,
    )
end

"Return copied inline-bitmap metadata, or `nothing` when absent."
function buffer_bitmap(buffer::AbstractPipeWireBuffer)
    metadata = buffer_metadata(buffer, LibPipeWire.SPA_META_Bitmap)
    metadata === nothing && return nothing
    native = _native_metadata(metadata)
    native.data == C_NULL &&
        throw(InvalidStateException("the bitmap metadata is unavailable", :unavailable))
    return _copy_buffer_bitmap(native.data, Int(native.size))
end

"Return copied cursor metadata, or `nothing` when absent."
function buffer_cursor(buffer::AbstractPipeWireBuffer)
    metadata = buffer_metadata(buffer, LibPipeWire.SPA_META_Cursor)
    metadata === nothing && return nothing
    native = _native_metadata(metadata)
    native.size >= sizeof(LibPipeWire.spa_meta_cursor) || throw(
        InvalidStateException("the cursor metadata payload is truncated", :truncated),
    )
    native.data == C_NULL &&
        throw(InvalidStateException("the cursor metadata is unavailable", :unavailable))
    cursor = unsafe_load(Ptr{LibPipeWire.spa_meta_cursor}(native.data))
    bitmap = if cursor.bitmap_offset == 0
        nothing
    else
        sizeof(LibPipeWire.spa_meta_cursor) <= cursor.bitmap_offset < native.size || throw(
            InvalidStateException("the cursor bitmap offset is invalid", :invalid_offset),
        )
        _copy_buffer_bitmap(
            Ptr{Cvoid}(Ptr{UInt8}(native.data) + Int(cursor.bitmap_offset)),
            Int(native.size - cursor.bitmap_offset),
        )
    end
    return BufferCursor(
        cursor.id,
        cursor.flags,
        cursor.position.x,
        cursor.position.y,
        cursor.hotspot.x,
        cursor.hotspot.y,
        bitmap,
    )
end

"Return copied timed-control sequence metadata, or `nothing` when absent."
function buffer_control(buffer::AbstractPipeWireBuffer)
    metadata = buffer_metadata(buffer, LibPipeWire.SPA_META_Control)
    metadata === nothing && return nothing
    native = _native_metadata(metadata)
    native.data == C_NULL &&
        throw(InvalidStateException("the control metadata is unavailable", :unavailable))
    native.size >= sizeof(LibPipeWire.spa_pod) || throw(
        InvalidStateException("the control metadata payload is truncated", :truncated),
    )
    header = unsafe_load(Ptr{LibPipeWire.spa_pod}(native.data))
    sizeof(LibPipeWire.spa_pod) + Int(header.size) <= Int(native.size) || throw(
        InvalidStateException("the control metadata POD is truncated", :truncated),
    )
    return _copy_pod(Ptr{LibPipeWire.spa_pod}(native.data))
end

"Return copied buffer-busy metadata, or `nothing` when absent."
function buffer_busy(buffer::AbstractPipeWireBuffer)
    native = _typed_metadata(
        buffer,
        LibPipeWire.SPA_META_Busy,
        LibPipeWire.spa_meta_busy,
    )
    return native === nothing ? nothing : BufferBusy(native.flags, native.count)
end

"Return copied video-transform metadata, or `nothing` when absent."
function video_transform(buffer::AbstractPipeWireBuffer)
    native = _typed_metadata(
        buffer,
        LibPipeWire.SPA_META_VideoTransform,
        LibPipeWire.spa_meta_videotransform,
    )
    return native === nothing ? nothing : native.transform
end

"Return copied explicit-sync timeline metadata, or `nothing` when absent."
function sync_timeline(buffer::AbstractPipeWireBuffer)
    native = _typed_metadata(
        buffer,
        LibPipeWire.SPA_META_SyncTimeline,
        LibPipeWire.spa_meta_sync_timeline,
    )
    native === nothing && return nothing
    return BufferSyncTimeline(native.flags, native.acquire_point, native.release_point)
end

"""
    dequeue_buffer(stream) -> Union{Nothing,StreamBuffer}

Dequeue a buffer, returning `nothing` when none is available. This convenience
method allocates a wrapper; use [`dequeue_buffer!`](@ref) on hot paths.
"""
function dequeue_buffer(stream::Stream)
    _check_callback_error(stream)
    handle = lock(stream.state_lock) do
        LibPipeWire.pw_stream_dequeue_buffer(_require_open(stream))
    end
    return handle == C_NULL ? nothing : StreamBuffer(handle)
end

"""
    dequeue_buffer!(buffer::StreamBuffer, stream::Stream) -> Bool

Dequeue into a reusable buffer wrapper. Return `true` when a buffer was
available and `false` otherwise. This form avoids the wrapper allocation made
by [`dequeue_buffer`](@ref).
"""
function dequeue_buffer!(buffer::StreamBuffer, stream::Stream)
    buffer.handle == C_NULL || throw(
        InvalidStateException("the previous PipeWire stream buffer is still dequeued", :dequeued),
    )
    _check_callback_error(stream)
    handle = lock(stream.state_lock) do
        LibPipeWire.pw_stream_dequeue_buffer(_require_open(stream))
    end
    buffer.handle = handle
    return handle != C_NULL
end

function _return_stream_buffer!(operation, buffer::StreamBuffer, stream::Stream)
    handle = _require_available(buffer)
    result = lock(stream.state_lock) do
        _require_open(stream)
        operation(stream.handle, handle)
    end
    _check_result(
        operation === LibPipeWire.pw_stream_queue_buffer ?
        :pw_stream_queue_buffer : :pw_stream_return_buffer,
        result,
    )
    buffer.handle = Ptr{LibPipeWire.pw_buffer}(C_NULL)
    return stream
end

"Queue a dequeued buffer, clear its wrapper, and return `stream`."
queue_buffer!(buffer::StreamBuffer, stream::Stream) =
    _return_stream_buffer!(LibPipeWire.pw_stream_queue_buffer, buffer, stream)
"Return a dequeued buffer, clear its wrapper, and return `stream`."
return_buffer!(buffer::StreamBuffer, stream::Stream) =
    _return_stream_buffer!(LibPipeWire.pw_stream_return_buffer, buffer, stream)

"""A borrowed data plane belonging to a [`StreamBuffer`](@ref)."""
struct StreamData <: AbstractPipeWireData
    buffer::StreamBuffer
    index::Int
end

"An explicitly memory-mapped PipeWire data plane."
mutable struct MappedBufferData{DataType<:AbstractPipeWireData}
    pointer::Ptr{UInt8}
    length::Int
    data::DataType
end

const MappedStreamData = MappedBufferData{StreamData}

"Return a borrowed data-plane view from a dequeued stream buffer."
function buffer_data(buffer::StreamBuffer, index::Integer=1)
    native_buffer = unsafe_load(_require_available(buffer)).buffer
    native_buffer == C_NULL && throw(InvalidStateException("the stream buffer has no SPA buffer", :no_buffer))
    count = Int(unsafe_load(native_buffer).n_datas)
    1 <= index <= count || throw(BoundsError(1:count, index))
    return StreamData(buffer, Int(index))
end

function _native_data(data::StreamData)
    native_buffer = unsafe_load(_require_available(data.buffer)).buffer
    buffer = unsafe_load(native_buffer)
    return unsafe_load(buffer.datas, data.index)
end

"Return the SPA memory type for a PipeWire data plane."
data_type(data::AbstractPipeWireData) = _native_data(data).type
"Return the SPA memory flags for a PipeWire data plane."
data_flags(data::AbstractPipeWireData) = _native_data(data).flags
"Return the file descriptor for a PipeWire data plane, or `-1` when absent."
data_fd(data::AbstractPipeWireData) = _native_data(data).fd
"Return the page-aligned mapping offset for a file-backed data plane."
data_map_offset(data::AbstractPipeWireData) = _native_data(data).mapoffset
"Return whether a PipeWire data plane already has a native memory mapping."
is_mapped(data::AbstractPipeWireData) = _native_data(data).data != C_NULL

function _allocation_sizes(sizes)
    requested_sizes = Int[]
    for size in sizes
        0 <= size <= typemax(UInt32) ||
            throw(ArgumentError("buffer data size is outside UInt32 range"))
        push!(requested_sizes, Int(size))
    end
    return requested_sizes
end

function _allocate_buffer!(owner, target, buffer, sizes, flags)
    buffer == C_NULL && throw(ArgumentError("the native PipeWire buffer is null"))
    native_flags = _core_uint32(flags, "buffer data flags")
    requested_sizes = _allocation_sizes(sizes)
    lock(owner.state_lock)
    try
        _require_open(target)
        native_buffer = unsafe_load(buffer).buffer
        native_buffer == C_NULL &&
            throw(InvalidStateException("the PipeWire buffer has no SPA buffer", :no_buffer))
        spa_buffer = unsafe_load(native_buffer)
        length(requested_sizes) == Int(spa_buffer.n_datas) || throw(
            DimensionMismatch("one allocation size is required for each PipeWire data plane"),
        )
        spa_buffer.datas == C_NULL && !isempty(requested_sizes) && throw(
            InvalidStateException("the PipeWire buffer has no data array", :no_data),
        )

        storage = [Vector{UInt8}(undef, size) for size in requested_sizes]
        GC.@preserve storage begin
            for index in eachindex(storage)
                current = unsafe_load(spa_buffer.datas, index)
                unsafe_store!(
                    spa_buffer.datas,
                    LibPipeWire.spa_data(
                        LibPipeWire.SPA_DATA_MemPtr,
                        native_flags,
                        Int64(-1),
                        UInt32(0),
                        UInt32(length(storage[index])),
                        pointer(storage[index]),
                        current.chunk,
                    ),
                    index,
                )
            end
        end
        owner.buffer_owners[buffer] = storage
        return storage
    finally
        unlock(owner.state_lock)
    end
end

"""
    allocate_buffer!(stream, buffer, sizes; flags=SPA.DATA_FLAG_READWRITE)

Allocate Julia-owned `MemPtr` storage for every native data plane in `buffer`.
Call this from `on_buffer_added` when connecting with
[`STREAM_ALLOC_BUFFERS`](@ref). The stream roots the storage until the native
buffer is removed. `buffer` is the raw pointer supplied to that callback.
"""
function allocate_buffer!(
    stream::Stream,
    buffer::Ptr{LibPipeWire.pw_buffer},
    sizes;
    flags::Integer=SPA.DATA_FLAG_READWRITE,
)
    return _allocate_buffer!(stream, stream, buffer, sizes, flags)
end

allocate_buffer!(
    stream::Stream,
    buffer::Ptr{LibPipeWire.pw_buffer},
    size::Integer;
    flags::Integer=SPA.DATA_FLAG_READWRITE,
) = allocate_buffer!(stream, buffer, (size,); flags)

"""
    map_data(data; writable=false)

Map an fd-backed `MemFd` or mappable `DmaBuf` plane. Close the returned mapping
before queueing or returning its buffer. DMA-BUF synchronization remains the
caller's responsibility.
"""
function map_data(data::AbstractPipeWireData; writable::Bool=false)
    native = _native_data(data)
    native.data == C_NULL ||
        throw(InvalidStateException("the PipeWire data plane is already mapped", :mapped))
    native.type in (LibPipeWire.SPA_DATA_MemFd, LibPipeWire.SPA_DATA_DmaBuf) || throw(
        InvalidStateException("the PipeWire data plane is not fd-backed", :not_fd_backed),
    )
    native.type != LibPipeWire.SPA_DATA_DmaBuf ||
        native.flags & SPA.DATA_FLAG_MAPPABLE != 0 ||
        throw(InvalidStateException("the DMA-BUF data plane is not mappable", :not_mappable))
    typemin(Cint) <= native.fd <= typemax(Cint) ||
        throw(InvalidStateException("the PipeWire data file descriptor is invalid", :invalid_fd))
    writable && native.flags & SPA.DATA_FLAG_WRITABLE == 0 && throw(
        InvalidStateException("the PipeWire data plane is not writable", :readonly),
    )
    native.maxsize == 0 && throw(
        InvalidStateException("the PipeWire data plane has zero capacity", :empty),
    )

    protection = Cint(1 | (writable ? 2 : 0))
    pointer = ccall(
        :mmap,
        Ptr{Cvoid},
        (Ptr{Cvoid}, Csize_t, Cint, Cint, Cint, Int64),
        C_NULL,
        Csize_t(native.maxsize),
        protection,
        Cint(1),
        Cint(native.fd),
        Int64(native.mapoffset),
    )
    pointer == Ptr{Cvoid}(typemax(UInt)) &&
        throw(PipeWireError(:mmap, -Base.Libc.errno()))
    mapping = MappedBufferData(Ptr{UInt8}(pointer), Int(native.maxsize), data)
    finalizer(close, mapping)
    return mapping
end

function Base.isopen(mapping::MappedBufferData)
    return mapping.pointer != C_NULL
end

function Base.close(mapping::MappedBufferData)
    mapping.pointer == C_NULL && return nothing
    result = ccall(:munmap, Cint, (Ptr{Cvoid}, Csize_t), mapping.pointer, mapping.length)
    result < 0 && throw(PipeWireError(:munmap, -Base.Libc.errno()))
    mapping.pointer = Ptr{UInt8}(C_NULL)
    mapping.length = 0
    return nothing
end

"Return the full borrowed byte view of an open explicit mapping."
function bytes(mapping::MappedBufferData)
    mapping.pointer == C_NULL &&
        throw(InvalidStateException("the PipeWire data mapping is closed", :closed))
    return UnsafeArray(mapping.pointer, (mapping.length,))
end

"Return the writable capacity in bytes of a PipeWire data plane."
capacity(data::AbstractPipeWireData) = Int(_native_data(data).maxsize)

"Return the native memory pointer for a PipeWire data plane."
function data_pointer(data::AbstractPipeWireData)
    native = _native_data(data)
    native.data == C_NULL &&
        throw(InvalidStateException("the PipeWire data plane is not mapped", :unmapped))
    return Ptr{UInt8}(native.data)
end

function _chunk(data::AbstractPipeWireData)
    native = _native_data(data)
    native.chunk == C_NULL &&
        throw(InvalidStateException("the PipeWire data plane has no chunk", :no_chunk))
    return native, native.chunk, unsafe_load(native.chunk)
end

"Return an owned snapshot of the current chunk in a PipeWire data plane."
function chunk_info(data::AbstractPipeWireData)
    _, _, chunk = _chunk(data)
    return BufferChunk(chunk.offset, chunk.size, chunk.stride, chunk.flags)
end

"Return a borrowed byte view of the current chunk in a PipeWire data plane."
function bytes(data::AbstractPipeWireData)
    native, _, chunk = _chunk(data)
    pointer = data_pointer(data)
    offset = Int(chunk.offset % max(native.maxsize, UInt32(1)))
    size = min(Int(chunk.size), Int(native.maxsize) - offset)
    return UnsafeArray(pointer + offset, (size,))
end

"""
    buffer_memory(data[, length])

Return a borrowed byte view of the mapped memory backing a PipeWire data plane.
By default the view spans the plane's full capacity; pass `length` to request a
bounded prefix. The view does not own the memory and is valid only while the
containing PipeWire buffer is leased.
"""
function buffer_memory(data::AbstractPipeWireData, length::Integer=capacity(data))
    available = capacity(data)
    0 <= length <= available || throw(ArgumentError(
        "requested memory length $length is outside the data-plane capacity $available",
    ))
    return UnsafeArray(data_pointer(data), (Int(length),))
end

Base.@deprecate writable_bytes(data::AbstractPipeWireData) buffer_memory(data)

"Set valid chunk bounds for a PipeWire data plane and return `data`."
function set_chunk!(
    data::AbstractPipeWireData;
    offset::Integer=0,
    size::Integer,
    stride::Integer=0,
)
    native, pointer, chunk = _chunk(data)
    0 <= offset <= native.maxsize || throw(ArgumentError("chunk offset exceeds data capacity"))
    0 <= size <= native.maxsize - offset || throw(ArgumentError("chunk size exceeds data capacity"))
    unsafe_store!(
        pointer,
        LibPipeWire.spa_chunk(UInt32(offset), UInt32(size), Int32(stride), chunk.flags),
    )
    return data
end

function run!(stream::Stream)
    run!(main_loop(stream))
    _check_callback_error(stream)
    return nothing
end

quit!(stream::Stream) = quit!(main_loop(stream))
