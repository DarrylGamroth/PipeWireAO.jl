"Create a filter in the inactive state."
const FILTER_INACTIVE = LibPipeWire.PW_FILTER_FLAG_INACTIVE
"Make a filter a graph driver."
const FILTER_DRIVER = LibPipeWire.PW_FILTER_FLAG_DRIVER
"Disable PipeWire's default filter latency handling."
const FILTER_CUSTOM_LATENCY = LibPipeWire.PW_FILTER_FLAG_CUSTOM_LATENCY
"Enable explicit filter processing triggers."
const FILTER_TRIGGER = LibPipeWire.PW_FILTER_FLAG_TRIGGER
"Dequeue and queue filter buffers outside the real-time process callback."
const FILTER_ASYNC = LibPipeWire.PW_FILTER_FLAG_ASYNC
"Request memory-mapped buffers for a filter port."
const FILTER_PORT_MAP_BUFFERS = LibPipeWire.PW_FILTER_PORT_FLAG_MAP_BUFFERS
"Let the application allocate buffers for a filter port."
const FILTER_PORT_ALLOC_BUFFERS = LibPipeWire.PW_FILTER_PORT_FLAG_ALLOC_BUFFERS

"Link property that enables graph-independent latest-buffer ownership."
const BUFFER_LATEST_LINK_PROPERTY = "link.buffer-latest"
"Input-port property that selects the latest-buffer receiver wait policy."
const BUFFER_LATEST_WAIT_PROPERTY = "port.buffer-latest.wait"
"Link property reporting the negotiated latest-buffer receiver wait policy."
const BUFFER_LATEST_LINK_WAIT_PROPERTY = "link.buffer-latest.wait"
"Wait continuously on latest-buffer shared state."
const BUFFER_LATEST_WAIT_BUSY_SPIN = "busy-spin"
"Wait for advisory latest-buffer eventfd notifications."
const BUFFER_LATEST_WAIT_EVENTFD = "eventfd"
"Busy-wait first, then use advisory latest-buffer eventfd notifications."
const BUFFER_LATEST_WAIT_HYBRID = "hybrid"
"SPA I/O identifier for graph-independent latest-buffer shared state."
const BUFFER_LATEST_IO = LibPipeWire.SPA_IO_BuffersLatest
"SPA I/O identifier for the process-local latest-buffer notification fd."
const BUFFER_LATEST_NOTIFY_IO = LibPipeWire.SPA_IO_BuffersLatestNotify

"A borrowed I/O area reported by a filter I/O-change callback."
struct FilterIO
    id::UInt32
    area::Ptr{Cvoid}
    size::UInt32
end

"""
    FilterPosition

A borrowed graph-position view supplied to a filter process callback. The view
is valid only for the duration of that callback. Use [`position_snapshot`](@ref)
to make a concrete copy that can be retained.
"""
struct FilterPosition
    pointer::Ptr{LibPipeWire.spa_io_position}
end

"Copy a borrowed filter position into a concrete native position value."
function position_snapshot(position::FilterPosition)
    position.pointer == C_NULL &&
        throw(InvalidStateException("the filter position is unavailable", :unavailable))
    return unsafe_load(position.pointer)
end

"""
    FilterPort

A port owned by a [`Filter`](@ref), with caller data stored in the concrete
`Data` type parameter. Closing the filter or calling [`remove_port!`](@ref)
invalidates the port.
"""
mutable struct FilterPort{FilterType,Data}
    handle::Ptr{Cvoid}
    filter::FilterType
    direction::Direction
    data::Data
end

"""
    FilterBuffer()

Create a reusable filter-buffer wrapper. A successfully dequeued buffer must
be returned with [`queue_buffer!`](@ref) before this wrapper can be reused.
"""
mutable struct FilterBuffer <: AbstractPipeWireBuffer
    handle::Ptr{LibPipeWire.pw_buffer}
    port_data::Ptr{Cvoid}
end

FilterBuffer() = FilterBuffer(
    Ptr{LibPipeWire.pw_buffer}(C_NULL),
    Ptr{Cvoid}(C_NULL),
)

"""
    ProgressiveFilterBuffer(port)

Create a reusable, initially inactive progressive-output lease for `port`.
Call [`begin_progressive!`](@ref) to transfer a dequeued [`FilterBuffer`](@ref)
into the lease and [`end_progressive!`](@ref) exactly once to release it.

This type deliberately does not implement the ordinary buffer interface. Once
the buffer is announced, a consumer may observe committed ranges concurrently,
so whole-payload access is unsafe. The lease has no finalizer; it must be ended
before the port is disconnected or removed. Exactly one worker may access the
port while using this lease, and the port must have exactly one latest-buffer
link.
"""
mutable struct ProgressiveFilterBuffer{PortType<:FilterPort}
    handle::Ptr{LibPipeWire.pw_buffer}
    port::PortType
