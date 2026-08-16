"""
    Proxy

An owning client-side PipeWire proxy. Create one with [`bind`](@ref) or
[`create_object`](@ref), and close it before closing its registry or core.
"""
mutable struct Proxy{Parent,Callbacks}
    handle::Ptr{LibPipeWire.pw_proxy}
    parent::Parent
    interface_type::String
    version::UInt32
    state_lock::ReentrantLock
    callback_lock::ReentrantLock
    listener::Base.RefValue{LibPipeWire.spa_hook}
    events::Base.RefValue{LibPipeWire.pw_proxy_events}
    callbacks::Callbacks
    callback_error::Base.RefValue{Any}
    global_id::UInt32
    removed::Bool
    callbacks_active::Bool
end


_proxy_core(proxy::Proxy{<:Registry}) = proxy.parent.core
_proxy_core(proxy::Proxy{<:CoreConnection}) = proxy.parent

function _invoke_proxy_callback(proxy::Proxy, ::Val{Field}, args...) where {Field}
    lock(proxy.callback_lock)
    if !proxy.callbacks_active
        unlock(proxy.callback_lock)
        return nothing
    end
    callback = getfield(proxy.callbacks, Field)
    unlock(proxy.callback_lock)
    callback === nothing && return nothing
    try
        callback(proxy, args...)
    catch error
        lock(proxy.callback_lock) do
            proxy.callback_error[] === nothing && (proxy.callback_error[] = error)
        end
        _stop_after_callback(_proxy_core(proxy).callback_state, error)
    end
    return nothing
end

function _proxy_destroyed(proxy::Proxy)::Cvoid
    lock(proxy.callback_lock) do
        proxy.callbacks_active = false
    end
    released = lock(proxy.state_lock) do
        proxy.handle == C_NULL && return false
        proxy.handle = Ptr{LibPipeWire.pw_proxy}(C_NULL)
        return true
    end
    released && _release_proxy(proxy.parent)
    return nothing
end

function _proxy_bound(proxy::Proxy, global_id::UInt32)::Cvoid
    lock(proxy.callback_lock) do
        proxy.global_id = global_id
    end
    _invoke_proxy_callback(proxy, Val(:on_bound), global_id)
    return nothing
end

function _proxy_removed(proxy::Proxy)::Cvoid
    lock(proxy.callback_lock) do
        proxy.removed = true
    end
    _invoke_proxy_callback(proxy, Val(:on_removed))
    return nothing
end

function _proxy_done(proxy::Proxy, sequence::Cint)::Cvoid
    _invoke_proxy_callback(proxy, Val(:on_done), sequence)
    return nothing
end

function _proxy_error(
    proxy::Proxy,
    sequence::Cint,
    result::Cint,
    message::Cstring,
)::Cvoid
    detail = message == C_NULL ? nothing : unsafe_string(message)
    error = PipeWireError(:pw_proxy, result, detail)
    lock(proxy.callback_lock) do
        proxy.callback_error[] === nothing && (proxy.callback_error[] = error)
    end
    _invoke_proxy_callback(proxy, Val(:on_error), sequence, error)
    return nothing
end

function _proxy_bound_properties(
    proxy::Proxy,
    global_id::UInt32,
    properties::Ptr{LibPipeWire.spa_dict},
)::Cvoid
    try
        _invoke_proxy_callback(
            proxy,
            Val(:on_bound_properties),
            global_id,
            _copy_properties(properties),
        )
    catch error
        lock(proxy.callback_lock) do
            proxy.callback_error[] === nothing && (proxy.callback_error[] = error)
        end
        _stop_after_callback(_proxy_core(proxy).callback_state, error)
    end
    return nothing
end

function _proxy_events(::T) where {T<:Proxy}
    destroyed = @cfunction(_proxy_destroyed, Cvoid, (Ref{T},))
    bound = @cfunction(_proxy_bound, Cvoid, (Ref{T}, UInt32))
    removed = @cfunction(_proxy_removed, Cvoid, (Ref{T},))
    done = @cfunction(_proxy_done, Cvoid, (Ref{T}, Cint))
    error = @cfunction(
        _proxy_error,
        Cvoid,
        (Ref{T}, Cint, Cint, Cstring),
    )
    bound_properties = @cfunction(
        _proxy_bound_properties,
        Cvoid,
        (Ref{T}, UInt32, Ptr{LibPipeWire.spa_dict}),
    )
    return LibPipeWire.pw_proxy_events(
        UInt32(1),
        destroyed,
        bound,
        removed,
        done,
        error,
        bound_properties,
    )
end

function _new_proxy(handle, parent, interface_name::String, version::UInt32, callbacks)
    listener = Ref(_zero_hook())
    events = Ref{LibPipeWire.pw_proxy_events}()
    proxy = Proxy(
        Ptr{LibPipeWire.pw_proxy}(handle),
        parent,
        interface_name,
        version,
        ReentrantLock(),
        ReentrantLock(),
        listener,
        events,
        callbacks,
        Ref{Any}(nothing),
        typemax(UInt32),
        false,
        true,
    )
    try
        events[] = _proxy_events(proxy)
    catch
        LibPipeWire.pw_proxy_destroy(proxy.handle)
        proxy.handle = Ptr{LibPipeWire.pw_proxy}(C_NULL)
        _release_proxy(parent)
        rethrow()
    end
    GC.@preserve proxy listener events begin
        LibPipeWire.pw_proxy_add_listener(
            proxy.handle,
            Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener),
            Base.unsafe_convert(Ptr{LibPipeWire.pw_proxy_events}, events),
            pointer_from_objref(proxy),
        )
    end
    finalizer(close, proxy)
    return proxy
