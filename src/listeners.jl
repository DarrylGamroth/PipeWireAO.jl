"""
    ManagedListener

An independently owned native PipeWire event listener returned by
[`add_listener!`](@ref). Its owner and callback tuple are concrete type
parameters, so native dispatch specializes on the exact callback types.

Keep the listener alive for as long as callbacks are wanted and call
`close(listener)` to detach it. Add and remove listeners on the owning
PipeWire loop thread, or while holding the corresponding [`ThreadLoop`](@ref)
lock.
"""
mutable struct ManagedListener{Owner,Events,Callbacks}
    owner::Owner
    state_lock::ReentrantLock
    hook::Base.RefValue{LibPipeWire.spa_hook}
    events::Base.RefValue{Events}
    callbacks::Callbacks
    active::Bool
end

mutable struct _CurrentInfoState{Info}
    lock::ReentrantLock
    value::Base.RefValue{Info}
    available::Bool
end

struct _CurrentInfoCallback{Object,Info}
    state::_CurrentInfoState{Info}
end

"""
    InfoTracker

An opt-in maintained current-info snapshot for a managed [`Node`](@ref),
[`Port`](@ref), [`Device`](@ref), or [`Link`](@ref). Construct one with
[`track_info!`](@ref), test readiness with [`has_current_info`](@ref), read it
with [`current_info`](@ref), and close it to detach its independently owned
listener.
"""
struct InfoTracker{Info,Listener}
    state::_CurrentInfoState{Info}
    listener::Listener
end

function _new_listener(owner::Owner, ::Type{Events}, callbacks::Callbacks) where {Owner,Events,Callbacks}
    return ManagedListener(
        owner,
        ReentrantLock(),
        Ref(_zero_hook()),
        Ref{Events}(),
        callbacks,
        false,
    )
end

function _activate_listener!(listener::ManagedListener)
    lock(listener.state_lock) do
        listener.active = true
    end
    finalizer(close, listener)
    return listener
end

function _discard_listener!(listener::ManagedListener)
    lock(listener.state_lock) do
        listener.active = false
        listener.hook[] = _zero_hook()
    end
    return nothing
end

function _remove_spa_hook!(hook::Base.RefValue{LibPipeWire.spa_hook})
    pointer = Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, hook)
    native = unsafe_load(pointer)
    link = native.link
    link.prev == C_NULL && return nothing

    previous = unsafe_load(link.prev)
    unsafe_store!(link.prev, LibPipeWire.spa_list(link.next, previous.prev))
    # A singleton's previous and following links are the same list head.
    # Read after the first store so the second preserves the updated next.
    following = unsafe_load(link.next)
    unsafe_store!(link.next, LibPipeWire.spa_list(following.next, link.prev))
    native.removed == C_NULL || ccall(
        native.removed,
        Cvoid,
        (Ptr{LibPipeWire.spa_hook},),
        pointer,
    )
    hook[] = _zero_hook()
    return nothing
end

function Base.isopen(listener::ManagedListener)
    active = lock(listener.state_lock) do
        listener.active
    end
    return active && isopen(listener.owner)
end

function Base.close(listener::ManagedListener)
    remove = lock(listener.state_lock) do
        listener.active || return false
        listener.active = false
        return isopen(listener.owner)
    end
    if remove
        hook = listener.hook
        GC.@preserve listener hook _remove_spa_hook!(hook)
    else
        listener.hook[] = _zero_hook()
    end
    return nothing
end

function _record_listener_error(owner::CoreConnection, error)
    state = owner.callback_state
    lock(state.lock) do
        state.error[] === nothing && (state.error[] = error)
    end
    _stop_after_callback(state, error)
    return nothing
end

function _record_listener_error(owner::Registry, error)
    state = owner.callback_state
    lock(state.lock) do
        state.error[] === nothing && (state.error[] = error)
    end
    _stop_after_callback(state.core_state, error)
    return nothing
end

function _record_listener_error(owner::Proxy, error)
    lock(owner.callback_lock) do
        owner.callback_error[] === nothing && (owner.callback_error[] = error)
    end
    _stop_after_callback(_proxy_core(owner).callback_state, error)
    return nothing
end

@inline function _active_listener_callback(
    listener::ManagedListener{Owner,Events,Callbacks},
    ::Val{Field},
) where {Owner,Events,Callbacks,Field}
    lock(listener.state_lock)
    if !listener.active
        unlock(listener.state_lock)
        return nothing
    end
    callback = getfield(listener.callbacks, Field)
    unlock(listener.state_lock)
    return callback
end

function _invoke_listener(
    listener::ManagedListener{Owner,Events,Callbacks},
    field::Val{Field},
) where {Owner,Events,Callbacks,Field}
    callback = _active_listener_callback(listener, field)
    callback === nothing && return nothing
    try
        callback(listener.owner)
    catch error
        _record_listener_error(listener.owner, error)
    end
    return nothing
end

function _invoke_listener(
    listener::ManagedListener{Owner,Events,Callbacks},
    field::Val{Field},
    first::A,
) where {Owner,Events,Callbacks,Field,A}
    callback = _active_listener_callback(listener, field)
    callback === nothing && return nothing
    try
        callback(listener.owner, first)
    catch error
        _record_listener_error(listener.owner, error)
    end
    return nothing
end

function _invoke_listener(
    listener::ManagedListener{Owner,Events,Callbacks},
    field::Val{Field},
    first::A,
    second::B,
) where {Owner,Events,Callbacks,Field,A,B}
    callback = _active_listener_callback(listener, field)
    callback === nothing && return nothing
    try
        callback(listener.owner, first, second)
    catch error
        _record_listener_error(listener.owner, error)
    end
    return nothing
