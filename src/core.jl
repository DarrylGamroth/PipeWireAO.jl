const _PW_ID_CORE = UInt32(0)
const _PW_VERSION_CORE = UInt32(4)
const _NULL_CALLBACK = Ptr{Cvoid}(C_NULL)

function _zero_hook()
    null_list = Ptr{LibPipeWire.spa_list}(C_NULL)
    return LibPipeWire.spa_hook(
        LibPipeWire.spa_list(null_list, null_list),
        LibPipeWire.spa_callbacks(C_NULL, C_NULL),
        C_NULL,
        C_NULL,
    )
end

"""
    Context()
    Context([loop]; properties=nothing)

Create an owning PipeWire context. The no-argument constructor also creates
and owns a [`MainLoop`](@ref). When a loop is supplied, it must outlive the
context.

Close every child [`CoreConnection`](@ref) before closing the context.
"""
mutable struct Context{LoopType<:AbstractPipeWireLoop}
    handle::Ptr{LibPipeWire.pw_context}
    loop::LoopType
    state_lock::ReentrantLock
    loaded_modules::Dict{String,Ptr{LibPipeWire.pw_impl_module}}
    core_count::Int
    owns_loop::Bool
end

function _new_context(loop::AbstractPipeWireLoop, owns_loop::Bool, properties)
    native_loop = _retain_context(loop)
    native_properties = try
        _owned_native_properties(properties)
    catch
        _release_context(loop)
        owns_loop && close(loop)
        rethrow()
    end
    handle = LibPipeWire.pw_context_new(native_loop, native_properties, 0)
    if handle == C_NULL
        errno = Base.Libc.errno()
        _release_context(loop)
        owns_loop && close(loop)
        throw(PipeWireError(:pw_context_new, -errno))
    end

    context = Context(
        handle,
        loop,
        ReentrantLock(),
        Dict{String,Ptr{LibPipeWire.pw_impl_module}}(),
        0,
        owns_loop,
    )
    finalizer(close, context)
    return context
end

function _ensure_context_module!(context::Context, name::AbstractString)
    module_name = _validate_c_string(String(name), "PipeWire module name")
    return lock(context.state_lock) do
        handle = _require_open(context)
        get!(context.loaded_modules, module_name) do
            module_handle = GC.@preserve module_name LibPipeWire.pw_context_load_module(
                handle,
                module_name,
                C_NULL,
                C_NULL,
            )
            module_handle == C_NULL && throw(
                PipeWireError(:pw_context_load_module, -Base.Libc.errno()),
            )
            return module_handle
        end
    end
end

"""
    enable_profiler!(context::Context) -> Context

Load the context-side profiler extension and return `context`. Do this before
connecting an embedded (`self=true`) core so that its registry advertises a
[`Profiler`](@ref) global. Binding a profiler from an external daemon loads the
client-side extension automatically.
"""
function enable_profiler!(context::Context)
    _ensure_context_module!(context, "libpipewire-module-profiler")
    return context
end

Context(loop::AbstractPipeWireLoop; properties=nothing) =
    _new_context(loop, false, properties)

function Context(; properties=nothing)
    loop = MainLoop()
    return _new_context(loop, true, properties)
end

function _require_open(context::Context)
    context.handle == C_NULL &&
        throw(InvalidStateException("the PipeWire context is closed", :closed))
    return context.handle
end

"""
    main_loop(context::Context) -> Union{MainLoop,ThreadLoop}
    main_loop(core::CoreConnection) -> Union{MainLoop,ThreadLoop}

Return the main loop associated with a managed PipeWire object.
"""
main_loop(context::Context) = context.loop

"Return a copied property snapshot for a PipeWire context."
function context_properties(context::Context)
    return lock(context.state_lock) do
        pointer = LibPipeWire.pw_context_get_properties(_require_open(context))
        pointer == C_NULL && return Dict{String,String}()
        native = unsafe_load(pointer)
        dictionary = Ref(native.dict)
        return GC.@preserve dictionary _copy_properties(
            Base.unsafe_convert(Ptr{LibPipeWire.spa_dict}, dictionary),
        )
    end
end

"Update PipeWire context properties and return `context`."
function update_properties!(context::Context, properties)
    _with_properties_dict(properties) do dictionary
        result = lock(context.state_lock) do
            LibPipeWire.pw_context_update_properties(_require_open(context), dictionary)
        end
        _check_result(:pw_context_update_properties, result)
    end
    return context
end

function Base.isopen(context::Context)
    return lock(context.state_lock) do
        context.handle != C_NULL
    end
end