end

ProgressiveFilterBuffer(port::PortType) where {PortType<:FilterPort} =
    ProgressiveFilterBuffer{PortType}(Ptr{LibPipeWire.pw_buffer}(C_NULL), port)

"Return whether `lease` currently owns an announced progressive buffer."
progressive_active(lease::ProgressiveFilterBuffer) = lease.handle != C_NULL

"A borrowed data plane belonging to a [`FilterBuffer`](@ref)."
struct FilterData <: AbstractPipeWireData
    buffer::FilterBuffer
    index::Int
end

const FilterMetadata = BufferMetadata{FilterBuffer}
const MappedFilterData = MappedBufferData{FilterData}

"""
    Filter(core, name; properties=nothing, callbacks...)

Create an owning PipeWire filter. Callback types are stored in the concrete
filter type. Julia callbacks are not hard-real-time safe, so
`FILTER_RT_PROCESS` is deliberately unavailable.

The callback keywords are `on_state_changed`, `on_io_changed`,
`on_param_changed`, `on_buffer_added`, `on_buffer_removed`, `on_process`,
`on_drained`, and `on_command`. The process callback receives
`(filter, position)`, where `position` is either a borrowed
[`FilterPosition`](@ref) or `nothing`. A warmed process callback whose callable
does not allocate has a zero-byte steady-state allocation contract. Callback
errors, copied parameter/command PODs, and an explicitly copied position
snapshot are excluded.
"""
mutable struct Filter{CoreType<:CoreConnection,Callbacks}
    handle::Ptr{LibPipeWire.pw_filter}
    core::CoreType
    state_lock::ReentrantLock
    callback_lock::ReentrantLock
    listener::Base.RefValue{LibPipeWire.spa_hook}
    events::Base.RefValue{LibPipeWire.pw_filter_events}
    callbacks::Callbacks
    callback_error::Base.RefValue{Any}
    ports::Vector{FilterPort}
    buffer_owners::Dict{Ptr{LibPipeWire.pw_buffer},Vector{Vector{UInt8}}}
    callbacks_active::Bool
    connected::Bool
end

function _filter_port(filter::Filter, pointer::Ptr{Cvoid})
    pointer == C_NULL && return nothing
    return lock(filter.state_lock) do
        for port in filter.ports
            port.handle == pointer && return port
        end
        return nothing
    end
end

function _record_filter_callback_error(
    filter::Filter{CoreType,Callbacks},
    error,
) where {CoreType,Callbacks}
    lock(filter.callback_lock) do
        filter.callback_error[] === nothing && (filter.callback_error[] = error)
    end
    _stop_after_callback(filter.core.callback_state, error)
    return nothing
end

function _active_filter_callback(
    filter::Filter{CoreType,Callbacks},
    ::Val{Field},
) where {CoreType,Callbacks,Field}
    state = filter.core.callback_state
    lock(filter.callback_lock)
    if !filter.callbacks_active
        unlock(filter.callback_lock)
        return nothing, state
    end
    callback = getfield(filter.callbacks, Field)
    unlock(filter.callback_lock)
    return callback, state
end

function _invoke_filter_callback(
    filter::Filter{CoreType,Callbacks},
    ::Val{Field},
) where {CoreType,Callbacks,Field}
    callback, _ = _active_filter_callback(filter, Val(Field))
    callback === nothing && return nothing
    try
        callback(filter)
    catch error
        _record_filter_callback_error(filter, error)
    end
    return nothing
end

function _invoke_filter_callback(
    filter::Filter{CoreType,Callbacks},
    ::Val{Field},
    first::A,
) where {CoreType,Callbacks,Field,A}
    callback, _ = _active_filter_callback(filter, Val(Field))
    callback === nothing && return nothing
    try
        callback(filter, first)
    catch error
        _record_filter_callback_error(filter, error)
    end
    return nothing
end

function _invoke_filter_callback(
    filter::Filter{CoreType,Callbacks},
    ::Val{Field},
    first::A,
    second::B,
) where {CoreType,Callbacks,Field,A,B}
    callback, _ = _active_filter_callback(filter, Val(Field))
    callback === nothing && return nothing
    try
        callback(filter, first, second)
    catch error
        _record_filter_callback_error(filter, error)
    end
    return nothing