end

function _invoke_listener(
    listener::ManagedListener{Owner,Events,Callbacks},
    field::Val{Field},
    first::A,
    second::B,
    third::C,
) where {Owner,Events,Callbacks,Field,A,B,C}
    callback = _active_listener_callback(listener, field)
    callback === nothing && return nothing
    try
        callback(listener.owner, first, second, third)
    catch error
        _record_listener_error(listener.owner, error)
    end
    return nothing
end

function _invoke_listener(
    listener::ManagedListener{Owner,Events,Callbacks},
    field::Val{Field},
    first::A,
    second::B,
    third::C,
    fourth::D,
) where {Owner,Events,Callbacks,Field,A,B,C,D}
    callback = _active_listener_callback(listener, field)
    callback === nothing && return nothing
    try
        callback(listener.owner, first, second, third, fourth)
    catch error
        _record_listener_error(listener.owner, error)
    end
    return nothing
end

function _invoke_listener(
    listener::ManagedListener{Owner,Events,Callbacks},
    field::Val{Field},
    first::A,
    second::B,
    third::C,
    fourth::D,
    fifth::E,
) where {Owner,Events,Callbacks,Field,A,B,C,D,E}
    callback = _active_listener_callback(listener, field)
    callback === nothing && return nothing
    try
        callback(listener.owner, first, second, third, fourth, fifth)
    catch error
        _record_listener_error(listener.owner, error)
    end
    return nothing
end

function _listener_core_info(
    listener::ManagedListener{<:CoreConnection},
    info::Ptr{LibPipeWire.pw_core_info},
)::Cvoid
    try
        _invoke_listener(listener, Val(:on_info), _copy_core_info(info))
    catch error
        _record_listener_error(listener.owner, error)
    end
    return nothing
end

function _listener_core_done(
    listener::ManagedListener{<:CoreConnection},
    id::UInt32,
    sequence::Cint,
)::Cvoid
    _invoke_listener(listener, Val(:on_done), id, sequence)
    return nothing
end

function _listener_core_ping(
    listener::ManagedListener{<:CoreConnection},
    id::UInt32,
    sequence::Cint,
)::Cvoid
    _invoke_listener(listener, Val(:on_ping), id, sequence)
    return nothing
end

function _listener_core_error(
    listener::ManagedListener{<:CoreConnection},
    id::UInt32,
    sequence::Cint,
    result::Cint,
    message::Cstring,
)::Cvoid
    detail = message == C_NULL ? nothing : unsafe_string(message)
    _invoke_listener(listener, Val(:on_error), id, sequence, PipeWireError(:pw_core, result, detail))
    return nothing
end

function _listener_core_remove_id(
    listener::ManagedListener{<:CoreConnection},
    id::UInt32,
)::Cvoid
    _invoke_listener(listener, Val(:on_remove_id), id)
    return nothing
end

function _listener_core_bound_id(
    listener::ManagedListener{<:CoreConnection},
    id::UInt32,
    global_id::UInt32,
)::Cvoid
    _invoke_listener(listener, Val(:on_bound_id), id, global_id)
    return nothing
end

function _listener_core_add_memory(
    listener::ManagedListener{<:CoreConnection},
    id::UInt32,
    data_type::UInt32,
    fd::Cint,
    flags::UInt32,
)::Cvoid
    _invoke_listener(listener, Val(:on_add_memory), CoreMemory(id, data_type, fd, flags))
    return nothing
end

function _listener_core_remove_memory(
    listener::ManagedListener{<:CoreConnection},
    id::UInt32,
)::Cvoid
    _invoke_listener(listener, Val(:on_remove_memory), id)
    return nothing
end

function _listener_core_bound_properties(
    listener::ManagedListener{<:CoreConnection},
    id::UInt32,
    global_id::UInt32,
    properties::Ptr{LibPipeWire.spa_dict},
)::Cvoid
    try
        _invoke_listener(
            listener,
            Val(:on_bound_properties),
            id,
            global_id,
            _copy_properties(properties),
        )
    catch error
        _record_listener_error(listener.owner, error)
    end
    return nothing
end

function _listener_core_events(::T) where {T<:ManagedListener{<:CoreConnection}}
    return LibPipeWire.pw_core_events(
        UInt32(1),
        @cfunction(_listener_core_info, Cvoid, (Ref{T}, Ptr{LibPipeWire.pw_core_info})),
        @cfunction(_listener_core_done, Cvoid, (Ref{T}, UInt32, Cint)),
        @cfunction(_listener_core_ping, Cvoid, (Ref{T}, UInt32, Cint)),
        @cfunction(_listener_core_error, Cvoid, (Ref{T}, UInt32, Cint, Cint, Cstring)),
        @cfunction(_listener_core_remove_id, Cvoid, (Ref{T}, UInt32)),
        @cfunction(_listener_core_bound_id, Cvoid, (Ref{T}, UInt32, UInt32)),
        @cfunction(
            _listener_core_add_memory,
            Cvoid,
            (Ref{T}, UInt32, UInt32, Cint, UInt32),
        ),
        @cfunction(_listener_core_remove_memory, Cvoid, (Ref{T}, UInt32)),
        @cfunction(
            _listener_core_bound_properties,
            Cvoid,
            (Ref{T}, UInt32, UInt32, Ptr{LibPipeWire.spa_dict}),
        ),
    )
end