function Base.close(context::Context)
    handle = lock(context.state_lock) do
        context.handle == C_NULL && return C_NULL
        context.core_count == 0 || throw(
            InvalidStateException(
                "cannot close a PipeWire context while core connections are open",
                :open_cores,
            ),
        )
        handle = context.handle
        context.handle = Ptr{LibPipeWire.pw_context}(C_NULL)
        return handle
    end
    handle == C_NULL && return nothing

    LibPipeWire.pw_context_destroy(handle)
    _release_context(context.loop)
    context.owns_loop && close(context.loop)
    return nothing
end

function _retain_core(context::Context)
    return lock(context.state_lock) do
        handle = _require_open(context)
        context.core_count += 1
        return handle
    end
end

function _release_core(context::Context)
    return lock(context.state_lock) do
        context.core_count -= 1
        @assert context.core_count >= 0
        return nothing
    end
end

"A copied information snapshot for the connected PipeWire core."
struct CoreInfo
    id::UInt32
    cookie::UInt32
    user_name::String
    host_name::String
    version::String
    name::String
    change_mask::UInt64
    properties::Dict{String,String}
end

"""
    CoreMemory

A copied description from a PipeWire core `add_mem` event. `fd` remains owned
by PipeWire and must not be closed by the callback. `data_type` is one of the
`SPA_DATA_*` constants in [`LibPipeWire`](@ref).
"""
struct CoreMemory
    id::UInt32
    data_type::UInt32
    fd::Cint
    flags::UInt32
end

mutable struct CoreState{LoopType<:AbstractPipeWireLoop}
    loop::LoopType
    lock::ReentrantLock
    pending::Union{Nothing,Cint}
    done::Bool
    error::Base.RefValue{Any}
    active::Bool
    condition::Threads.Condition
end

"""
    CoreConnection

An owning connection to a PipeWire core. Callback types are stored in the type
parameter so native event dispatch can specialize without abstract callable
fields.
"""
mutable struct CoreConnection{Callbacks,ContextType<:Context,StateType<:CoreState}
    handle::Ptr{LibPipeWire.pw_core}
    context::ContextType
    state_lock::ReentrantLock
    registry_count::Int
    stream_count::Int
    filter_count::Int
    proxy_count::Int
    listener::Base.RefValue{LibPipeWire.spa_hook}
    events::Base.RefValue{LibPipeWire.pw_core_events}
    callback_state::StateType
    callbacks::Callbacks
end

function _stop_after_callback(state, error=nothing)
    lock(state.lock) do
        error !== nothing && state.error[] === nothing && (state.error[] = error)
    end
    lock(state.condition) do
        notify(state.condition; all=true)
    end
    if state.loop isa MainLoop
        try
            quit!(state.loop)
        catch quit_error
            lock(state.lock) do
                state.error[] === nothing && (state.error[] = quit_error)
            end
        end
    end
    return nothing
end

function _active_core_callback(
    core::CoreConnection{Callbacks},
    ::Val{Field},
) where {Callbacks,Field}
    state = core.callback_state
    lock(state.lock)
    if !state.active
        unlock(state.lock)
        return nothing, state
    end
    callback = getfield(core.callbacks, Field)
    unlock(state.lock)
    return callback, state
end

function _invoke_core_callback(
    core::CoreConnection{Callbacks},
    field::Val{Field},
    arg1::A,
) where {Callbacks,Field,A}
    callback, state = _active_core_callback(core, field)
    callback === nothing && return nothing
    try
        callback(core, arg1)
    catch error
        _stop_after_callback(state, error)
    end
    return nothing
end

function _invoke_core_callback(
    core::CoreConnection{Callbacks},
    field::Val{Field},
    arg1::A,
    arg2::B,
) where {Callbacks,Field,A,B}
    callback, state = _active_core_callback(core, field)
    callback === nothing && return nothing
    try
        callback(core, arg1, arg2)
    catch error
        _stop_after_callback(state, error)
    end
    return nothing
end

function _invoke_core_callback(
    core::CoreConnection{Callbacks},
    field::Val{Field},
    arg1::A,
    arg2::B,
    arg3::C,
) where {Callbacks,Field,A,B,C}
    callback, state = _active_core_callback(core, field)
    callback === nothing && return nothing
    try
        callback(core, arg1, arg2, arg3)
    catch error
        _stop_after_callback(state, error)
    end
    return nothing
end

function _invoke_core_add_memory(
    core::CoreConnection{Callbacks},
    id::UInt32,
    data_type::UInt32,
    fd::Cint,
    flags::UInt32,
) where {Callbacks}
    callback, state = _active_core_callback(core, Val(:on_add_memory))
    callback === nothing && return nothing
    try
        callback(core, CoreMemory(id, data_type, fd, flags))
    catch error
        _stop_after_callback(state, error)
    end
    return nothing