end

function _invoke_filter_callback(
    filter::Filter{CoreType,Callbacks},
    ::Val{Field},
    first::A,
    second::B,
    third::C,
) where {CoreType,Callbacks,Field,A,B,C}
    callback, _ = _active_filter_callback(filter, Val(Field))
    callback === nothing && return nothing
    try
        callback(filter, first, second, third)
    catch error
        _record_filter_callback_error(filter, error)
    end
    return nothing
end

function _filter_state_changed(
    filter::Filter,
    old::Int32,
    current::Int32,
    message::Cstring,
)::Cvoid
    detail = message == C_NULL ? nothing : unsafe_string(message)
    _invoke_filter_callback(filter, Val(:on_state_changed), old, current, detail)
    return nothing
end

function _filter_io_changed(
    filter::Filter,
    port_data::Ptr{Cvoid},
    id::UInt32,
    area::Ptr{Cvoid},
    size::UInt32,
)::Cvoid
    _invoke_filter_callback(
        filter,
        Val(:on_io_changed),
        _filter_port(filter, port_data),
        FilterIO(id, area, size),
    )
    return nothing
end

function _filter_param_changed(
    filter::Filter,
    port_data::Ptr{Cvoid},
    id::UInt32,
    param::Ptr{LibPipeWire.spa_pod},
)::Cvoid
    try
        _invoke_filter_callback(
            filter,
            Val(:on_param_changed),
            _filter_port(filter, port_data),
            id,
            _copy_pod(param),
        )
    catch error
        lock(filter.callback_lock) do
            filter.callback_error[] === nothing && (filter.callback_error[] = error)
        end
        _stop_after_callback(filter.core.callback_state, error)
    end
    return nothing
end

function _filter_buffer_added(
    filter::Filter,
    port_data::Ptr{Cvoid},
    buffer::Ptr{LibPipeWire.pw_buffer},
)::Cvoid
    _invoke_filter_callback(
        filter,
        Val(:on_buffer_added),
        _filter_port(filter, port_data),
        buffer,
    )
    return nothing
end

function _filter_buffer_removed(
    filter::Filter,
    port_data::Ptr{Cvoid},
    buffer::Ptr{LibPipeWire.pw_buffer},
)::Cvoid
    try
        _invoke_filter_callback(
            filter,
            Val(:on_buffer_removed),
            _filter_port(filter, port_data),
            buffer,
        )
    finally
        lock(filter.state_lock) do
            pop!(filter.buffer_owners, buffer, nothing)
        end
    end
    return nothing
end

function _filter_process(
    filter::Filter,
    position::Ptr{LibPipeWire.spa_io_position},
)::Cvoid
    view = position == C_NULL ? nothing : FilterPosition(position)
    _invoke_filter_callback(filter, Val(:on_process), view)
    return nothing
end

function _filter_drained(filter::Filter)::Cvoid
    _invoke_filter_callback(filter, Val(:on_drained))
    return nothing
end

function _filter_command(
    filter::Filter,
    command::Ptr{LibPipeWire.spa_command},
)::Cvoid
    try
        _invoke_filter_callback(
            filter,
            Val(:on_command),
            _copy_pod(Ptr{LibPipeWire.spa_pod}(command)),
        )
    catch error
        lock(filter.callback_lock) do
            filter.callback_error[] === nothing && (filter.callback_error[] = error)
        end
        _stop_after_callback(filter.core.callback_state, error)
    end
    return nothing
end

function _filter_events(::T) where {T<:Filter}
    state_changed = @cfunction(
        _filter_state_changed,
        Cvoid,
        (Ref{T}, Int32, Int32, Cstring),
    )
    io_changed = @cfunction(
        _filter_io_changed,
        Cvoid,
        (Ref{T}, Ptr{Cvoid}, UInt32, Ptr{Cvoid}, UInt32),
    )
    param_changed = @cfunction(
        _filter_param_changed,
        Cvoid,
        (Ref{T}, Ptr{Cvoid}, UInt32, Ptr{LibPipeWire.spa_pod}),
    )
    buffer_added = @cfunction(
        _filter_buffer_added,
        Cvoid,
        (Ref{T}, Ptr{Cvoid}, Ptr{LibPipeWire.pw_buffer}),
    )
    buffer_removed = @cfunction(
        _filter_buffer_removed,
        Cvoid,
        (Ref{T}, Ptr{Cvoid}, Ptr{LibPipeWire.pw_buffer}),
    )
    process = @cfunction(
        _filter_process,
        Cvoid,
        (Ref{T}, Ptr{LibPipeWire.spa_io_position}),
    )
    drained = @cfunction(_filter_drained, Cvoid, (Ref{T},))
    command = @cfunction(
        _filter_command,
        Cvoid,
        (Ref{T}, Ptr{LibPipeWire.spa_command}),
    )
    return LibPipeWire.pw_filter_events(
        UInt32(1),
        _NULL_CALLBACK,
        state_changed,
        io_changed,
        param_changed,
        buffer_added,
        buffer_removed,
        process,
        drained,
        command,
    )