"""
    add_listener!(core::CoreConnection; callbacks...) -> ManagedListener

Attach an additional independently owned core-event listener. Callback
signatures and keyword names match [`CoreConnection`](@ref). Close the returned
listener to detach it without closing `core`.
"""
function add_listener!(
    core::CoreConnection;
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
    listener = _new_listener(core, LibPipeWire.pw_core_events, callbacks)
    listener.events[] = _listener_core_events(listener)
    handle = lock(core.state_lock) do
        _require_open(core)
    end
    hook = listener.hook
    events = listener.events
    result = GC.@preserve listener hook events LibPipeWire.pw_core_add_listener(
        handle,
        Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, hook),
        Base.unsafe_convert(Ptr{LibPipeWire.pw_core_events}, events),
        pointer_from_objref(listener),
    )
    if result < 0
        _discard_listener!(listener)
        throw(PipeWireError(:pw_core_add_listener, result))
    end
    return _activate_listener!(listener)
end

function _listener_registry_global(
    listener::ManagedListener{<:Registry},
    id::UInt32,
    permissions::UInt32,
    type::Cstring,
    version::UInt32,
    properties::Ptr{LibPipeWire.spa_dict},
)::Cvoid
    try
        global_object = Global(
            id,
            permissions,
            type == C_NULL ? "" : unsafe_string(type),
            version,
            _copy_properties(properties),
        )
        _invoke_listener(listener, Val(:on_global_added), global_object)
    catch error
        _record_listener_error(listener.owner, error)
    end
    return nothing
end

function _listener_registry_global_remove(
    listener::ManagedListener{<:Registry},
    id::UInt32,
)::Cvoid
    _invoke_listener(listener, Val(:on_global_removed), id)
    return nothing
end

function _listener_registry_events(::T) where {T<:ManagedListener{<:Registry}}
    return LibPipeWire.pw_registry_events(
        UInt32(0),
        @cfunction(
            _listener_registry_global,
            Cvoid,
            (Ref{T}, UInt32, UInt32, Cstring, UInt32, Ptr{LibPipeWire.spa_dict}),
        ),
        @cfunction(_listener_registry_global_remove, Cvoid, (Ref{T}, UInt32)),
    )
end

"""
    add_listener!(registry::Registry; on_global_added=nothing,
                  on_global_removed=nothing) -> ManagedListener

Attach an additional registry listener. Added globals are passed as owned
[`Global`](@ref) snapshots; removal callbacks receive the removed `UInt32` ID.
"""
function add_listener!(
    registry::Registry;
    on_global_added=nothing,
    on_global_removed=nothing,
)
    callbacks = (
        on_global_added=on_global_added,
        on_global_removed=on_global_removed,
    )
    listener = _new_listener(registry, LibPipeWire.pw_registry_events, callbacks)
    listener.events[] = _listener_registry_events(listener)
    handle = lock(registry.state_lock) do
        _require_open(registry)
    end
    hook = listener.hook
    events = listener.events
    result = GC.@preserve listener hook events LibPipeWire.pw_registry_add_listener(
        handle,
        Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, hook),
        Base.unsafe_convert(Ptr{LibPipeWire.pw_registry_events}, events),
        pointer_from_objref(listener),
    )
    if result < 0
        _discard_listener!(listener)
        throw(PipeWireError(:pw_registry_add_listener, result))
    end
    return _activate_listener!(listener)
end


function _listener_proxy_destroyed(listener::ManagedListener{<:Proxy})::Cvoid
    _invoke_listener(listener, Val(:on_destroyed))
    lock(listener.state_lock) do
        listener.active = false
    end
    return nothing
end


function _listener_proxy_bound(
    listener::ManagedListener{<:Proxy},
    global_id::UInt32,
)::Cvoid
    _invoke_listener(listener, Val(:on_bound), global_id)
    return nothing
end


function _listener_proxy_removed(listener::ManagedListener{<:Proxy})::Cvoid
    _invoke_listener(listener, Val(:on_removed))
    return nothing
end


function _listener_proxy_done(
    listener::ManagedListener{<:Proxy},
    sequence::Cint,
)::Cvoid
    _invoke_listener(listener, Val(:on_done), sequence)
    return nothing
end


function _listener_proxy_error(
    listener::ManagedListener{<:Proxy},
    sequence::Cint,
    result::Cint,
    message::Cstring,
)::Cvoid
    detail = message == C_NULL ? nothing : unsafe_string(message)
    _invoke_listener(listener, Val(:on_error), sequence, PipeWireError(:pw_proxy, result, detail))
    return nothing
end


function _listener_proxy_bound_properties(
    listener::ManagedListener{<:Proxy},
    global_id::UInt32,
    properties::Ptr{LibPipeWire.spa_dict},
)::Cvoid
    try
        _invoke_listener(
            listener,
            Val(:on_bound_properties),
            global_id,
            _copy_properties(properties),
        )
    catch error
        _record_listener_error(listener.owner, error)
    end
    return nothing
end


function _listener_proxy_events(::T) where {T<:ManagedListener{<:Proxy}}
    return LibPipeWire.pw_proxy_events(
        UInt32(0),
        @cfunction(_listener_proxy_destroyed, Cvoid, (Ref{T},)),
        @cfunction(_listener_proxy_bound, Cvoid, (Ref{T}, UInt32)),
        @cfunction(_listener_proxy_removed, Cvoid, (Ref{T},)),
        @cfunction(_listener_proxy_done, Cvoid, (Ref{T}, Cint)),
        @cfunction(_listener_proxy_error, Cvoid, (Ref{T}, Cint, Cint, Cstring)),
        @cfunction(
            _listener_proxy_bound_properties,
            Cvoid,
            (Ref{T}, UInt32, Ptr{LibPipeWire.spa_dict}),
        ),
    )
end