end

function _copy_core_info(pointer::Ptr{LibPipeWire.pw_core_info})
    pointer == C_NULL && throw(ArgumentError("the core info pointer is null"))
    info = unsafe_load(pointer)
    return CoreInfo(
        info.id,
        info.cookie,
        info.user_name == C_NULL ? "" : unsafe_string(info.user_name),
        info.host_name == C_NULL ? "" : unsafe_string(info.host_name),
        info.version == C_NULL ? "" : unsafe_string(info.version),
        info.name == C_NULL ? "" : unsafe_string(info.name),
        info.change_mask,
        _copy_properties(info.props),
    )
end

function _core_info(
    core::CoreConnection,
    info::Ptr{LibPipeWire.pw_core_info},
)::Cvoid
    try
        _invoke_core_callback(core, Val(:on_info), _copy_core_info(info))
    catch error
        _stop_after_callback(core.callback_state, error)
    end
    return nothing
end

function _core_done(core::CoreConnection, id::UInt32, sequence::Cint)::Cvoid
    state = core.callback_state
    should_stop = lock(state.lock) do
        state.active && state.pending === sequence && (state.done = true)
    end
    _invoke_core_callback(core, Val(:on_done), id, sequence)
    should_stop && _stop_after_callback(state)
    return nothing
end

function _core_ping(core::CoreConnection, id::UInt32, sequence::Cint)::Cvoid
    _invoke_core_callback(core, Val(:on_ping), id, sequence)
    return nothing
end

function _core_error(
    core::CoreConnection,
    id::UInt32,
    sequence::Cint,
    result::Cint,
    message::Cstring,
)::Cvoid
    state = core.callback_state
    detail = message == C_NULL ? nothing : unsafe_string(message)
    error = PipeWireError(:pw_core, result, detail)
    lock(state.lock) do
        state.error[] === nothing && (state.error[] = error)
    end
    _invoke_core_callback(core, Val(:on_error), id, sequence, error)
    _stop_after_callback(state)
    return nothing
end

function _core_remove_id(core::CoreConnection, id::UInt32)::Cvoid
    _invoke_core_callback(core, Val(:on_remove_id), id)
    return nothing
end

function _core_bound_id(
    core::CoreConnection,
    id::UInt32,
    global_id::UInt32,
)::Cvoid
    _invoke_core_callback(core, Val(:on_bound_id), id, global_id)
    return nothing
end

function _core_add_memory(
    core::CoreConnection,
    id::UInt32,
    data_type::UInt32,
    fd::Cint,
    flags::UInt32,
)::Cvoid
    _invoke_core_add_memory(core, id, data_type, fd, flags)
    return nothing
end

function _core_remove_memory(core::CoreConnection, id::UInt32)::Cvoid
    _invoke_core_callback(core, Val(:on_remove_memory), id)
    return nothing
end

function _core_bound_properties(
    core::CoreConnection,
    id::UInt32,
    global_id::UInt32,
    properties::Ptr{LibPipeWire.spa_dict},
)::Cvoid
    try
        _invoke_core_callback(
            core,
            Val(:on_bound_properties),
            id,
            global_id,
            _copy_properties(properties),
        )
    catch error
        _stop_after_callback(core.callback_state, error)
    end
    return nothing
end

function _core_events(::T) where {T<:CoreConnection}
    info = @cfunction(
        _core_info,
        Cvoid,
        (Ref{T}, Ptr{LibPipeWire.pw_core_info}),
    )
    done = @cfunction(_core_done, Cvoid, (Ref{T}, UInt32, Cint))
    ping = @cfunction(_core_ping, Cvoid, (Ref{T}, UInt32, Cint))
    error = @cfunction(
        _core_error,
        Cvoid,
        (Ref{T}, UInt32, Cint, Cint, Cstring),
    )
    remove_id = @cfunction(_core_remove_id, Cvoid, (Ref{T}, UInt32))
    bound_id = @cfunction(
        _core_bound_id,
        Cvoid,
        (Ref{T}, UInt32, UInt32),
    )
    add_memory = @cfunction(
        _core_add_memory,
        Cvoid,
        (Ref{T}, UInt32, UInt32, Cint, UInt32),
    )
    remove_memory = @cfunction(
        _core_remove_memory,
        Cvoid,
        (Ref{T}, UInt32),
    )
    bound_properties = @cfunction(
        _core_bound_properties,
        Cvoid,
        (Ref{T}, UInt32, UInt32, Ptr{LibPipeWire.spa_dict}),
    )
    return LibPipeWire.pw_core_events(
        UInt32(1),
        info,
        done,
        ping,
        error,
        remove_id,
        bound_id,
        add_memory,
        remove_memory,
        bound_properties,
    )