end

function Filter(
    core::CoreConnection,
    name::AbstractString;
    properties=nothing,
    on_state_changed=nothing,
    on_io_changed=nothing,
    on_param_changed=nothing,
    on_buffer_added=nothing,
    on_buffer_removed=nothing,
    on_process=nothing,
    on_drained=nothing,
    on_command=nothing,
)
    name_string = _validate_c_string(String(name), "filter name")
    core_handle = _retain_filter(core)
    native_properties = try
        _owned_native_properties(properties)
    catch
        _release_filter(core)
        rethrow()
    end
    handle = GC.@preserve name_string LibPipeWire.pw_filter_new(
        core_handle,
        pointer(name_string),
        native_properties,
    )
    if handle == C_NULL
        _release_filter(core)
        throw(PipeWireError(:pw_filter_new, -Base.Libc.errno()))
    end

    callbacks = (
        on_state_changed=on_state_changed,
        on_io_changed=on_io_changed,
        on_param_changed=on_param_changed,
        on_buffer_added=on_buffer_added,
        on_buffer_removed=on_buffer_removed,
        on_process=on_process,
        on_drained=on_drained,
        on_command=on_command,
    )
    listener = Ref(_zero_hook())
    events = Ref{LibPipeWire.pw_filter_events}()
    filter = Filter(
        handle,
        core,
        ReentrantLock(),
        ReentrantLock(),
        listener,
        events,
        callbacks,
        Ref{Any}(nothing),
        FilterPort[],
        Dict{Ptr{LibPipeWire.pw_buffer},Vector{Vector{UInt8}}}(),
        true,
        false,
    )
    try
        events[] = _filter_events(filter)
    catch
        close(filter)
        rethrow()
    end
    GC.@preserve filter listener events LibPipeWire.pw_filter_add_listener(
        handle,
        Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener),
        Base.unsafe_convert(Ptr{LibPipeWire.pw_filter_events}, events),
        pointer_from_objref(filter),
    )
    finalizer(close, filter)
    return filter
end

main_loop(filter::Filter) = main_loop(filter.core)

function _require_open(filter::Filter)
    filter.handle == C_NULL &&
        throw(InvalidStateException("the PipeWire filter is closed", :closed))
    return filter.handle
end

function _require_open(port::FilterPort)
    port.handle == C_NULL &&
        throw(InvalidStateException("the PipeWire filter port is closed", :closed))
    _require_open(port.filter)
    return port.handle
end

function _check_callback_error(filter::Filter)
    error = lock(filter.callback_lock) do
        filter.callback_error[]
    end
    error === nothing || throw(error)
    return nothing
end

Base.isopen(filter::Filter) = lock(filter.state_lock) do
    filter.handle != C_NULL
end

Base.isopen(port::FilterPort) = lock(port.filter.state_lock) do
    port.handle != C_NULL && port.filter.handle != C_NULL
end

function Base.close(filter::Filter)
    handle = lock(filter.state_lock) do
        filter.handle == C_NULL && return C_NULL
        handle = filter.handle
        filter.handle = Ptr{LibPipeWire.pw_filter}(C_NULL)
        filter.connected = false
        return handle
    end
    handle == C_NULL && return nothing
    lock(filter.callback_lock) do
        filter.callbacks_active = false
    end
    LibPipeWire.pw_filter_destroy(handle)
    for port in filter.ports
        port.handle = C_NULL
    end
    empty!(filter.ports)
    empty!(filter.buffer_owners)
    _release_filter(filter.core)
    return nothing
end

"Return the current native filter state, throwing a reported filter error."
function filter_state(filter::Filter)
    _check_callback_error(filter)
    error_pointer = Ref{Cstring}(C_NULL)
    value = lock(filter.state_lock) do
        LibPipeWire.pw_filter_get_state(_require_open(filter), error_pointer)
    end
    if value == LibPipeWire.PW_FILTER_STATE_ERROR
        detail = error_pointer[] == C_NULL ? nothing : unsafe_string(error_pointer[])
        throw(PipeWireError(:pw_filter, Cint(-Base.Libc.errno()), detail))
    end
    return value