"""
    add_listener!(proxy::Proxy; callbacks...) -> ManagedListener

Attach an additional proxy listener. Supported callbacks are `on_destroyed`,
`on_bound`, `on_removed`, `on_done`, `on_error`, and `on_bound_properties`.
Close the returned listener to detach it.
"""
function add_listener!(
    proxy::Proxy;
    on_destroyed=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    callbacks = (
        on_destroyed=on_destroyed,
        on_bound=on_bound,
        on_removed=on_removed,
        on_done=on_done,
        on_error=on_error,
        on_bound_properties=on_bound_properties,
    )
    listener = _new_listener(proxy, LibPipeWire.pw_proxy_events, callbacks)
    listener.events[] = _listener_proxy_events(listener)
    handle = lock(proxy.state_lock) do
        _require_open(proxy)
    end
    lock(listener.state_lock) do
        listener.active = true
    end
    hook = listener.hook
    events = listener.events
    GC.@preserve listener hook events LibPipeWire.pw_proxy_add_listener(
        handle,
        Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, hook),
        Base.unsafe_convert(Ptr{LibPipeWire.pw_proxy_events}, events),
        pointer_from_objref(listener),
    )
    finalizer(close, listener)
    return listener
end


_record_listener_error(owner::ManagedObject, error) =
    _record_object_callback_error(owner, error)


function _register_result_listener!(
    listener::ManagedListener{Owner,Events},
    handle,
    add_listener,
    operation::Symbol,
) where {Owner,Events}
    hook = listener.hook
    events = listener.events
    result = GC.@preserve listener hook events add_listener(
        handle,
        Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, hook),
        Base.unsafe_convert(Ptr{Events}, events),
        pointer_from_objref(listener),
    )
    if result < 0
        _discard_listener!(listener)
        throw(PipeWireError(operation, result))
    end
    return _activate_listener!(listener)
end


function _listener_object_param(
    listener::ManagedListener{<:Union{Node,Port,Device}},
    sequence::Cint,
    id::UInt32,
    index::UInt32,
    next::UInt32,
    param::Ptr{LibPipeWire.spa_pod},
)::Cvoid
    try
        _invoke_listener(
            listener,
            Val(:on_param),
            sequence,
            id,
            index,
            next,
            _copy_pod(param),
        )
    catch error
        _record_listener_error(listener.owner, error)
    end
    return nothing
end


for (name, native_info, copy_info) in (
    (:Node, :(LibPipeWire.pw_node_info), :_copy_node_info),
    (:Port, :(LibPipeWire.pw_port_info), :_copy_port_info),
    (:Device, :(LibPipeWire.pw_device_info), :_copy_device_info),
    (:Link, :(LibPipeWire.pw_link_info), :_copy_link_info),
    (:Factory, :(LibPipeWire.pw_factory_info), :_copy_factory_info),
    (:PipeWireModule, :(LibPipeWire.pw_module_info), :_copy_module_info),
    (:Client, :(LibPipeWire.pw_client_info), :_copy_client_info),
)
    callback_name = Symbol(:_listener_, lowercase(String(name)), :_info)
    @eval function $callback_name(
        listener::ManagedListener{<:$name},
        info::Ptr{$native_info},
    )::Cvoid
        try
            _invoke_listener(listener, Val(:on_info), $copy_info(info))
        catch error
            _record_listener_error(listener.owner, error)
        end
        return nothing
    end
end


function _listener_client_permissions(
    listener::ManagedListener{<:Client},
    index::UInt32,
    count::UInt32,
    permissions::Ptr{LibPipeWire.pw_permission},
)::Cvoid
    try
        _invoke_listener(
            listener,
            Val(:on_permissions),
            index,
            _copy_permissions(permissions, count),
        )
    catch error
        _record_listener_error(listener.owner, error)
    end
    return nothing
end


function _listener_metadata_property(
    listener::ManagedListener{<:Metadata},
    subject::UInt32,
    key::Cstring,
    type::Cstring,
    value::Cstring,
)::Cint
    _invoke_listener(
        listener,
        Val(:on_property),
        subject,
        key == C_NULL ? nothing : unsafe_string(key),
        type == C_NULL ? nothing : unsafe_string(type),
        value == C_NULL ? nothing : unsafe_string(value),
    )
    return Cint(0)
end


function _listener_profiler_profile(
    listener::ManagedListener{<:Profiler},
    pod::Ptr{LibPipeWire.spa_pod},
)::Cvoid
    try
        _invoke_listener(listener, Val(:on_profile), _copy_pod(pod))
    catch error
        _record_listener_error(listener.owner, error)
    end
    return nothing
end


function _listener_node_events(::T) where {T<:ManagedListener{<:Node}}
    return LibPipeWire.pw_node_events(
        UInt32(0),
        @cfunction(_listener_node_info, Cvoid, (Ref{T}, Ptr{LibPipeWire.pw_node_info})),
        @cfunction(
            _listener_object_param,
            Cvoid,
            (Ref{T}, Cint, UInt32, UInt32, UInt32, Ptr{LibPipeWire.spa_pod}),
        ),
    )
end


function _listener_port_events(::T) where {T<:ManagedListener{<:Port}}
    return LibPipeWire.pw_port_events(
        UInt32(0),
        @cfunction(_listener_port_info, Cvoid, (Ref{T}, Ptr{LibPipeWire.pw_port_info})),
        @cfunction(
            _listener_object_param,
            Cvoid,
            (Ref{T}, Cint, UInt32, UInt32, UInt32, Ptr{LibPipeWire.spa_pod}),
        ),
    )
end


function _listener_device_events(::T) where {T<:ManagedListener{<:Device}}
    return LibPipeWire.pw_device_events(
        UInt32(0),
        @cfunction(
            _listener_device_info,
            Cvoid,
            (Ref{T}, Ptr{LibPipeWire.pw_device_info}),
        ),
        @cfunction(
            _listener_object_param,
            Cvoid,
            (Ref{T}, Cint, UInt32, UInt32, UInt32, Ptr{LibPipeWire.spa_pod}),
        ),
    )