end

"""
    CoreConnection(context::Context; self=false, properties=nothing, callbacks...)

Connect `context` to a PipeWire core. By default this connects to the daemon
selected by PipeWire's client configuration. Set `self=true` to connect the
context to an internal core, primarily for embedded use and deterministic
tests. Pass an already-connected socket as `fd`; PipeWire takes ownership of
that descriptor, including on connection failure. `self` and `fd` are mutually
exclusive. `properties` may be a [`Properties`](@ref) value or any iterable of
string pairs. A `Properties` argument is copied and remains open.

`on_info(core, info)` receives copied [`CoreInfo`](@ref) snapshots.
`on_done(core, id, sequence)` observes synchronization acknowledgements, and
`on_error(core, id, sequence, error)` observes native core errors. Callback
keywords for the remaining core protocol events are `on_ping`, `on_remove_id`,
`on_bound_id`, `on_add_memory`, `on_remove_memory`, and
`on_bound_properties`. The memory callback receives a [`CoreMemory`](@ref);
the bound-properties callback receives copied properties. Callback types are
part of the concrete `CoreConnection` type.

Close every child [`Registry`](@ref), [`Stream`](@ref), [`Filter`](@ref), and
core-created proxy before closing the connection.
"""
function CoreConnection(
    context::Context;
    self::Bool=false,
    fd::Union{Nothing,Integer}=nothing,
    properties=nothing,
    on_info=nothing,
    on_done=nothing,
    on_ping=nothing,
    on_error=nothing,
    on_remove_id=nothing,
    on_bound_id=nothing,
    on_add_memory=nothing,
    on_remove_memory=nothing,
    on_bound_properties=nothing,
)
    self && fd !== nothing &&
        throw(ArgumentError("self and fd select mutually exclusive PipeWire connections"))
    native_fd = if fd === nothing
        nothing
    else
        typemin(Cint) <= fd <= typemax(Cint) ||
            throw(ArgumentError("the PipeWire socket fd is outside Cint range"))
        Cint(fd)
    end
    context_handle = _retain_core(context)
    native_properties = try
        _owned_native_properties(properties)
    catch
        _release_core(context)
        rethrow()
    end
    handle = if self
        LibPipeWire.pw_context_connect_self(context_handle, native_properties, 0)
    elseif native_fd !== nothing
        LibPipeWire.pw_context_connect_fd(context_handle, native_fd, native_properties, 0)
    else
        LibPipeWire.pw_context_connect(context_handle, native_properties, 0)
    end
    if handle == C_NULL
        errno = Base.Libc.errno()
        _release_core(context)
        operation = if self
            :pw_context_connect_self
        elseif native_fd !== nothing
            :pw_context_connect_fd
        else
            :pw_context_connect
        end
        throw(PipeWireError(operation, -errno))
    end

    state = CoreState(
        main_loop(context),
        ReentrantLock(),
        nothing,
        false,
        Ref{Any}(nothing),
        true,
        Threads.Condition(),
    )
    callbacks = (
        on_info=on_info,
        on_done=on_done,
        on_ping=on_ping,
        on_error=on_error,
        on_remove_id=on_remove_id,
        on_bound_id=on_bound_id,
        on_add_memory=on_add_memory,
        on_remove_memory=on_remove_memory,
        on_bound_properties=on_bound_properties,
    )
    listener = Ref(_zero_hook())
    events = Ref{LibPipeWire.pw_core_events}()
    core = CoreConnection(
        handle,
        context,
        ReentrantLock(),
        0,
        0,
        0,
        0,
        listener,
        events,
        state,
        callbacks,
    )
    try
        events[] = _core_events(core)
    catch
        close(core)
        rethrow()
    end
    result = GC.@preserve core listener events begin
        LibPipeWire.pw_core_add_listener(
            handle,
            Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener),
            Base.unsafe_convert(Ptr{LibPipeWire.pw_core_events}, events),
            pointer_from_objref(core),
        )
    end
    if result < 0
        LibPipeWire.pw_core_disconnect(handle)
        _release_core(context)
        throw(PipeWireError(:pw_core_add_listener, result))
    end

    finalizer(close, core)
    return core
end

main_loop(core::CoreConnection) = main_loop(core.context)

function _require_open(core::CoreConnection)
    core.handle == C_NULL &&
        throw(InvalidStateException("the PipeWire core connection is closed", :closed))
    return core.handle