end

"Return the native name of `filter`."
function filter_name(filter::Filter)
    pointer = lock(filter.state_lock) do
        LibPipeWire.pw_filter_get_name(_require_open(filter))
    end
    return pointer == C_NULL ? "" : unsafe_string(pointer)
end

"Return the bound PipeWire node ID for `filter`."
function node_id(filter::Filter)
    _check_callback_error(filter)
    return lock(filter.state_lock) do
        LibPipeWire.pw_filter_get_node_id(_require_open(filter))
    end
end

function _filter_params(params)
    native_params = Pod[pod for pod in params]
    pointers = Ptr{LibPipeWire.spa_pod}[_pod_pointer(pod) for pod in native_params]
    return native_params, pointers
end

"Connect `filter` for processing and return it."
function connect!(filter::Filter; flags::Integer=FILTER_ASYNC, params=Pod[])
    native_flags = _core_uint32(flags, "filter flags")
    native_flags & LibPipeWire.PW_FILTER_FLAG_RT_PROCESS == 0 || throw(
        ArgumentError(
            "Julia filter callbacks are not hard-real-time safe; " *
            "RT_PROCESS is unsupported",
        ),
    )
    native_params, pointers = _filter_params(params)
    result = GC.@preserve native_params pointers lock(filter.state_lock) do
        filter.connected && throw(
            InvalidStateException("the PipeWire filter is already connected", :connected),
        )
        result = LibPipeWire.pw_filter_connect(
            _require_open(filter),
            native_flags,
            isempty(pointers) ? C_NULL : pointer(pointers),
            UInt32(length(pointers)),
        )
        result >= 0 && (filter.connected = true)
        result
    end
    _check_result(:pw_filter_connect, result)
    return filter
end

"Disconnect `filter` and return it."
function disconnect!(filter::Filter)
    result = lock(filter.state_lock) do
        handle = _require_open(filter)
        filter.connected || return Cint(0)
        result = LibPipeWire.pw_filter_disconnect(handle)
        result >= 0 && (filter.connected = false)
        result
    end
    _check_result(:pw_filter_disconnect, result)
    return filter
end

function _filter_direction(direction::Symbol)
    direction === :input && return DIRECTION_INPUT
    direction === :output && return DIRECTION_OUTPUT
    throw(ArgumentError("filter port direction must be :input or :output"))
end

"""
    add_port!(filter, direction; data=nothing, flags=0, properties=nothing, params=())

Add an input or output port and return its concrete [`FilterPort`](@ref).
`filter` owns the port lifetime; `data` is stored in the port's type parameter.
"""
function add_port!(
    filter::Filter,
    direction::Symbol;
    data=nothing,
    flags::Integer=0,
    properties=nothing,
    params=Pod[],
)
    native_direction = _filter_direction(direction)
    native_flags = _core_uint32(flags, "filter port flags")
    native_params, pointers = _filter_params(params)
    return GC.@preserve native_params pointers lock(filter.state_lock) do
        handle = _require_open(filter)
        native_properties = _owned_native_properties(properties)
        port_data = LibPipeWire.pw_filter_add_port(
            handle,
            UInt32(native_direction),
            native_flags,
            sizeof(Ptr{Cvoid}),
            native_properties,
            isempty(pointers) ? C_NULL : pointer(pointers),
            UInt32(length(pointers)),
        )
        port_data == C_NULL &&
            throw(PipeWireError(:pw_filter_add_port, -Base.Libc.errno()))
        port = FilterPort(port_data, filter, native_direction, data)
        push!(filter.ports, port)
        return port
    end
end

"Remove `port` from its filter and invalidate it."
function remove_port!(port::FilterPort)
    filter = port.filter
    result = lock(filter.state_lock) do
        handle = _require_open(port)
        result = LibPipeWire.pw_filter_remove_port(handle)
        if result >= 0
            port.handle = C_NULL
            index = findfirst(candidate -> candidate === port, filter.ports)
            index === nothing || deleteat!(filter.ports, index)
        end
        result
    end
    _check_result(:pw_filter_remove_port, result)
    return filter
end