end


function _listener_link_events(::T) where {T<:ManagedListener{<:Link}}
    return LibPipeWire.pw_link_events(
        UInt32(0),
        @cfunction(_listener_link_info, Cvoid, (Ref{T}, Ptr{LibPipeWire.pw_link_info})),
    )
end


function _listener_factory_events(::T) where {T<:ManagedListener{<:Factory}}
    return LibPipeWire.pw_factory_events(
        UInt32(0),
        @cfunction(
            _listener_factory_info,
            Cvoid,
            (Ref{T}, Ptr{LibPipeWire.pw_factory_info}),
        ),
    )
end


function _listener_module_events(::T) where {T<:ManagedListener{<:PipeWireModule}}
    return LibPipeWire.pw_module_events(
        UInt32(0),
        @cfunction(
            _listener_pipewiremodule_info,
            Cvoid,
            (Ref{T}, Ptr{LibPipeWire.pw_module_info}),
        ),
    )
end


function _listener_client_events(::T) where {T<:ManagedListener{<:Client}}
    return LibPipeWire.pw_client_events(
        UInt32(0),
        @cfunction(
            _listener_client_info,
            Cvoid,
            (Ref{T}, Ptr{LibPipeWire.pw_client_info}),
        ),
        @cfunction(
            _listener_client_permissions,
            Cvoid,
            (Ref{T}, UInt32, UInt32, Ptr{LibPipeWire.pw_permission}),
        ),
    )
end


function _listener_metadata_events(::T) where {T<:ManagedListener{<:Metadata}}
    return LibPipeWire.pw_metadata_events(
        UInt32(0),
        @cfunction(
            _listener_metadata_property,
            Cint,
            (Ref{T}, UInt32, Cstring, Cstring, Cstring),
        ),
    )
end


function _listener_profiler_events(::T) where {T<:ManagedListener{<:Profiler}}
    return LibPipeWire.pw_profiler_events(
        UInt32(0),
        @cfunction(
            _listener_profiler_profile,
            Cvoid,
            (Ref{T}, Ptr{LibPipeWire.spa_pod}),
        ),
    )
end


"""
    add_listener!(object::ManagedObject; callbacks...) -> ManagedListener

Attach an additional independently owned listener to a typed PipeWire object.
Callback keywords match those accepted when binding that object: `on_info` and
`on_param` for nodes, ports, and devices; `on_info` for links, factories, and
modules; `on_info` and `on_permissions` for clients; `on_property` for
metadata; and `on_profile` for profilers.
"""
function add_listener!(object::Node; on_info=nothing, on_param=nothing)
    listener = _new_listener(
        object,
        LibPipeWire.pw_node_events,
        (on_info=on_info, on_param=on_param),
    )
    listener.events[] = _listener_node_events(listener)
    handle = _with_object_handle(identity, object, LibPipeWire.pw_node)
    return _register_result_listener!(
        listener,
        handle,
        LibPipeWire.pw_node_add_listener,
        :pw_node_add_listener,
    )
end


function add_listener!(object::Port; on_info=nothing, on_param=nothing)
    listener = _new_listener(
        object,
        LibPipeWire.pw_port_events,
        (on_info=on_info, on_param=on_param),
    )
    listener.events[] = _listener_port_events(listener)
    handle = _with_object_handle(identity, object, LibPipeWire.pw_port)
    return _register_result_listener!(
        listener,
        handle,
        LibPipeWire.pw_port_add_listener,
        :pw_port_add_listener,
    )
end


function add_listener!(object::Device; on_info=nothing, on_param=nothing)
    listener = _new_listener(
        object,
        LibPipeWire.pw_device_events,
        (on_info=on_info, on_param=on_param),
    )
    listener.events[] = _listener_device_events(listener)
    handle = _with_object_handle(identity, object, LibPipeWire.pw_device)
    return _register_result_listener!(
        listener,
        handle,
        LibPipeWire.pw_device_add_listener,
        :pw_device_add_listener,
    )
end


for (name, event_type, events_function, native_type, add_function, operation) in (
    (
        :Link,
        :(LibPipeWire.pw_link_events),
        :_listener_link_events,
        :(LibPipeWire.pw_link),
        :(LibPipeWire.pw_link_add_listener),
        :pw_link_add_listener,
    ),
    (
        :Factory,
        :(LibPipeWire.pw_factory_events),
        :_listener_factory_events,
        :(LibPipeWire.pw_factory),
        :(LibPipeWire.pw_factory_add_listener),
        :pw_factory_add_listener,
    ),
    (
        :PipeWireModule,
        :(LibPipeWire.pw_module_events),
        :_listener_module_events,
        :(LibPipeWire.pw_module),
        :(LibPipeWire.pw_module_add_listener),
        :pw_module_add_listener,
    ),
)
    @eval function add_listener!(object::$name; on_info=nothing)
        listener = _new_listener(object, $event_type, (on_info=on_info,))
        listener.events[] = $events_function(listener)
        handle = _with_object_handle(identity, object, $native_type)
        return _register_result_listener!(
            listener,
            handle,
            $add_function,
            $(QuoteNode(operation)),
        )
    end
end


function (callback::_CurrentInfoCallback{Object,Info})(
    ::Object,
    update::Info,
) where {Object,Info}
    state = callback.state
    lock(state.lock)
    try
        if state.available
            state.value[] = _merge_info(state.value[], update)
        else
            state.value[] = _merge_info(nothing, update)
        end
        state.available = true
    finally
        unlock(state.lock)
    end
    return nothing