end

function Base.isopen(core::CoreConnection)
    return lock(core.state_lock) do
        core.handle != C_NULL
    end
end

function Base.close(core::CoreConnection)
    handle = lock(core.state_lock) do
        core.handle == C_NULL && return C_NULL
        core.registry_count == 0 || throw(
            InvalidStateException(
                "cannot close a PipeWire core connection while registries are open",
                :open_registries,
            ),
        )
        core.stream_count == 0 || throw(
            InvalidStateException(
                "cannot close a PipeWire core connection while streams are open",
                :open_streams,
            ),
        )
        core.filter_count == 0 || throw(
            InvalidStateException(
                "cannot close a PipeWire core connection while filters are open",
                :open_filters,
            ),
        )
        core.proxy_count == 0 || throw(
            InvalidStateException(
                "cannot close a PipeWire core connection while created proxies are open",
                :open_proxies,
            ),
        )
        handle = core.handle
        core.handle = Ptr{LibPipeWire.pw_core}(C_NULL)
        return handle
    end
    handle == C_NULL && return nothing

    lock(core.callback_state.lock) do
        core.callback_state.active = false
    end
    result = LibPipeWire.pw_core_disconnect(handle)
    _release_core(core.context)
    _check_result(:pw_core_disconnect, result)
    return nothing
end

function _retain_filter(core::CoreConnection)
    return lock(core.state_lock) do
        handle = _require_open(core)
        core.filter_count += 1
        return handle
    end
end

function _release_filter(core::CoreConnection)
    return lock(core.state_lock) do
        core.filter_count -= 1
        @assert core.filter_count >= 0
        return nothing
    end
end

function _retain_stream(core::CoreConnection)
    return lock(core.state_lock) do
        handle = _require_open(core)
        core.stream_count += 1
        return handle
    end
end

function _release_stream(core::CoreConnection)
    return lock(core.state_lock) do
        core.stream_count -= 1
        @assert core.stream_count >= 0
        return nothing
    end
end

function _retain_proxy(core::CoreConnection)
    return lock(core.state_lock) do
        handle = _require_open(core)
        core.proxy_count += 1
        return handle
    end
end

function _release_proxy(core::CoreConnection)
    return lock(core.state_lock) do
        core.proxy_count -= 1
        @assert core.proxy_count >= 0
        return nothing
    end
end

function _retain_registry(core::CoreConnection)
    return lock(core.state_lock) do
        handle = _require_open(core)
        core.registry_count += 1
        return handle
    end
end

function _release_registry(core::CoreConnection)
    return lock(core.state_lock) do
        core.registry_count -= 1
        @assert core.registry_count >= 0
        return nothing
    end
end

function _begin_roundtrip(
    core_handle::Ptr{LibPipeWire.pw_core},
    state::CoreState,
    loop::MainLoop,
    previous::Cint,
)
    sequence = LibPipeWire.pw_core_sync(core_handle, _PW_ID_CORE, previous)
    sequence < 0 && throw(PipeWireError(:pw_core_sync, sequence))
    lock(state.lock) do
        state.pending = sequence
    end
    return sequence
end

function _begin_roundtrip(
    core_handle::Ptr{LibPipeWire.pw_core},
    state::CoreState,
    loop::ThreadLoop,
    previous::Cint,
)
    return with_thread_loop_lock(loop) do _
        sequence = LibPipeWire.pw_core_sync(core_handle, _PW_ID_CORE, previous)
        sequence < 0 && throw(PipeWireError(:pw_core_sync, sequence))
        lock(state.lock) do
            state.pending = sequence
        end
        return sequence
    end
end

function _wait_roundtrip(loop::MainLoop, state::CoreState)
    run!(loop)
    return nothing
end

function _wait_roundtrip(loop::ThreadLoop, state::CoreState)
    started_here = !isrunning(loop)
    started_here && start!(loop)
    try
        lock(state.condition)
        try
            while true
                finished = lock(state.lock) do
                    state.done || state.error[] !== nothing
                end
                finished && return nothing
                wait(state.condition)
            end
        finally
            unlock(state.condition)
        end
    finally
        started_here && stop!(loop)
    end
end