"Return a copied property snapshot for a filter or filter port."
function filter_properties(filter::Filter, port::Union{Nothing,FilterPort}=nothing)
    port === nothing || port.filter === filter ||
        throw(ArgumentError("the filter port belongs to a different filter"))
    pointer = lock(filter.state_lock) do
        LibPipeWire.pw_filter_get_properties(
            _require_open(filter),
            port === nothing ? C_NULL : _require_open(port),
        )
    end
    pointer == C_NULL && return Dict{String,String}()
    native = unsafe_load(pointer)
    dictionary = Ref(native.dict)
    return GC.@preserve dictionary _copy_properties(
        Base.unsafe_convert(Ptr{LibPipeWire.spa_dict}, dictionary),
    )
end

function _update_filter_properties!(filter::Filter, port, properties)
    _with_properties_dict(properties) do dictionary
        result = lock(filter.state_lock) do
            LibPipeWire.pw_filter_update_properties(
                _require_open(filter),
                port === nothing ? C_NULL : _require_open(port),
                dictionary,
            )
        end
        _check_result(:pw_filter_update_properties, result)
    end
    return port === nothing ? filter : port
end

update_properties!(filter::Filter, properties) =
    _update_filter_properties!(filter, nothing, properties)
update_properties!(port::FilterPort, properties) =
    _update_filter_properties!(port.filter, port, properties)

"Update global or port parameters and return the target."
function update_params!(filter::Filter, params; port::Union{Nothing,FilterPort}=nothing)
    port === nothing || port.filter === filter ||
        throw(ArgumentError("the filter port belongs to a different filter"))
    native_params, pointers = _filter_params(params)
    result = GC.@preserve native_params pointers lock(filter.state_lock) do
        LibPipeWire.pw_filter_update_params(
            _require_open(filter),
            port === nothing ? C_NULL : _require_open(port),
            isempty(pointers) ? C_NULL : pointer(pointers),
            UInt32(length(pointers)),
        )
    end
    _check_result(:pw_filter_update_params, result)
    return port === nothing ? filter : port
end

update_params!(port::FilterPort, params) = update_params!(port.filter, params; port)

"Set whether `filter` is active and return it."
function set_active!(filter::Filter, active::Bool=true)
    _check_callback_error(filter)
    result = lock(filter.state_lock) do
        LibPipeWire.pw_filter_set_active(_require_open(filter), active)
    end
    _check_result(:pw_filter_set_active, result)
    return filter
end

"Flush queued filter buffers, optionally draining them first, and return `filter`."
function flush!(filter::Filter; drain::Bool=false)
    _check_callback_error(filter)
    result = lock(filter.state_lock) do
        LibPipeWire.pw_filter_flush(_require_open(filter), drain)
    end
    _check_result(:pw_filter_flush, result)
    return filter
end

"""
    trigger_process!(filter)

Request one graph-processing iteration and return `filter`. A driver filter
must trigger periodically while it is driving; one call is not a durable queue
of future iterations.
"""
function trigger_process!(filter::Filter)
    _check_callback_error(filter)
    result = lock(filter.state_lock) do
        LibPipeWire.pw_filter_trigger_process(_require_open(filter))
    end
    _check_result(:pw_filter_trigger_process, result)
    return filter
end

"Emit an owned SPA event POD from `filter` and return it."
function emit_event!(filter::Filter, event::Pod)
    _check_callback_error(filter)
    object = pod_value(SPA.Object, event)
    LibPipeWire.SPA_TYPE_EVENT_START <= object.type < LibPipeWire._SPA_TYPE_EVENT_LAST ||
        throw(ArgumentError("the POD is not an SPA event object"))
    result = GC.@preserve event lock(filter.state_lock) do
        LibPipeWire.pw_filter_emit_event(
            _require_open(filter),
            Ptr{LibPipeWire.spa_event}(_pod_pointer(event)),
        )
    end
    _check_result(:pw_filter_emit_event, result)
    return filter
end

emit_event!(filter::Filter, event::SPA.Event) = emit_event!(filter, Pod(event))

"""
    set_error!(filter, result, message)

Move `filter` to PipeWire's error state and return it. `result` must be a
negative errno-style value. This main-loop operation is not real-time safe.
"""
function set_error!(filter::Filter, result::Integer, message::AbstractString)
    typemin(Cint) <= result < 0 ||
        throw(ArgumentError("a PipeWire filter error result must be a negative Cint"))
    text = _validate_c_string(String(message), "filter error message")
    format = "%s"
    GC.@preserve text format lock(filter.state_lock) do
        LibPipeWire.pw_filter_set_error(
            _require_open(filter),
            Cint(result),
            pointer(format),
            pointer(text),
        )
    end
    return filter