end


function _track_info!(object::Object, ::Type{Info}) where {Object,Info}
    state = _CurrentInfoState{Info}(ReentrantLock(), Ref{Info}(), false)
    listener = add_listener!(object; on_info=_CurrentInfoCallback{Object,Info}(state))
    return InfoTracker(state, listener)
end


"""
    track_info!(object) -> InfoTracker

Attach an independent listener that maintains current copied object info for a
managed `Node`, `Port`, `Device`, or `Link`. Raw `on_info` callbacks are
unchanged and continue to receive protocol deltas.

The tracker merges fields according to each event's PipeWire change mask.
Its accumulated `change_mask` records all fields observed so far. Keep the
tracker alive while updates are wanted and call `close(tracker)` to detach it.
"""
track_info!(object::Node) = _track_info!(object, NodeInfo)
track_info!(object::Port) = _track_info!(object, PortInfo)
track_info!(object::Device) = _track_info!(object, DeviceInfo)
track_info!(object::Link) = _track_info!(object, LinkInfo)


"""
    has_current_info(tracker::InfoTracker) -> Bool

Return whether the tracker has received its first info event.
"""
function has_current_info(tracker::InfoTracker)
    state = tracker.state
    lock(state.lock)
    try
        return state.available
    finally
        unlock(state.lock)
    end
end


"""
    current_info(tracker::InfoTracker) -> Info

Return the most recently known complete copied info. Throw an
`InvalidStateException` if no info event has arrived; use
[`has_current_info`](@ref) to test readiness. The returned value remains valid
after later events because the tracker replaces rather than mutates its stored
dictionaries, parameter vectors, and format PODs. Treat those owned containers
as read-only.
"""
function current_info(tracker::InfoTracker{Info})::Info where {Info}
    state = tracker.state
    lock(state.lock)
    try
        state.available || throw(
            InvalidStateException(
                "the PipeWire info tracker has not received an info event",
                :unavailable,
            ),
        )
        return state.value[]
    finally
        unlock(state.lock)
    end
end


Base.isopen(tracker::InfoTracker) = isopen(tracker.listener)

function Base.close(tracker::InfoTracker)
    close(tracker.listener)
    return nothing
end


function add_listener!(object::Client; on_info=nothing, on_permissions=nothing)
    listener = _new_listener(
        object,
        LibPipeWire.pw_client_events,
        (on_info=on_info, on_permissions=on_permissions),
    )
    listener.events[] = _listener_client_events(listener)
    handle = _with_object_handle(identity, object, LibPipeWire.pw_client)
    return _register_result_listener!(
        listener,
        handle,
        LibPipeWire.pw_client_add_listener,
        :pw_client_add_listener,
    )
end


function add_listener!(object::Metadata; on_property=nothing)
    listener = _new_listener(
        object,
        LibPipeWire.pw_metadata_events,
        (on_property=on_property,),
    )
    listener.events[] = _listener_metadata_events(listener)
    hook = listener.hook
    events = listener.events
    result = _with_metadata_method(object, :add_listener) do data, method
        GC.@preserve listener hook events @ccall $method(
            data::Ptr{Cvoid},
            Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, hook)::Ptr{LibPipeWire.spa_hook},
            Base.unsafe_convert(Ptr{LibPipeWire.pw_metadata_events}, events)::Ptr{LibPipeWire.pw_metadata_events},
            pointer_from_objref(listener)::Ptr{Cvoid},
        )::Cint
    end
    if result < 0
        _discard_listener!(listener)
        throw(PipeWireError(:pw_metadata_add_listener, result))
    end
    return _activate_listener!(listener)
end


function add_listener!(object::Profiler; on_profile=nothing)
    listener = _new_listener(
        object,
        LibPipeWire.pw_profiler_events,
        (on_profile=on_profile,),
    )
    listener.events[] = _listener_profiler_events(listener)
    hook = listener.hook
    events = listener.events
    result = _with_profiler_method(object, :add_listener) do data, method
        GC.@preserve listener hook events @ccall $method(
            data::Ptr{Cvoid},
            Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, hook)::Ptr{LibPipeWire.spa_hook},
            Base.unsafe_convert(Ptr{LibPipeWire.pw_profiler_events}, events)::Ptr{LibPipeWire.pw_profiler_events},
            pointer_from_objref(listener)::Ptr{Cvoid},
        )::Cint
    end
    if result < 0
        _discard_listener!(listener)
        throw(PipeWireError(:pw_profiler_add_listener, result))
    end
    return _activate_listener!(listener)
end


function _record_listener_error(owner::Stream, error)
    lock(owner.callback_lock) do
        owner.callback_error[] === nothing && (owner.callback_error[] = error)
    end
    _stop_after_callback(owner.core.callback_state, error)
    return nothing
end


function _listener_stream_destroy(listener::ManagedListener{<:Stream})::Cvoid
    _invoke_listener(listener, Val(:on_destroyed))
    lock(listener.state_lock) do
        listener.active = false
    end
    return nothing
end


function _listener_stream_state_changed(
    listener::ManagedListener{<:Stream},
    old::Int32,
    current::Int32,
    message::Cstring,
)::Cvoid
    detail = message == C_NULL ? nothing : unsafe_string(message)
    _invoke_listener(listener, Val(:on_state_changed), old, current, detail)
    return nothing
end


function _listener_stream_control_info(
    listener::ManagedListener{<:Stream},
    id::UInt32,
    control::Ptr{LibPipeWire.pw_stream_control},
)::Cvoid
    try
        _invoke_listener(listener, Val(:on_control_info), id, _copy_stream_control(control))
    catch error
        _record_listener_error(listener.owner, error)
    end
    return nothing
end