"""
    roundtrip(core::CoreConnection)
    roundtrip(registry::Registry)

Run the associated loop until the PipeWire core acknowledges all messages sent
before this call. A stopped [`ThreadLoop`](@ref) is started for the operation
and stopped again before returning. Registry global events received during the
roundtrip are available from [`globals`](@ref).
"""
function roundtrip(core::CoreConnection)
    core_handle = lock(core.state_lock) do
        _require_open(core)
    end
    state = core.callback_state
    previous = lock(state.lock) do
        state.active || throw(InvalidStateException("the PipeWire core connection is closed", :closed))
        state.pending === nothing || throw(
            InvalidStateException("a PipeWire core roundtrip is already pending", :pending),
        )
        state.error[] = nothing
        state.done = false
        return Cint(0)
    end

    loop = main_loop(core)
    _begin_roundtrip(core_handle, state, loop, previous)

    try
        _wait_roundtrip(loop, state)
        callback_error, done = lock(state.lock) do
            (state.error[], state.done)
        end
        callback_error === nothing || throw(callback_error)
        done || throw(
            InvalidStateException("the PipeWire core roundtrip was interrupted", :interrupted),
        )
    finally
        lock(state.lock) do
            state.pending = nothing
        end
    end
    return nothing
end

function _core_uint32(value::Integer, kind::AbstractString)
    0 <= value <= typemax(UInt32) || throw(ArgumentError("$kind is outside UInt32 range"))
    return UInt32(value)
end

function _core_sequence(value::Integer)
    typemin(Cint) <= value <= typemax(Cint) ||
        throw(ArgumentError("sequence is outside Cint range"))
    return Cint(value)
end

"""
    sync!(core, sequence=0; id=0) -> Cint

Request an asynchronous synchronization barrier and return the sequence that
will be delivered to `on_done`. Use [`roundtrip`](@ref) when a blocking barrier
is preferable.
"""
function sync!(core::CoreConnection, sequence::Integer=0; id::Integer=_PW_ID_CORE)
    object_id = _core_uint32(id, "object ID")
    requested = _core_sequence(sequence)
    result = lock(core.state_lock) do
        LibPipeWire.pw_core_sync(_require_open(core), object_id, requested)
    end
    return _check_result(:pw_core_sync, result)
end

"""
    pong!(core, id, sequence)

Reply to a core `on_ping` event and return `core`.
"""
function pong!(core::CoreConnection, id::Integer, sequence::Integer)
    object_id = _core_uint32(id, "object ID")
    reply = _core_sequence(sequence)
    result = lock(core.state_lock) do
        LibPipeWire.pw_core_pong(_require_open(core), object_id, reply)
    end
    _check_result(:pw_core_pong, result)
    return core
end

"""
    report_error!(core, id, sequence, result, message)

Report a fatal resource error to the PipeWire server and return `core`.
"""
function report_error!(
    core::CoreConnection,
    id::Integer,
    sequence::Integer,
    result::Integer,
    message::AbstractString,
)
    object_id = _core_uint32(id, "object ID")
    requested = _core_sequence(sequence)
    typemin(Cint) <= result <= typemax(Cint) ||
        throw(ArgumentError("result is outside Cint range"))
    detail = _validate_c_string(String(message), "error message")
    native_result = lock(core.state_lock) do
        handle = _require_open(core)
        GC.@preserve detail LibPipeWire.pw_core_error(
            handle,
            object_id,
            requested,
            Cint(result),
            pointer(detail),
        )
    end
    _check_result(:pw_core_error, native_result)
    return core
end

"""
    hello!(core; version=4)

Restart the core protocol conversation and return `core`. PipeWire destroys
all server resources owned by this client except the core and client resource,
so this operation is rejected while managed registries, streams, filters, or
created proxies remain open.
"""
function hello!(core::CoreConnection; version::Integer=_PW_VERSION_CORE)
    requested_version = _core_uint32(version, "core version")
    requested_version <= _PW_VERSION_CORE ||
        throw(ArgumentError("the requested core version is not supported"))
    result = lock(core.state_lock) do
        _require_open(core)
        (
            core.registry_count == 0 &&
            core.stream_count == 0 &&
            core.filter_count == 0 &&
            core.proxy_count == 0
        ) ||
            throw(
                InvalidStateException(
                    "cannot restart the core protocol while managed child resources are open",
                    :open_children,
                ),
            )
        LibPipeWire.pw_core_hello(core.handle, requested_version)
    end
    _check_result(:pw_core_hello, result)
    return core
end

"""
    core_properties(core) -> Dict{String,String}

Return a copied snapshot of the local properties associated with `core`.
"""
function core_properties(core::CoreConnection)
    return lock(core.state_lock) do
        pointer = LibPipeWire.pw_core_get_properties(_require_open(core))
        pointer == C_NULL && throw(PipeWireError(:pw_core_get_properties, -Base.Libc.EIO))
        native = unsafe_load(pointer)
        dictionary = Ref(native.dict)
        GC.@preserve dictionary _copy_properties(
            Base.unsafe_convert(Ptr{LibPipeWire.spa_dict}, dictionary),
        )
    end