end

"""
    bind(registry::Registry, global::Global; version=global.version, callbacks...) -> Proxy

Bind a registry global and return an owning client-side proxy. The callback
keywords are `on_bound`, `on_removed`, `on_done`, `on_error`, and
`on_bound_properties`; each callback receives the proxy as its first argument.
"""
function Base.bind(
    registry::Registry,
    global_object::Global;
    version::Integer=global_object.version,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    0 <= version <= global_object.version || throw(
        ArgumentError("the requested proxy version exceeds the announced global version"),
    )
    registry_handle = _retain_proxy(registry)
    interface_name = global_object.type
    handle = GC.@preserve interface_name LibPipeWire.pw_registry_bind(
        registry_handle,
        global_object.id,
        pointer(interface_name),
        UInt32(version),
        0,
    )
    if handle == C_NULL
        _release_proxy(registry)
        throw(PipeWireError(:pw_registry_bind, -Base.Libc.errno()))
    end

    callbacks = (
        on_bound=on_bound,
        on_removed=on_removed,
        on_done=on_done,
        on_error=on_error,
        on_bound_properties=on_bound_properties,
    )
    return _new_proxy(handle, registry, interface_name, UInt32(version), callbacks)
end

"""
    create_object(core, factory_name, interface_type;
                  version=3, properties=nothing, callbacks...) -> Proxy

Create a server-side object from a PipeWire factory and return its owning
client proxy. `properties` may be a [`Properties`](@ref) value or any iterable
of string pairs. Close the proxy before closing `core`.
"""
function create_object(
    core::CoreConnection,
    factory_name::AbstractString,
    interface_name::AbstractString;
    version::Integer=3,
    properties=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    0 <= version <= typemax(UInt32) || throw(
        ArgumentError("the requested interface version is outside UInt32 range"),
    )
    factory = _validate_c_string(String(factory_name), "factory name")
    interface = _validate_c_string(String(interface_name), "interface type")
    core_handle = _retain_proxy(core)
    handle = try
        _with_properties_dict(properties) do dictionary
            GC.@preserve factory interface LibPipeWire.pw_core_create_object(
                core_handle,
                pointer(factory),
                pointer(interface),
                UInt32(version),
                dictionary,
                0,
            )
        end
    catch
        _release_proxy(core)
        rethrow()
    end
    if handle == C_NULL
        _release_proxy(core)
        throw(PipeWireError(:pw_core_create_object, -Base.Libc.errno()))
    end

    callbacks = (
        on_bound=on_bound,
        on_removed=on_removed,
        on_done=on_done,
        on_error=on_error,
        on_bound_properties=on_bound_properties,
    )
    return _new_proxy(handle, core, interface, UInt32(version), callbacks)
end

"""
    destroy_object!(core, proxy)

Destroy a core-created object on the server, close its local proxy, and return
`core`. Call [`roundtrip`](@ref) afterward to observe any asynchronous server
error or registry removal event.
"""
function destroy_object!(core::CoreConnection, proxy::Proxy{<:CoreConnection})
    proxy.parent === core || throw(
        ArgumentError("the proxy belongs to a different PipeWire core"),
    )
    close(proxy)
    return core
end

function _require_open(proxy::Proxy)
    proxy.handle == C_NULL &&
        throw(InvalidStateException("the PipeWire proxy is closed", :closed))
    error = lock(proxy.callback_lock) do
        proxy.callback_error[]
    end
    error === nothing || throw(error)
    return proxy.handle
end

function Base.isopen(proxy::Proxy)
    return lock(proxy.state_lock) do
        proxy.handle != C_NULL
    end
end

function Base.close(proxy::Proxy)
    handle = lock(proxy.state_lock) do
        proxy.handle == C_NULL && return C_NULL
        handle = proxy.handle
        proxy.handle = Ptr{LibPipeWire.pw_proxy}(C_NULL)
        return handle
    end
    handle == C_NULL && return nothing
    lock(proxy.callback_lock) do
        proxy.callbacks_active = false
    end
    LibPipeWire.pw_proxy_destroy(handle)
    _release_proxy(proxy.parent)
    return nothing
end

"Return the PipeWire interface type name implemented by a proxy."
interface_type(proxy::Proxy) = proxy.interface_type

"Return the local proxy ID assigned by PipeWireAO."
function proxy_id(proxy::Proxy)
    return lock(proxy.state_lock) do
        LibPipeWire.pw_proxy_get_id(_require_open(proxy))
    end
end

"Return the server global ID to which a proxy was bound."
function bound_id(proxy::Proxy)
    return lock(proxy.callback_lock) do
        proxy.global_id
    end
end

roundtrip(proxy::Proxy) = roundtrip(_proxy_core(proxy))

"""Attempt to destroy a global object through a registry."""
function destroy_global!(registry::Registry, id::Integer)
    result = lock(registry.state_lock) do
        LibPipeWire.pw_registry_destroy(_require_open(registry), UInt32(id))
    end
    _check_result(:pw_registry_destroy, result)
    return registry
end