function _listener_stream_io_changed(
    listener::ManagedListener{<:Stream},
    id::UInt32,
    area::Ptr{Cvoid},
    size::UInt32,
)::Cvoid
    _invoke_listener(listener, Val(:on_io_changed), StreamIO(id, area, size))
    return nothing
end


function _listener_stream_param_changed(
    listener::ManagedListener{<:Stream},
    id::UInt32,
    param::Ptr{LibPipeWire.spa_pod},
)::Cvoid
    try
        _invoke_listener(listener, Val(:on_param_changed), id, _copy_pod(param))
    catch error
        _record_listener_error(listener.owner, error)
    end
    return nothing
end


function _listener_stream_buffer_added(
    listener::ManagedListener{<:Stream},
    buffer::Ptr{LibPipeWire.pw_buffer},
)::Cvoid
    _invoke_listener(listener, Val(:on_buffer_added), buffer)
    return nothing
end


function _listener_stream_buffer_removed(
    listener::ManagedListener{<:Stream},
    buffer::Ptr{LibPipeWire.pw_buffer},
)::Cvoid
    _invoke_listener(listener, Val(:on_buffer_removed), buffer)
    return nothing
end


function _listener_stream_process(listener::ManagedListener{<:Stream})::Cvoid
    _invoke_listener(listener, Val(:on_process))
    return nothing
end


function _listener_stream_drained(listener::ManagedListener{<:Stream})::Cvoid
    _invoke_listener(listener, Val(:on_drained))
    return nothing
end


function _listener_stream_command(
    listener::ManagedListener{<:Stream},
    command::Ptr{LibPipeWire.spa_command},
)::Cvoid
    try
        _invoke_listener(
            listener,
            Val(:on_command),
            _copy_pod(Ptr{LibPipeWire.spa_pod}(command)),
        )
    catch error
        _record_listener_error(listener.owner, error)
    end
    return nothing
end


function _listener_stream_trigger_done(listener::ManagedListener{<:Stream})::Cvoid
    _invoke_listener(listener, Val(:on_trigger_done))
    return nothing
end


function _listener_stream_events(::T) where {T<:ManagedListener{<:Stream}}
    return LibPipeWire.pw_stream_events(
        UInt32(2),
        @cfunction(_listener_stream_destroy, Cvoid, (Ref{T},)),
        @cfunction(
            _listener_stream_state_changed,
            Cvoid,
            (Ref{T}, Int32, Int32, Cstring),
        ),
        @cfunction(
            _listener_stream_control_info,
            Cvoid,
            (Ref{T}, UInt32, Ptr{LibPipeWire.pw_stream_control}),
        ),
        @cfunction(
            _listener_stream_io_changed,
            Cvoid,
            (Ref{T}, UInt32, Ptr{Cvoid}, UInt32),
        ),
        @cfunction(
            _listener_stream_param_changed,
            Cvoid,
            (Ref{T}, UInt32, Ptr{LibPipeWire.spa_pod}),
        ),
        @cfunction(
            _listener_stream_buffer_added,
            Cvoid,
            (Ref{T}, Ptr{LibPipeWire.pw_buffer}),
        ),
        @cfunction(
            _listener_stream_buffer_removed,
            Cvoid,
            (Ref{T}, Ptr{LibPipeWire.pw_buffer}),
        ),
        @cfunction(_listener_stream_process, Cvoid, (Ref{T},)),
        @cfunction(_listener_stream_drained, Cvoid, (Ref{T},)),
        @cfunction(
            _listener_stream_command,
            Cvoid,
            (Ref{T}, Ptr{LibPipeWire.spa_command}),
        ),
        @cfunction(_listener_stream_trigger_done, Cvoid, (Ref{T},)),
    )
end