end

"""
    update_properties!(core, properties)

Update the local properties associated with a core and its client, then return
`core`.
"""
function update_properties!(core::CoreConnection, properties)
    result = _with_properties_dict(properties) do dictionary
        lock(core.state_lock) do
            LibPipeWire.pw_core_update_properties(_require_open(core), dictionary)
        end
    end
    _check_result(:pw_core_update_properties, result)
    return core
end

"""
    Global

A snapshot of a global object announced by a PipeWire registry. `properties`
contains copied key/value strings and can be inspected independently of the
native callback that produced it.
"""
struct Global
    id::UInt32
    permissions::UInt32
    type::String
    version::UInt32
    properties::Dict{String,String}
end

function Base.show(io::IO, global_object::Global)
    label = get(
        global_object.properties,
        "node.name",
        get(global_object.properties, "object.path", global_object.type),
    )
    return print(io, "Global(", global_object.id, ", ", repr(label), ')')
end

mutable struct RegistryState
    lock::ReentrantLock
    globals::Dict{UInt32,Global}
    error::Base.RefValue{Any}
    core_state::CoreState
    active::Bool
end

"""
    Registry(core::CoreConnection)

Create an owning proxy for the core registry and subscribe to global-object
addition and removal events. Call [`roundtrip`](@ref) to receive the initial
set of globals.
"""
mutable struct Registry{CoreType<:CoreConnection}
    handle::Ptr{LibPipeWire.pw_registry}
    core::CoreType
    state_lock::ReentrantLock
    proxy_count::Int
    listener::Base.RefValue{LibPipeWire.spa_hook}
    events::Base.RefValue{LibPipeWire.pw_registry_events}
    callback_state::RegistryState
end

function _copy_properties(pointer::Ptr{LibPipeWire.spa_dict})
    result = Dict{String,String}()
    pointer == C_NULL && return result
    dictionary = unsafe_load(pointer)
    for index in 1:Int(dictionary.n_items)
        item = unsafe_load(dictionary.items, index)
        item.key == C_NULL && continue
        result[unsafe_string(item.key)] = item.value == C_NULL ? "" : unsafe_string(item.value)
    end
    return result
end

function _registry_global_added(
    registry::Registry,
    id::UInt32,
    permissions::UInt32,
    type::Cstring,
    version::UInt32,
    properties::Ptr{LibPipeWire.spa_dict},
)::Cvoid
    state = registry.callback_state
    try
        global_object = Global(
            id,
            permissions,
            type == C_NULL ? "" : unsafe_string(type),
            version,
            _copy_properties(properties),
        )
        lock(state.lock) do
            state.active && (state.globals[id] = global_object)
        end
    catch error
        lock(state.lock) do
            state.error[] === nothing && (state.error[] = error)
        end
        _stop_after_callback(state.core_state, error)
    end
    return nothing
end

function _registry_global_removed(registry::Registry, id::UInt32)::Cvoid
    state = registry.callback_state
    try
        lock(state.lock) do
            state.active && delete!(state.globals, id)
        end
    catch error
        lock(state.lock) do
            state.error[] === nothing && (state.error[] = error)
        end
        _stop_after_callback(state.core_state, error)
    end
    return nothing
end

function _registry_events(::T) where {T<:Registry}
    global_added = @cfunction(
        _registry_global_added,
        Cvoid,
        (Ref{T}, UInt32, UInt32, Cstring, UInt32, Ptr{LibPipeWire.spa_dict}),
    )
    global_removed = @cfunction(
        _registry_global_removed,
        Cvoid,
        (Ref{T}, UInt32),
    )
    return LibPipeWire.pw_registry_events(
        UInt32(0),
        global_added,
        global_removed,
    )
end

function Registry(core::CoreConnection)
    core_handle = _retain_registry(core)
    handle = LibPipeWire.pw_core_get_registry(core_handle, UInt32(3), 0)
    if handle == C_NULL
        errno = Base.Libc.errno()
        _release_registry(core)
        throw(PipeWireError(:pw_core_get_registry, -errno))
    end

    state = RegistryState(
        ReentrantLock(),
        Dict{UInt32,Global}(),
        Ref{Any}(nothing),
        core.callback_state,
        true,
    )
    listener = Ref(_zero_hook())
    events = Ref{LibPipeWire.pw_registry_events}()
    registry = Registry(
        handle,
        core,
        ReentrantLock(),
        0,
        listener,
        events,
        state,
    )
    try
        events[] = _registry_events(registry)
    catch
        close(registry)
        rethrow()
    end
    result = GC.@preserve registry listener events begin
        LibPipeWire.pw_registry_add_listener(
            handle,
            Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener),
            Base.unsafe_convert(Ptr{LibPipeWire.pw_registry_events}, events),
            pointer_from_objref(registry),
        )
    end
    if result < 0
        close(registry)
        throw(PipeWireError(:pw_registry_add_listener, result))
    end

    finalizer(close, registry)
    return registry