end

"Return whether a driver filter is currently driving the graph."
is_driving(filter::Filter) = lock(filter.state_lock) do
    LibPipeWire.pw_filter_is_driving(_require_open(filter))
end

"Return whether the graph uses lazy scheduling for `filter`."
is_lazy(filter::Filter) = lock(filter.state_lock) do
    LibPipeWire.pw_filter_is_lazy(_require_open(filter))
end

"Return the filter's current native monotonic time in nanoseconds."
filter_nsec(filter::Filter) = lock(filter.state_lock) do
    LibPipeWire.pw_filter_get_nsec(_require_open(filter))
end

function dequeue_buffer(port::FilterPort)
    _check_callback_error(port.filter)
    handle = lock(port.filter.state_lock) do
        LibPipeWire.pw_filter_dequeue_buffer(_require_open(port))
    end
    return handle == C_NULL ? nothing : FilterBuffer(handle, port.handle)
end

function dequeue_buffer!(buffer::FilterBuffer, port::FilterPort)
    buffer.handle == C_NULL || throw(
        InvalidStateException("the previous PipeWire filter buffer is still dequeued", :dequeued),
    )
    _check_callback_error(port.filter)
    buffer.handle = lock(port.filter.state_lock) do
        LibPipeWire.pw_filter_dequeue_buffer(_require_open(port))
    end
    buffer.port_data = buffer.handle == C_NULL ? C_NULL : port.handle
    return buffer.handle != C_NULL
end

function queue_buffer!(buffer::FilterBuffer, port::FilterPort)
    buffer.handle == C_NULL &&
        throw(InvalidStateException("the PipeWire filter buffer was already queued", :queued))
    buffer.port_data == port.handle ||
        throw(ArgumentError("the filter buffer was dequeued from a different port"))
    result = lock(port.filter.state_lock) do
        LibPipeWire.pw_filter_queue_buffer(_require_open(port), buffer.handle)
    end
    _check_result(:pw_filter_queue_buffer, result)
    buffer.handle = C_NULL
    buffer.port_data = C_NULL
    return port.filter
end

"""
    begin_progressive!(lease, buffer) -> Filter

Announce the dequeued output `buffer` through a graph-independent
latest-buffer link and transfer it into the reusable `lease`. The application
must publish its negotiated progressive active state before this call. On
success, `buffer` becomes unavailable and `lease` must be passed to
[`end_progressive!`](@ref) exactly once instead of [`queue_buffer!`](@ref).

After one warm-up call, the successful path has a zero-byte heap-allocation
contract. Construction, compilation, callback failures, validation failures,
and native PipeWire errors are outside that contract.
"""
function begin_progressive!(lease::ProgressiveFilterBuffer, buffer::FilterBuffer)
    port = lease.port
    filter = port.filter
    _check_callback_error(filter)
    result = lock(filter.state_lock) do
        port_data = _require_open(port)
        port.direction == DIRECTION_OUTPUT || throw(
            ArgumentError("progressive buffers can only be announced from an output port"),
        )
        lease.handle == C_NULL || throw(
            InvalidStateException("the progressive buffer lease is already active", :active),
        )
        buffer.handle == C_NULL && throw(
            InvalidStateException("the PipeWire filter buffer was already queued", :queued),
        )
        buffer.port_data == port_data || throw(
            ArgumentError("the filter buffer was dequeued from a different port"),
        )
        status = LibPipeWire.pw_filter_begin_progressive_buffer(port_data, buffer.handle)
        if status >= 0
            lease.handle = buffer.handle
            buffer.handle = C_NULL
            buffer.port_data = C_NULL
        end
        return status
    end
    _check_result(:pw_filter_begin_progressive_buffer, result)
    return filter
end

"""
    end_progressive!(lease) -> Filter

Release an active progressive-output `lease`. The application must first stop
writing and publish its negotiated terminal state. The allocation is reusable
only after PipeWireAO has also observed the consumer's return. A failed native
call leaves the lease active so the caller can diagnose or retry it.

After one warm-up call, the successful path has a zero-byte heap-allocation
contract. Compilation, callback failures, validation failures, and native
PipeWire errors are outside that contract.
"""
function end_progressive!(lease::ProgressiveFilterBuffer)
    port = lease.port
    filter = port.filter
    _check_callback_error(filter)
    result = lock(filter.state_lock) do
        port_data = _require_open(port)
        lease.handle == C_NULL && throw(
            InvalidStateException("the progressive buffer lease is inactive", :inactive),
        )
        status = LibPipeWire.pw_filter_end_progressive_buffer(port_data, lease.handle)
        status >= 0 && (lease.handle = C_NULL)
        return status
    end
    _check_result(:pw_filter_end_progressive_buffer, result)
    return filter