"""
    add_listener!(stream::Stream; callbacks...) -> ManagedListener

Attach an additional stream listener. Callback keywords match [`Stream`](@ref)
and additionally include `on_destroyed`. The listener's warmed `on_process`
dispatch has the same zero-allocation contract as the stream's primary process
callback when the callable itself does not allocate.
"""
function add_listener!(
    stream::Stream;
    on_destroyed=nothing,
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
    callbacks = (
        on_destroyed=on_destroyed,
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
    listener = _new_listener(stream, LibPipeWire.pw_stream_events, callbacks)
    listener.events[] = _listener_stream_events(listener)
    handle = lock(stream.state_lock) do
        _require_open(stream)
    end
    lock(listener.state_lock) do
        listener.active = true
    end
    hook = listener.hook
    events = listener.events
    try
        GC.@preserve listener hook events LibPipeWire.pw_stream_add_listener(
            handle,
            Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, hook),
            Base.unsafe_convert(Ptr{LibPipeWire.pw_stream_events}, events),
            pointer_from_objref(listener),
        )
    catch
        _discard_listener!(listener)
        rethrow()
    end
    finalizer(close, listener)
    return listener
end


function _record_listener_error(owner::Filter, error)
    _record_filter_callback_error(owner, error)
    return nothing
end


function _listener_filter_destroy(listener::ManagedListener{<:Filter})::Cvoid
    _invoke_listener(listener, Val(:on_destroyed))
    lock(listener.state_lock) do
        listener.active = false
    end
    return nothing
end


function _listener_filter_state_changed(
    listener::ManagedListener{<:Filter},
    old::Int32,
    current::Int32,
    message::Cstring,
)::Cvoid
    detail = message == C_NULL ? nothing : unsafe_string(message)
    _invoke_listener(listener, Val(:on_state_changed), old, current, detail)
    return nothing
end


function _listener_filter_io_changed(
    listener::ManagedListener{<:Filter},
    port_data::Ptr{Cvoid},
    id::UInt32,
    area::Ptr{Cvoid},
    size::UInt32,
)::Cvoid
    owner = listener.owner
    _invoke_listener(
        listener,
        Val(:on_io_changed),
        _filter_port(owner, port_data),
        FilterIO(id, area, size),
    )
    return nothing
end


function _listener_filter_param_changed(
    listener::ManagedListener{<:Filter},
    port_data::Ptr{Cvoid},
    id::UInt32,
    param::Ptr{LibPipeWire.spa_pod},
)::Cvoid
    try
        owner = listener.owner
        _invoke_listener(
            listener,
            Val(:on_param_changed),
            _filter_port(owner, port_data),
            id,
            _copy_pod(param),
        )
    catch error
        _record_listener_error(listener.owner, error)
    end
    return nothing
end


function _listener_filter_buffer_added(
    listener::ManagedListener{<:Filter},
    port_data::Ptr{Cvoid},
    buffer::Ptr{LibPipeWire.pw_buffer},
)::Cvoid
    owner = listener.owner
    _invoke_listener(
        listener,
        Val(:on_buffer_added),
        _filter_port(owner, port_data),
        buffer,
    )
    return nothing
end


function _listener_filter_buffer_removed(
    listener::ManagedListener{<:Filter},
    port_data::Ptr{Cvoid},
    buffer::Ptr{LibPipeWire.pw_buffer},
)::Cvoid
    owner = listener.owner
    _invoke_listener(
        listener,
        Val(:on_buffer_removed),
        _filter_port(owner, port_data),
        buffer,
    )
    return nothing
end


function _listener_filter_process(
    listener::ManagedListener{<:Filter},
    position::Ptr{LibPipeWire.spa_io_position},
)::Cvoid
    view = position == C_NULL ? nothing : FilterPosition(position)
    _invoke_listener(listener, Val(:on_process), view)
    return nothing
end


function _listener_filter_drained(listener::ManagedListener{<:Filter})::Cvoid
    _invoke_listener(listener, Val(:on_drained))
    return nothing
end


function _listener_filter_command(
    listener::ManagedListener{<:Filter},
    command::Ptr{LibPipeWire.spa_command},
)::Cvoid
    try
        _invoke_listener(
            listener,
            Val(:on_command),
            _copy_pod(Ptr{LibPipeWire.spa_pod}(command)),
        )
    catch error
        _record_listener_error(listener.owner, error)
    end
    return nothing
end


function _listener_filter_events(::T) where {T<:ManagedListener{<:Filter}}
    return LibPipeWire.pw_filter_events(
        UInt32(1),
        @cfunction(_listener_filter_destroy, Cvoid, (Ref{T},)),
        @cfunction(
            _listener_filter_state_changed,
            Cvoid,
            (Ref{T}, Int32, Int32, Cstring),
        ),
        @cfunction(
            _listener_filter_io_changed,
            Cvoid,
            (Ref{T}, Ptr{Cvoid}, UInt32, Ptr{Cvoid}, UInt32),
        ),
        @cfunction(
            _listener_filter_param_changed,
            Cvoid,
            (Ref{T}, Ptr{Cvoid}, UInt32, Ptr{LibPipeWire.spa_pod}),
        ),
        @cfunction(
            _listener_filter_buffer_added,
            Cvoid,
            (Ref{T}, Ptr{Cvoid}, Ptr{LibPipeWire.pw_buffer}),
        ),
        @cfunction(
            _listener_filter_buffer_removed,
            Cvoid,
            (Ref{T}, Ptr{Cvoid}, Ptr{LibPipeWire.pw_buffer}),
        ),
        @cfunction(
            _listener_filter_process,
            Cvoid,
            (Ref{T}, Ptr{LibPipeWire.spa_io_position}),
        ),
        @cfunction(_listener_filter_drained, Cvoid, (Ref{T},)),
        @cfunction(
            _listener_filter_command,
            Cvoid,
            (Ref{T}, Ptr{LibPipeWire.spa_command}),
        ),
    )
end


"""
    add_listener!(filter::Filter; callbacks...) -> ManagedListener

Attach an additional filter listener. Callback keywords match [`Filter`](@ref)
and additionally include `on_destroyed`. The listener's warmed `on_process`
dispatch has the same zero-allocation contract as the filter's primary process
callback when the callable itself does not allocate.
"""
function add_listener!(
    filter::Filter;
    on_destroyed=nothing,
    on_state_changed=nothing,
    on_io_changed=nothing,
    on_param_changed=nothing,
    on_buffer_added=nothing,
    on_buffer_removed=nothing,
    on_process=nothing,
    on_drained=nothing,
    on_command=nothing,
)
    callbacks = (
        on_destroyed=on_destroyed,
        on_state_changed=on_state_changed,
        on_io_changed=on_io_changed,
        on_param_changed=on_param_changed,
        on_buffer_added=on_buffer_added,
        on_buffer_removed=on_buffer_removed,
        on_process=on_process,
        on_drained=on_drained,
        on_command=on_command,
    )
    listener = _new_listener(filter, LibPipeWire.pw_filter_events, callbacks)
    listener.events[] = _listener_filter_events(listener)
    handle = lock(filter.state_lock) do
        _require_open(filter)
    end
    lock(listener.state_lock) do
        listener.active = true
    end
    hook = listener.hook
    events = listener.events
    try
        GC.@preserve listener hook events LibPipeWire.pw_filter_add_listener(
            handle,
            Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, hook),
            Base.unsafe_convert(Ptr{LibPipeWire.pw_filter_events}, events),
            pointer_from_objref(listener),
        )
    catch
        _discard_listener!(listener)
        rethrow()
    end
    finalizer(close, listener)
    return listener
end