end

function _require_open(registry::Registry)
    registry.handle == C_NULL &&
        throw(InvalidStateException("the PipeWire registry is closed", :closed))
    return registry.handle
end

function Base.isopen(registry::Registry)
    return lock(registry.state_lock) do
        registry.handle != C_NULL
    end
end

function Base.close(registry::Registry)
    handle = lock(registry.state_lock) do
        registry.handle == C_NULL && return C_NULL
        registry.proxy_count == 0 || throw(
            InvalidStateException(
                "cannot close a PipeWire registry while proxies are open",
                :open_proxies,
            ),
        )
        handle = registry.handle
        registry.handle = Ptr{LibPipeWire.pw_registry}(C_NULL)
        return handle
    end
    handle == C_NULL && return nothing

    lock(registry.callback_state.lock) do
        registry.callback_state.active = false
    end
    LibPipeWire.pw_proxy_destroy(Ptr{LibPipeWire.pw_proxy}(handle))
    _release_registry(registry.core)
    return nothing
end

function _retain_proxy(registry::Registry)
    return lock(registry.state_lock) do
        handle = _require_open(registry)
        registry.proxy_count += 1
        return handle
    end
end

function _release_proxy(registry::Registry)
    return lock(registry.state_lock) do
        registry.proxy_count -= 1
        @assert registry.proxy_count >= 0
        return nothing
    end
end

roundtrip(registry::Registry) = roundtrip(registry.core)

"""
    globals(registry::Registry) -> Vector{Global}

Return an ID-sorted snapshot of the global objects currently known to
`registry`. The returned globals and their property dictionaries are copies.
"""
function globals(registry::Registry)
    lock(registry.state_lock) do
        _require_open(registry)
    end
    state = registry.callback_state
    return lock(state.lock) do
        state.error[] === nothing || throw(state.error[])
        result = [
            Global(global_object.id, global_object.permissions, global_object.type,
                global_object.version, copy(global_object.properties))
            for global_object in values(state.globals)
        ]
        sort!(result; by=global_object -> global_object.id)
        return result
    end
end

_copy_global(global_object::Global) = Global(
    global_object.id,
    global_object.permissions,
    global_object.type,
    global_object.version,
    copy(global_object.properties),
)

"Return the copied global with `id`, or `nothing` when it is not present."
function find_global(registry::Registry, id::Integer)
    object_id = _core_uint32(id, "global ID")
    lock(registry.state_lock) do
        _require_open(registry)
    end
    state = registry.callback_state
    error, global_object = lock(state.lock) do
        (state.error[], get(state.globals, object_id, nothing))
    end
    error === nothing || throw(error)
    return global_object === nothing ? nothing : _copy_global(global_object)
end

"Return copied globals matching an interface type and required properties."
function find_globals(
    registry::Registry;
    interface::Union{Nothing,AbstractString}=nothing,
    properties=(),
)
    required = Dict{String,String}(String(key) => String(value) for (key, value) in properties)
    return filter(globals(registry)) do global_object
        (interface === nothing || global_object.type == interface) &&
            all(get(global_object.properties, key, nothing) == value for (key, value) in required)
    end
end

function Base.getindex(registry::Registry, id::Integer)
    global_object = find_global(registry, id)
    global_object === nothing && throw(KeyError(id))
    return global_object
end

"""
    with_registry(f; self=false, loop=nothing, context_properties=nothing,
                  core_properties=nothing, fd=nothing)

Create a context, core connection, and registry; call `f(registry)`; then close
all three objects in dependency order. Set `self=true` to use an internal core.
The registry passed to `f` is closed when this function returns.
"""
function with_registry(
    f;
    self::Bool=false,
    loop::Union{Nothing,AbstractPipeWireLoop}=nothing,
    context_properties=nothing,
    core_properties=nothing,
    fd::Union{Nothing,Integer}=nothing,
)
    context = loop === nothing ?
              Context(; properties=context_properties) :
              Context(loop; properties=context_properties)
    core = nothing
    registry = nothing
    try
        core = CoreConnection(context; self, fd, properties=core_properties)
        registry = Registry(core)
        return f(registry)
    finally
        registry === nothing || close(registry)
        core === nothing || close(core)
        close(context)
    end
end