end

"""
    unsafe_progressive_buffer_pointer(lease) -> Ptr{LibPipeWire.pw_buffer}

Return the native buffer pointer held by an active progressive lease.

This pointer is an unsafe escape hatch for the application-defined progressive
protocol. Use it only to form views of storage that the protocol still grants
to the producer. Do not call the ordinary whole-buffer API, queue the pointer,
or retain it after [`end_progressive!`](@ref).
"""
function unsafe_progressive_buffer_pointer(lease::ProgressiveFilterBuffer)
    lease.handle == C_NULL && throw(
        InvalidStateException("the progressive buffer lease is inactive", :inactive),
    )
    return lease.handle
end

"""
    buffer_latest_fd(port) -> Cint

Return the borrowed advisory notification fd for a connected latest-buffer
port. PipeWireAO owns the descriptor; callers must not close it. Readability is
only a hint, so a receiver must always retry [`dequeue_buffer!`](@ref) after
draining or waiting. Busy-spin ports report `ENODEV`, and ports without
latest-buffer I/O report `ENOTSUP`, as [`PipeWireError`](@ref)s.

After one warm-up call, the successful path has a zero-byte heap-allocation
contract. Compilation, callback failures, and native errors are excluded.
"""
function buffer_latest_fd(port::FilterPort)
    _check_callback_error(port.filter)
    result = lock(port.filter.state_lock) do
        LibPipeWire.pw_filter_get_buffer_latest_fd(_require_open(port))
    end
    return _check_result(:pw_filter_get_buffer_latest_fd, result)
end

"""
    dsp_buffer(port, T, n_samples) -> Ptr{T}

Return the port's DSP buffer pointer, or `C_NULL` when unavailable. The caller
must use the negotiated format and `n_samples` to access this borrowed memory
with the correct element type and extent.
"""
function dsp_buffer(port::FilterPort, ::Type{T}, n_samples::Integer) where {T}
    0 <= n_samples <= typemax(UInt32) ||
        throw(ArgumentError("DSP sample count is outside UInt32 range"))
    return lock(port.filter.state_lock) do
        Ptr{T}(
            LibPipeWire.pw_filter_get_dsp_buffer(_require_open(port), UInt32(n_samples)),
        )
    end
end

function _require_available(buffer::FilterBuffer)
    buffer.handle == C_NULL &&
        throw(InvalidStateException("the PipeWire filter buffer was already queued", :queued))
    return buffer.handle
end

"""
    allocate_buffer!(port, buffer, sizes; flags=SPA.DATA_FLAG_READWRITE)

Allocate Julia-owned `MemPtr` storage for every native data plane in `buffer`.
Call this from `on_buffer_added` for a port created with
[`FILTER_PORT_ALLOC_BUFFERS`](@ref). The filter roots the storage until the
native buffer is removed. `buffer` is the raw pointer supplied to that callback.
"""
function allocate_buffer!(
    port::FilterPort,
    buffer::Ptr{LibPipeWire.pw_buffer},
    sizes;
    flags::Integer=SPA.DATA_FLAG_READWRITE,
)
    return _allocate_buffer!(port.filter, port, buffer, sizes, flags)
end

allocate_buffer!(
    port::FilterPort,
    buffer::Ptr{LibPipeWire.pw_buffer},
    size::Integer;
    flags::Integer=SPA.DATA_FLAG_READWRITE,
) = allocate_buffer!(port, buffer, (size,); flags)

function buffer_data(buffer::FilterBuffer, index::Integer=1)
    native_buffer = unsafe_load(_require_available(buffer)).buffer
    native_buffer == C_NULL && throw(
        InvalidStateException("the filter buffer has no SPA buffer", :no_buffer),
    )
    count = Int(unsafe_load(native_buffer).n_datas)
    1 <= index <= count || throw(BoundsError(1:count, index))
    return FilterData(buffer, Int(index))
end

function _native_data(data::FilterData)
    native_buffer = unsafe_load(_require_available(data.buffer)).buffer
    buffer = unsafe_load(native_buffer)
    return unsafe_load(buffer.datas, data.index)
end

function run!(filter::Filter)
    run!(main_loop(filter))
    _check_callback_error(filter)
    return nothing
end

quit!(filter::Filter) = quit!(main_loop(filter))
