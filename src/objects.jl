const _NODE_INTERFACE = "PipeWire:Interface:Node"
const _PORT_INTERFACE = "PipeWire:Interface:Port"
const _DEVICE_INTERFACE = "PipeWire:Interface:Device"
const _LINK_INTERFACE = "PipeWire:Interface:Link"
const _METADATA_INTERFACE = "PipeWire:Interface:Metadata"
const _FACTORY_INTERFACE = "PipeWire:Interface:Factory"
const _MODULE_INTERFACE = "PipeWire:Interface:Module"
const _CLIENT_INTERFACE = "PipeWire:Interface:Client"
const _PROFILER_INTERFACE = "PipeWire:Interface:Profiler"
const _OBJECT_INTERFACE_VERSION = UInt32(3)

"The input or output direction of a PipeWire port."
@enum Direction::UInt32 begin
    DIRECTION_INPUT = LibPipeWire.SPA_DIRECTION_INPUT
    DIRECTION_OUTPUT = LibPipeWire.SPA_DIRECTION_OUTPUT
end

"The current state reported for a PipeWire node."
@enum NodeState::Int32 begin
    NODE_STATE_ERROR = LibPipeWire.PW_NODE_STATE_ERROR
    NODE_STATE_CREATING = LibPipeWire.PW_NODE_STATE_CREATING
    NODE_STATE_SUSPENDED = LibPipeWire.PW_NODE_STATE_SUSPENDED
    NODE_STATE_IDLE = LibPipeWire.PW_NODE_STATE_IDLE
    NODE_STATE_RUNNING = LibPipeWire.PW_NODE_STATE_RUNNING
end

"The current negotiation or streaming state of a PipeWire link."
@enum LinkState::Int32 begin
    LINK_STATE_ERROR = LibPipeWire.PW_LINK_STATE_ERROR
    LINK_STATE_UNLINKED = LibPipeWire.PW_LINK_STATE_UNLINKED
    LINK_STATE_INIT = LibPipeWire.PW_LINK_STATE_INIT
    LINK_STATE_NEGOTIATING = LibPipeWire.PW_LINK_STATE_NEGOTIATING
    LINK_STATE_ALLOCATING = LibPipeWire.PW_LINK_STATE_ALLOCATING
    LINK_STATE_PAUSED = LibPipeWire.PW_LINK_STATE_PAUSED
    LINK_STATE_ACTIVE = LibPipeWire.PW_LINK_STATE_ACTIVE
end

"A copied SPA parameter descriptor from a PipeWire object info event."
struct ParamInfo
    id::UInt32
    flags::UInt32
    user::UInt32
    sequence::Int32
end

"A copied node information snapshot."
struct NodeInfo
    id::UInt32
    max_input_ports::UInt32
    max_output_ports::UInt32
    change_mask::UInt64
    n_input_ports::UInt32
    n_output_ports::UInt32
    state::NodeState
    error::Union{Nothing,String}
    properties::Dict{String,String}
    params::Vector{ParamInfo}
end

"A copied port information snapshot."
struct PortInfo
    id::UInt32
    direction::Direction
    change_mask::UInt64
    properties::Dict{String,String}
    params::Vector{ParamInfo}
end

"A copied device information snapshot."
struct DeviceInfo
    id::UInt32
    change_mask::UInt64
    properties::Dict{String,String}
    params::Vector{ParamInfo}
end

"A copied link information snapshot."
struct LinkInfo
    id::UInt32
    output_node_id::UInt32
    output_port_id::UInt32
    input_node_id::UInt32
    input_port_id::UInt32
    change_mask::UInt64
    state::LinkState
    error::Union{Nothing,String}
    format::Union{Nothing,Pod}
    properties::Dict{String,String}
end

"Node info change-mask bit for the input-port count."
const NODE_CHANGE_INPUT_PORTS = UInt64(1) << 0
"Node info change-mask bit for the output-port count."
const NODE_CHANGE_OUTPUT_PORTS = UInt64(1) << 1
"Node info change-mask bit for state and error."
const NODE_CHANGE_STATE = UInt64(1) << 2
"Node info change-mask bit for properties."
const NODE_CHANGE_PROPERTIES = UInt64(1) << 3
"Node info change-mask bit for parameter descriptors."
const NODE_CHANGE_PARAMS = UInt64(1) << 4
"Port info change-mask bit for properties."
const PORT_CHANGE_PROPERTIES = UInt64(1) << 0
"Port info change-mask bit for parameter descriptors."
const PORT_CHANGE_PARAMS = UInt64(1) << 1
"Device info change-mask bit for properties."
const DEVICE_CHANGE_PROPERTIES = UInt64(1) << 0
"Device info change-mask bit for parameter descriptors."
const DEVICE_CHANGE_PARAMS = UInt64(1) << 1
"Link info change-mask bit for state and error."
const LINK_CHANGE_STATE = UInt64(1) << 0
"Link info change-mask bit for the negotiated format."
const LINK_CHANGE_FORMAT = UInt64(1) << 1
"Link info change-mask bit for properties."
const LINK_CHANGE_PROPERTIES = UInt64(1) << 2

@inline _changed(mask::UInt64, field::UInt64) = !iszero(mask & field)

function _merge_param_infos(current::Vector{ParamInfo}, update::Vector{ParamInfo})
    count = length(update)
    result = Vector{ParamInfo}(undef, count)
    retained = min(length(current), count)
    for index in 1:retained
        previous = current[index]
        changed = previous.flags != update[index].flags
        result[index] = ParamInfo(
            update[index].id,
            update[index].flags,
            previous.user + UInt32(changed),
            previous.sequence,
        )
    end
    for index in (retained + 1):count
        result[index] = ParamInfo(update[index].id, update[index].flags, UInt32(1), Int32(0))
    end
    return result
end

function _merge_info(::Nothing, update::NodeInfo)
    mask = update.change_mask
    return NodeInfo(
        update.id,
        update.max_input_ports,
        update.max_output_ports,
        mask,
        _changed(mask, NODE_CHANGE_INPUT_PORTS) ? update.n_input_ports : UInt32(0),
        _changed(mask, NODE_CHANGE_OUTPUT_PORTS) ? update.n_output_ports : UInt32(0),
        _changed(mask, NODE_CHANGE_STATE) ? update.state : NODE_STATE_CREATING,
        _changed(mask, NODE_CHANGE_STATE) ? update.error : nothing,
        _changed(mask, NODE_CHANGE_PROPERTIES) ? update.properties : Dict{String,String}(),
        _changed(mask, NODE_CHANGE_PARAMS) ?
        _merge_param_infos(ParamInfo[], update.params) : ParamInfo[],
    )
end

function _merge_info(current::NodeInfo, update::NodeInfo)
    mask = update.change_mask
    return NodeInfo(
        current.id,
        current.max_input_ports,
        current.max_output_ports,
        current.change_mask | mask,
        _changed(mask, NODE_CHANGE_INPUT_PORTS) ?
        update.n_input_ports : current.n_input_ports,
        _changed(mask, NODE_CHANGE_OUTPUT_PORTS) ?
        update.n_output_ports : current.n_output_ports,
        _changed(mask, NODE_CHANGE_STATE) ? update.state : current.state,
        _changed(mask, NODE_CHANGE_STATE) ? update.error : current.error,
        _changed(mask, NODE_CHANGE_PROPERTIES) ? update.properties : current.properties,
        _changed(mask, NODE_CHANGE_PARAMS) ?
        _merge_param_infos(current.params, update.params) : current.params,
    )
end

function _merge_info(::Nothing, update::PortInfo)
    mask = update.change_mask
    return PortInfo(
        update.id,
        update.direction,
        mask,
        _changed(mask, PORT_CHANGE_PROPERTIES) ? update.properties : Dict{String,String}(),
        _changed(mask, PORT_CHANGE_PARAMS) ?
        _merge_param_infos(ParamInfo[], update.params) : ParamInfo[],
    )
end

function _merge_info(current::PortInfo, update::PortInfo)
    mask = update.change_mask
    return PortInfo(
        current.id,
        current.direction,
        current.change_mask | mask,
        _changed(mask, PORT_CHANGE_PROPERTIES) ? update.properties : current.properties,
        _changed(mask, PORT_CHANGE_PARAMS) ?
        _merge_param_infos(current.params, update.params) : current.params,
    )
end

function _merge_info(::Nothing, update::DeviceInfo)
    mask = update.change_mask
    return DeviceInfo(
        update.id,
        mask,
        _changed(mask, DEVICE_CHANGE_PROPERTIES) ? update.properties : Dict{String,String}(),
        _changed(mask, DEVICE_CHANGE_PARAMS) ?
        _merge_param_infos(ParamInfo[], update.params) : ParamInfo[],
    )
end

function _merge_info(current::DeviceInfo, update::DeviceInfo)
    mask = update.change_mask
    return DeviceInfo(
        current.id,
        current.change_mask | mask,
        _changed(mask, DEVICE_CHANGE_PROPERTIES) ? update.properties : current.properties,
        _changed(mask, DEVICE_CHANGE_PARAMS) ?
        _merge_param_infos(current.params, update.params) : current.params,
    )
end

function _merge_info(::Nothing, update::LinkInfo)
    mask = update.change_mask
    return LinkInfo(
        update.id,
        update.output_node_id,
        update.output_port_id,
        update.input_node_id,
        update.input_port_id,
        mask,
        _changed(mask, LINK_CHANGE_STATE) ? update.state : LINK_STATE_INIT,
        _changed(mask, LINK_CHANGE_STATE) ? update.error : nothing,
        _changed(mask, LINK_CHANGE_FORMAT) ? update.format : nothing,
        _changed(mask, LINK_CHANGE_PROPERTIES) ? update.properties : Dict{String,String}(),
    )
end

function _merge_info(current::LinkInfo, update::LinkInfo)
    mask = update.change_mask
    return LinkInfo(
        current.id,
        current.output_node_id,
        current.output_port_id,
        current.input_node_id,
        current.input_port_id,
        current.change_mask | mask,
        _changed(mask, LINK_CHANGE_STATE) ? update.state : current.state,
        _changed(mask, LINK_CHANGE_STATE) ? update.error : current.error,
        _changed(mask, LINK_CHANGE_FORMAT) ? update.format : current.format,
        _changed(mask, LINK_CHANGE_PROPERTIES) ? update.properties : current.properties,
    )
end

"A copied factory information snapshot."
struct FactoryInfo
    id::UInt32
    name::String
    type::String
    version::UInt32
    change_mask::UInt64
    properties::Dict{String,String}
end

"A copied module information snapshot."
struct ModuleInfo
    id::UInt32
    name::String
    filename::String
    args::String
    change_mask::UInt64
    properties::Dict{String,String}
end

"A copied client information snapshot."
struct ClientInfo
    id::UInt32
    change_mask::UInt64
    properties::Dict{String,String}
end

"A PipeWire permission entry associating a global ID with a permission mask."
struct Permission
    id::UInt32
    permissions::UInt32
end

function _copy_param_infos(pointer::Ptr{LibPipeWire.spa_param_info}, count::UInt32)
    result = Vector{ParamInfo}(undef, count)
    for index in eachindex(result)
        info = unsafe_load(pointer, index)
        result[index] = ParamInfo(info.id, info.flags, info.user, info.seq)
    end
    return result
end

function _copy_node_info(pointer::Ptr{LibPipeWire.pw_node_info})
    pointer == C_NULL && throw(ArgumentError("the node info pointer is null"))
    info = unsafe_load(pointer)
    return NodeInfo(
        info.id,
        info.max_input_ports,
        info.max_output_ports,
        info.change_mask,
        info.n_input_ports,
        info.n_output_ports,
        NodeState(info.state),
        info.error == C_NULL ? nothing : unsafe_string(info.error),
        _copy_properties(info.props),
        _copy_param_infos(info.params, info.n_params),
    )
end

function _copy_port_info(pointer::Ptr{LibPipeWire.pw_port_info})
    pointer == C_NULL && throw(ArgumentError("the port info pointer is null"))
    info = unsafe_load(pointer)
    return PortInfo(
        info.id,
        Direction(info.direction),
        info.change_mask,
        _copy_properties(info.props),
        _copy_param_infos(info.params, info.n_params),
    )
end


function _copy_device_info(pointer::Ptr{LibPipeWire.pw_device_info})
    pointer == C_NULL && throw(ArgumentError("the device info pointer is null"))
    info = unsafe_load(pointer)
    return DeviceInfo(
        info.id,
        info.change_mask,
        _copy_properties(info.props),
        _copy_param_infos(info.params, info.n_params),
    )
end

function _copy_link_info(pointer::Ptr{LibPipeWire.pw_link_info})
    pointer == C_NULL && throw(ArgumentError("the link info pointer is null"))
    info = unsafe_load(pointer)
    return LinkInfo(
        info.id,
        info.output_node_id,
        info.output_port_id,
        info.input_node_id,
        info.input_port_id,
        info.change_mask,
        LinkState(info.state),
        info.error == C_NULL ? nothing : unsafe_string(info.error),
        _copy_pod(info.format),
        _copy_properties(info.props),
    )
end

function _copy_factory_info(pointer::Ptr{LibPipeWire.pw_factory_info})
    pointer == C_NULL && throw(ArgumentError("the factory info pointer is null"))
    info = unsafe_load(pointer)
    return FactoryInfo(
        info.id,
        info.name == C_NULL ? "" : unsafe_string(info.name),
        info.type == C_NULL ? "" : unsafe_string(info.type),
        info.version,
        info.change_mask,
        _copy_properties(info.props),
    )
end

function _copy_module_info(pointer::Ptr{LibPipeWire.pw_module_info})
    pointer == C_NULL && throw(ArgumentError("the module info pointer is null"))
    info = unsafe_load(pointer)
    return ModuleInfo(
        info.id,
        info.name == C_NULL ? "" : unsafe_string(info.name),
        info.filename == C_NULL ? "" : unsafe_string(info.filename),
        info.args == C_NULL ? "" : unsafe_string(info.args),
        info.change_mask,
        _copy_properties(info.props),
    )
end

function _copy_client_info(pointer::Ptr{LibPipeWire.pw_client_info})
    pointer == C_NULL && throw(ArgumentError("the client info pointer is null"))
    info = unsafe_load(pointer)
    return ClientInfo(info.id, info.change_mask, _copy_properties(info.props))
end

function _copy_permissions(pointer::Ptr{LibPipeWire.pw_permission}, count::UInt32)
    result = Vector{Permission}(undef, count)
    for index in eachindex(result)
        permission = unsafe_load(pointer, index)
        result[index] = Permission(permission.id, permission.permissions)
    end
    return result
end

for (name, event_type) in (
    (:Node, :(LibPipeWire.pw_node_events)),
    (:Port, :(LibPipeWire.pw_port_events)),
    (:Device, :(LibPipeWire.pw_device_events)),
    (:Link, :(LibPipeWire.pw_link_events)),
    (:Metadata, :(LibPipeWire.pw_metadata_events)),
    (:Factory, :(LibPipeWire.pw_factory_events)),
    (:PipeWireModule, :(LibPipeWire.pw_module_events)),
    (:Client, :(LibPipeWire.pw_client_events)),
    (:Profiler, :(LibPipeWire.pw_profiler_events)),
)
    @eval begin
        mutable struct $name{ProxyType<:Proxy,Callbacks}
            proxy::ProxyType
            callback_lock::ReentrantLock
            listener::Base.RefValue{LibPipeWire.spa_hook}
            events::Base.RefValue{$event_type}
            callbacks::Callbacks
            callback_error::Base.RefValue{Any}
            callbacks_active::Bool
        end
    end
end

"""
    Node

An owning typed proxy for a PipeWire node. Construct one with
`bind(registry, global_object, Node; callbacks...)`.
"""
Node

"""
    Port

An owning typed proxy for a PipeWire port. Construct one with
`bind(registry, global_object, Port; callbacks...)`.
"""
Port

"""
    Device

An owning typed proxy for a PipeWire device. Construct one with
`bind(registry, global_object, Device; callbacks...)`.
"""
Device

"""
    Link

An owning typed proxy for a PipeWire link. Construct one with
`bind(registry, global_object, Link; callbacks...)`.
"""
Link

"""
    Metadata

An owning typed proxy for a PipeWire metadata store. Construct one with
`bind(registry, global_object, Metadata; callbacks...)`.
"""
Metadata

"An owning typed proxy for a PipeWire factory."
Factory

"An owning typed proxy for a loaded PipeWire module."
PipeWireModule

"An owning typed proxy for a connected PipeWire client."
Client

"An owning typed proxy for PipeWire profiling samples."
Profiler

const ManagedObject =
    Union{Node,Port,Device,Link,Metadata,Factory,PipeWireModule,Client,Profiler}

function _invoke_object_callback(object::ManagedObject, ::Val{Field}, args...) where {Field}
    lock(object.callback_lock)
    if !object.callbacks_active
        unlock(object.callback_lock)
        return nothing
    end
    callback = getfield(object.callbacks, Field)
    unlock(object.callback_lock)
    callback === nothing && return nothing
    try
        callback(object, args...)
    catch error
        lock(object.callback_lock) do
            object.callback_error[] === nothing && (object.callback_error[] = error)
        end
        _stop_after_callback(_proxy_core(object.proxy).callback_state, error)
    end
    return nothing
end

function _require_open(object::ManagedObject)
    error = lock(object.callback_lock) do
        object.callback_error[]
    end
    error === nothing || throw(error)
    return _require_open(object.proxy)
end

Base.isopen(object::ManagedObject) = isopen(object.proxy)

function Base.close(object::ManagedObject)
    lock(object.callback_lock) do
        object.callbacks_active = false
    end
    close(object.proxy)
    return nothing
end

function destroy_object!(core::CoreConnection, object::ManagedObject)
    object.proxy.parent isa CoreConnection || throw(
        ArgumentError("only core-created PipeWire objects can be destroyed this way"),
    )
    object.proxy.parent === core || throw(
        ArgumentError("the object belongs to a different PipeWire core"),
    )
    lock(object.callback_lock) do
        object.callbacks_active = false
    end
    destroy_object!(core, object.proxy)
    return core
end

interface_type(object::ManagedObject) = interface_type(object.proxy)
proxy_id(object::ManagedObject) = proxy_id(object.proxy)
bound_id(object::ManagedObject) = bound_id(object.proxy)

function roundtrip(object::ManagedObject)
    roundtrip(object.proxy)
    _require_open(object)
    return nothing
end

function _typed_proxy(
    registry::Registry,
    global_object::Global,
    expected_type::String,
    version::Integer;
    proxy_callbacks...,
)
    global_object.type == expected_type || throw(
        ArgumentError("the global does not implement $expected_type"),
    )
    maximum = min(global_object.version, _OBJECT_INTERFACE_VERSION)
    0 <= version <= maximum || throw(
        ArgumentError("the requested interface version exceeds the supported version"),
    )
    return bind(registry, global_object; version=version, proxy_callbacks...)
end

function _with_object_handle(call, object::ManagedObject, ::Type{T}) where {T}
    error = lock(object.callback_lock) do
        object.callback_error[]
    end
    error === nothing || throw(error)
    return lock(object.proxy.state_lock) do
        call(Ptr{T}(_require_open(object.proxy)))
    end
end

function _node_info(object::Node, info::Ptr{LibPipeWire.pw_node_info})::Cvoid
    try
        _invoke_object_callback(object, Val(:on_info), _copy_node_info(info))
    catch error
        _record_object_callback_error(object, error)
    end
    return nothing
end

function _port_info(object::Port, info::Ptr{LibPipeWire.pw_port_info})::Cvoid
    try
        _invoke_object_callback(object, Val(:on_info), _copy_port_info(info))
    catch error
        _record_object_callback_error(object, error)
    end
    return nothing
end

function _device_info(object::Device, info::Ptr{LibPipeWire.pw_device_info})::Cvoid
    try
        _invoke_object_callback(object, Val(:on_info), _copy_device_info(info))
    catch error
        _record_object_callback_error(object, error)
    end
    return nothing
end

function _link_info(object::Link, info::Ptr{LibPipeWire.pw_link_info})::Cvoid
    try
        _invoke_object_callback(object, Val(:on_info), _copy_link_info(info))
    catch error
        _record_object_callback_error(object, error)
    end
    return nothing
end

function _factory_info(
    object::Factory,
    info::Ptr{LibPipeWire.pw_factory_info},
)::Cvoid
    try
        _invoke_object_callback(object, Val(:on_info), _copy_factory_info(info))
    catch error
        _record_object_callback_error(object, error)
    end
    return nothing
end

function _module_info(
    object::PipeWireModule,
    info::Ptr{LibPipeWire.pw_module_info},
)::Cvoid
    try
        _invoke_object_callback(object, Val(:on_info), _copy_module_info(info))
    catch error
        _record_object_callback_error(object, error)
    end
    return nothing
end

function _client_info(object::Client, info::Ptr{LibPipeWire.pw_client_info})::Cvoid
    try
        _invoke_object_callback(object, Val(:on_info), _copy_client_info(info))
    catch error
        _record_object_callback_error(object, error)
    end
    return nothing
end

function _client_permissions(
    object::Client,
    index::UInt32,
    count::UInt32,
    permissions::Ptr{LibPipeWire.pw_permission},
)::Cvoid
    try
        _invoke_object_callback(
            object,
            Val(:on_permissions),
            index,
            _copy_permissions(permissions, count),
        )
    catch error
        _record_object_callback_error(object, error)
    end
    return nothing
end

function _record_object_callback_error(object::ManagedObject, error)
    lock(object.callback_lock) do
        object.callback_error[] === nothing && (object.callback_error[] = error)
    end
    _stop_after_callback(_proxy_core(object.proxy).callback_state, error)
    return nothing
end

function _object_param(
    object::Union{Node,Port,Device},
    sequence::Cint,
    id::UInt32,
    index::UInt32,
    next::UInt32,
    param::Ptr{LibPipeWire.spa_pod},
)
    try
        _invoke_object_callback(
            object,
            Val(:on_param),
            sequence,
            id,
            index,
            next,
            _copy_pod(param),
        )
    catch error
        _record_object_callback_error(object, error)
    end
    return nothing
end

function _node_param(
    object::Node,
    sequence::Cint,
    id::UInt32,
    index::UInt32,
    next::UInt32,
    param::Ptr{LibPipeWire.spa_pod},
)::Cvoid
    _object_param(object, sequence, id, index, next, param)
end

function _port_param(
    object::Port,
    sequence::Cint,
    id::UInt32,
    index::UInt32,
    next::UInt32,
    param::Ptr{LibPipeWire.spa_pod},
)::Cvoid
    _object_param(object, sequence, id, index, next, param)
end

function _device_param(
    object::Device,
    sequence::Cint,
    id::UInt32,
    index::UInt32,
    next::UInt32,
    param::Ptr{LibPipeWire.spa_pod},
)::Cvoid
    _object_param(object, sequence, id, index, next, param)
end

function _metadata_property(
    object::Metadata,
    subject::UInt32,
    key::Cstring,
    type::Cstring,
    value::Cstring,
)::Cint
    try
        _invoke_object_callback(
            object,
            Val(:on_property),
            subject,
            key == C_NULL ? nothing : unsafe_string(key),
            type == C_NULL ? nothing : unsafe_string(type),
            value == C_NULL ? nothing : unsafe_string(value),
        )
    catch error
        _record_object_callback_error(object, error)
    end
    return Cint(0)
end

function _profiler_profile(
    profiler::Profiler,
    pod::Ptr{LibPipeWire.spa_pod},
)::Cvoid
    try
        _invoke_object_callback(profiler, Val(:on_profile), _copy_pod(pod))
    catch error
        _record_object_callback_error(profiler, error)
    end
    return nothing
end

function _node_events(::T) where {T<:Node}
    info = @cfunction(_node_info, Cvoid, (Ref{T}, Ptr{LibPipeWire.pw_node_info}))
    param = @cfunction(
        _node_param,
        Cvoid,
        (Ref{T}, Cint, UInt32, UInt32, UInt32, Ptr{LibPipeWire.spa_pod}),
    )
    return LibPipeWire.pw_node_events(UInt32(0), info, param)
end

function _port_events(::T) where {T<:Port}
    info = @cfunction(_port_info, Cvoid, (Ref{T}, Ptr{LibPipeWire.pw_port_info}))
    param = @cfunction(
        _port_param,
        Cvoid,
        (Ref{T}, Cint, UInt32, UInt32, UInt32, Ptr{LibPipeWire.spa_pod}),
    )
    return LibPipeWire.pw_port_events(UInt32(0), info, param)
end

function _device_events(::T) where {T<:Device}
    info = @cfunction(
        _device_info,
        Cvoid,
        (Ref{T}, Ptr{LibPipeWire.pw_device_info}),
    )
    param = @cfunction(
        _device_param,
        Cvoid,
        (Ref{T}, Cint, UInt32, UInt32, UInt32, Ptr{LibPipeWire.spa_pod}),
    )
    return LibPipeWire.pw_device_events(UInt32(0), info, param)
end

function _link_events(::T) where {T<:Link}
    info = @cfunction(_link_info, Cvoid, (Ref{T}, Ptr{LibPipeWire.pw_link_info}))
    return LibPipeWire.pw_link_events(UInt32(0), info)
end

function _metadata_events(::T) where {T<:Metadata}
    property = @cfunction(
        _metadata_property,
        Cint,
        (Ref{T}, UInt32, Cstring, Cstring, Cstring),
    )
    return LibPipeWire.pw_metadata_events(UInt32(0), property)
end

function _profiler_events(::T) where {T<:Profiler}
    profile = @cfunction(
        _profiler_profile,
        Cvoid,
        (Ref{T}, Ptr{LibPipeWire.spa_pod}),
    )
    return LibPipeWire.pw_profiler_events(UInt32(0), profile)
end

function _factory_events(::T) where {T<:Factory}
    info = @cfunction(
        _factory_info,
        Cvoid,
        (Ref{T}, Ptr{LibPipeWire.pw_factory_info}),
    )
    return LibPipeWire.pw_factory_events(UInt32(0), info)
end

function _module_events(::T) where {T<:PipeWireModule}
    info = @cfunction(
        _module_info,
        Cvoid,
        (Ref{T}, Ptr{LibPipeWire.pw_module_info}),
    )
    return LibPipeWire.pw_module_events(UInt32(0), info)
end

function _client_events(::T) where {T<:Client}
    info = @cfunction(
        _client_info,
        Cvoid,
        (Ref{T}, Ptr{LibPipeWire.pw_client_info}),
    )
    permissions = @cfunction(
        _client_permissions,
        Cvoid,
        (Ref{T}, UInt32, UInt32, Ptr{LibPipeWire.pw_permission}),
    )
    return LibPipeWire.pw_client_events(UInt32(0), info, permissions)
end

function _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    return (
        on_bound=on_bound,
        on_removed=on_removed,
        on_done=on_done,
        on_error=on_error,
        on_bound_properties=on_bound_properties,
    )
end

function _attach_node(proxy::Proxy, on_info, on_param)
    listener = Ref(_zero_hook())
    events = Ref{LibPipeWire.pw_node_events}()
    callbacks = (on_info=on_info, on_param=on_param)
    object = Node(proxy, ReentrantLock(), listener, events, callbacks, Ref{Any}(nothing), true)
    try
        events[] = _node_events(object)
    catch
        close(object)
        rethrow()
    end
    result = GC.@preserve object listener events LibPipeWire.pw_node_add_listener(
        Ptr{LibPipeWire.pw_node}(proxy.handle),
        Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener),
        Base.unsafe_convert(Ptr{LibPipeWire.pw_node_events}, events),
        pointer_from_objref(object),
    )
    result < 0 && (close(object); throw(PipeWireError(:pw_node_add_listener, result)))
    finalizer(close, object)
    return object
end


function _attach_port(proxy::Proxy, on_info, on_param)
    listener = Ref(_zero_hook())
    events = Ref{LibPipeWire.pw_port_events}()
    callbacks = (on_info=on_info, on_param=on_param)
    object = Port(proxy, ReentrantLock(), listener, events, callbacks, Ref{Any}(nothing), true)
    try
        events[] = _port_events(object)
    catch
        close(object)
        rethrow()
    end
    result = GC.@preserve object listener events LibPipeWire.pw_port_add_listener(
        Ptr{LibPipeWire.pw_port}(proxy.handle),
        Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener),
        Base.unsafe_convert(Ptr{LibPipeWire.pw_port_events}, events),
        pointer_from_objref(object),
    )
    result < 0 && (close(object); throw(PipeWireError(:pw_port_add_listener, result)))
    finalizer(close, object)
    return object
end

function _attach_device(proxy::Proxy, on_info, on_param)
    listener = Ref(_zero_hook())
    events = Ref{LibPipeWire.pw_device_events}()
    callbacks = (on_info=on_info, on_param=on_param)
    object = Device(proxy, ReentrantLock(), listener, events, callbacks, Ref{Any}(nothing), true)
    try
        events[] = _device_events(object)
    catch
        close(object)
        rethrow()
    end
    result = GC.@preserve object listener events LibPipeWire.pw_device_add_listener(
        Ptr{LibPipeWire.pw_device}(proxy.handle),
        Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener),
        Base.unsafe_convert(Ptr{LibPipeWire.pw_device_events}, events),
        pointer_from_objref(object),
    )
    result < 0 && (close(object); throw(PipeWireError(:pw_device_add_listener, result)))
    finalizer(close, object)
    return object
end

function _attach_link(proxy::Proxy, on_info)
    listener = Ref(_zero_hook())
    events = Ref{LibPipeWire.pw_link_events}()
    callbacks = (on_info=on_info,)
    object = Link(proxy, ReentrantLock(), listener, events, callbacks, Ref{Any}(nothing), true)
    try
        events[] = _link_events(object)
    catch
        close(object)
        rethrow()
    end
    result = GC.@preserve object listener events LibPipeWire.pw_link_add_listener(
        Ptr{LibPipeWire.pw_link}(proxy.handle),
        Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener),
        Base.unsafe_convert(Ptr{LibPipeWire.pw_link_events}, events),
        pointer_from_objref(object),
    )
    result < 0 && (close(object); throw(PipeWireError(:pw_link_add_listener, result)))
    finalizer(close, object)
    return object
end

function _attach_factory(proxy::Proxy, on_info)
    listener = Ref(_zero_hook())
    events = Ref{LibPipeWire.pw_factory_events}()
    callbacks = (on_info=on_info,)
    object = Factory(proxy, ReentrantLock(), listener, events, callbacks, Ref{Any}(nothing), true)
    try
        events[] = _factory_events(object)
    catch
        close(object)
        rethrow()
    end
    result = GC.@preserve object listener events LibPipeWire.pw_factory_add_listener(
        Ptr{LibPipeWire.pw_factory}(proxy.handle),
        Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener),
        Base.unsafe_convert(Ptr{LibPipeWire.pw_factory_events}, events),
        pointer_from_objref(object),
    )
    result < 0 && (close(object); throw(PipeWireError(:pw_factory_add_listener, result)))
    finalizer(close, object)
    return object
end

function _attach_module(proxy::Proxy, on_info)
    listener = Ref(_zero_hook())
    events = Ref{LibPipeWire.pw_module_events}()
    callbacks = (on_info=on_info,)
    object = PipeWireModule(proxy, ReentrantLock(), listener, events, callbacks, Ref{Any}(nothing), true)
    try
        events[] = _module_events(object)
    catch
        close(object)
        rethrow()
    end
    result = GC.@preserve object listener events LibPipeWire.pw_module_add_listener(
        Ptr{LibPipeWire.pw_module}(proxy.handle),
        Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener),
        Base.unsafe_convert(Ptr{LibPipeWire.pw_module_events}, events),
        pointer_from_objref(object),
    )
    result < 0 && (close(object); throw(PipeWireError(:pw_module_add_listener, result)))
    finalizer(close, object)
    return object
end

function _attach_client(proxy::Proxy, on_info, on_permissions)
    listener = Ref(_zero_hook())
    events = Ref{LibPipeWire.pw_client_events}()
    callbacks = (on_info=on_info, on_permissions=on_permissions)
    object = Client(proxy, ReentrantLock(), listener, events, callbacks, Ref{Any}(nothing), true)
    try
        events[] = _client_events(object)
    catch
        close(object)
        rethrow()
    end
    result = GC.@preserve object listener events LibPipeWire.pw_client_add_listener(
        Ptr{LibPipeWire.pw_client}(proxy.handle),
        Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener),
        Base.unsafe_convert(Ptr{LibPipeWire.pw_client_events}, events),
        pointer_from_objref(object),
    )
    result < 0 && (close(object); throw(PipeWireError(:pw_client_add_listener, result)))
    finalizer(close, object)
    return object
end

"""
    bind(registry, global_object, Node; callbacks...) -> Node

Bind a node global and install copied `on_info` and `on_param` event callbacks.
The base proxy callbacks are also accepted. Close the node before its registry.
"""
function Base.bind(
    registry::Registry,
    global_object::Global,
    ::Type{Node};
    version::Integer=min(global_object.version, _OBJECT_INTERFACE_VERSION),
    on_info=nothing,
    on_param=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    proxy_callbacks = _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    proxy = _typed_proxy(registry, global_object, _NODE_INTERFACE, version; proxy_callbacks...)
    return _attach_node(proxy, on_info, on_param)
end


"""
    bind(registry, global_object, Port; callbacks...) -> Port

Bind a port global and install copied `on_info` and `on_param` event callbacks.
The base proxy callbacks are also accepted. Close the port before its registry.
"""
function Base.bind(
    registry::Registry,
    global_object::Global,
    ::Type{Port};
    version::Integer=min(global_object.version, _OBJECT_INTERFACE_VERSION),
    on_info=nothing,
    on_param=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    proxy_callbacks = _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    proxy = _typed_proxy(registry, global_object, _PORT_INTERFACE, version; proxy_callbacks...)
    return _attach_port(proxy, on_info, on_param)
end

"""
    bind(registry, global_object, Device; callbacks...) -> Device

Bind a device global and install copied `on_info` and `on_param` event callbacks.
The base proxy callbacks are also accepted. Close the device before its registry.
"""
function Base.bind(
    registry::Registry,
    global_object::Global,
    ::Type{Device};
    version::Integer=min(global_object.version, _OBJECT_INTERFACE_VERSION),
    on_info=nothing,
    on_param=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    proxy_callbacks = _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    proxy = _typed_proxy(registry, global_object, _DEVICE_INTERFACE, version; proxy_callbacks...)
    return _attach_device(proxy, on_info, on_param)
end

"""
    bind(registry, global_object, Link; callbacks...) -> Link

Bind a link global and install a copied `on_info` event callback. The base
proxy callbacks are also accepted. Close the link before its registry.
"""
function Base.bind(
    registry::Registry,
    global_object::Global,
    ::Type{Link};
    version::Integer=min(global_object.version, _OBJECT_INTERFACE_VERSION),
    on_info=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    proxy_callbacks = _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    proxy = _typed_proxy(registry, global_object, _LINK_INTERFACE, version; proxy_callbacks...)
    return _attach_link(proxy, on_info)
end

"""
    bind(registry, global_object, Factory; callbacks...) -> Factory

Bind a factory global and install a copied `on_info` event callback.
"""
function Base.bind(
    registry::Registry,
    global_object::Global,
    ::Type{Factory};
    version::Integer=min(global_object.version, _OBJECT_INTERFACE_VERSION),
    on_info=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    proxy_callbacks = _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    proxy = _typed_proxy(registry, global_object, _FACTORY_INTERFACE, version; proxy_callbacks...)
    return _attach_factory(proxy, on_info)
end

"""
    bind(registry, global_object, PipeWireModule; callbacks...) -> PipeWireModule

Bind a module global and install a copied `on_info` event callback.
"""
function Base.bind(
    registry::Registry,
    global_object::Global,
    ::Type{PipeWireModule};
    version::Integer=min(global_object.version, _OBJECT_INTERFACE_VERSION),
    on_info=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    proxy_callbacks = _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    proxy = _typed_proxy(registry, global_object, _MODULE_INTERFACE, version; proxy_callbacks...)
    return _attach_module(proxy, on_info)
end

"""
    bind(registry, global_object, Client; callbacks...) -> Client

Bind a client global. `on_info` receives copied client info and
`on_permissions(client, index, permissions)` receives copied permission entries.
"""
function Base.bind(
    registry::Registry,
    global_object::Global,
    ::Type{Client};
    version::Integer=min(global_object.version, _OBJECT_INTERFACE_VERSION),
    on_info=nothing,
    on_permissions=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    proxy_callbacks = _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    proxy = _typed_proxy(registry, global_object, _CLIENT_INTERFACE, version; proxy_callbacks...)
    return _attach_client(proxy, on_info, on_permissions)
end

function _with_metadata_method(call, object::Metadata, field::Symbol)
    return _with_object_handle(object, LibPipeWire.pw_metadata) do handle
        interface = unsafe_load(Ptr{LibPipeWire.spa_interface}(handle))
        interface.cb.funcs == C_NULL && throw(
            PipeWireError(Symbol("pw_metadata_", field), -Base.Libc.ENOTSUP),
        )
        methods = unsafe_load(Ptr{LibPipeWire.pw_metadata_methods}(interface.cb.funcs))
        method = getfield(methods, field)
        method == C_NULL && throw(
            PipeWireError(Symbol("pw_metadata_", field), -Base.Libc.ENOTSUP),
        )
        call(interface.cb.data, method)
    end
end

function _attach_metadata(proxy::Proxy, on_property)
    listener = Ref(_zero_hook())
    events = Ref{LibPipeWire.pw_metadata_events}()
    callbacks = (on_property=on_property,)
    object = Metadata(proxy, ReentrantLock(), listener, events, callbacks, Ref{Any}(nothing), true)
    try
        events[] = _metadata_events(object)
    catch
        close(object)
        rethrow()
    end
    result = try
        _with_metadata_method(object, :add_listener) do data, method
            GC.@preserve object listener events @ccall $method(
                data::Ptr{Cvoid},
                Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener)::Ptr{LibPipeWire.spa_hook},
                Base.unsafe_convert(Ptr{LibPipeWire.pw_metadata_events}, events)::Ptr{LibPipeWire.pw_metadata_events},
                pointer_from_objref(object)::Ptr{Cvoid},
            )::Cint
        end
    catch
        close(object)
        rethrow()
    end
    result < 0 && (close(object); throw(PipeWireError(:pw_metadata_add_listener, result)))
    finalizer(close, object)
    return object
end

function _with_profiler_method(call, object::Profiler, field::Symbol)
    return _with_object_handle(object, LibPipeWire.pw_profiler) do handle
        interface = unsafe_load(Ptr{LibPipeWire.spa_interface}(handle))
        interface.cb.funcs == C_NULL && throw(
            PipeWireError(Symbol("pw_profiler_", field), -Base.Libc.ENOTSUP),
        )
        methods = unsafe_load(Ptr{LibPipeWire.pw_profiler_methods}(interface.cb.funcs))
        method = getfield(methods, field)
        method == C_NULL && throw(
            PipeWireError(Symbol("pw_profiler_", field), -Base.Libc.ENOTSUP),
        )
        return call(interface.cb.data, method)
    end
end

function _attach_profiler(proxy::Proxy, on_profile)
    listener = Ref(_zero_hook())
    events = Ref{LibPipeWire.pw_profiler_events}()
    callbacks = (on_profile=on_profile,)
    object = Profiler(
        proxy,
        ReentrantLock(),
        listener,
        events,
        callbacks,
        Ref{Any}(nothing),
        true,
    )
    try
        events[] = _profiler_events(object)
    catch
        close(object)
        rethrow()
    end
    result = try
        _with_profiler_method(object, :add_listener) do data, method
            GC.@preserve object listener events @ccall $method(
                data::Ptr{Cvoid},
                Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener)::Ptr{LibPipeWire.spa_hook},
                Base.unsafe_convert(Ptr{LibPipeWire.pw_profiler_events}, events)::Ptr{LibPipeWire.pw_profiler_events},
                pointer_from_objref(object)::Ptr{Cvoid},
            )::Cint
        end
    catch
        close(object)
        rethrow()
    end
    result < 0 && (close(object); throw(PipeWireError(:pw_profiler_add_listener, result)))
    finalizer(close, object)
    return object
end

"""
    bind(registry, global_object, Metadata; callbacks...) -> Metadata

Bind a metadata global and install `on_property`. Property strings are copied
before the callback runs. The base proxy callbacks are also accepted.
"""
function Base.bind(
    registry::Registry,
    global_object::Global,
    ::Type{Metadata};
    version::Integer=min(global_object.version, _OBJECT_INTERFACE_VERSION),
    on_property=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    proxy_callbacks = _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    proxy = _typed_proxy(registry, global_object, _METADATA_INTERFACE, version; proxy_callbacks...)
    return _attach_metadata(proxy, on_property)
end

"""
    bind(registry, global_object, Profiler; on_profile=nothing, callbacks...)

Bind the profiler extension. `on_profile(profiler, pod)` receives an owned copy
of each profiling POD, safe to retain after the callback returns.
"""
function Base.bind(
    registry::Registry,
    global_object::Global,
    ::Type{Profiler};
    version::Integer=min(global_object.version, _OBJECT_INTERFACE_VERSION),
    on_profile=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    _ensure_context_module!(
        registry.core.context,
        "libpipewire-module-profiler",
    )
    proxy_callbacks = _proxy_callback_keywords(
        on_bound,
        on_removed,
        on_done,
        on_error,
        on_bound_properties,
    )
    proxy = _typed_proxy(
        registry,
        global_object,
        _PROFILER_INTERFACE,
        version;
        proxy_callbacks...,
    )
    return _attach_profiler(proxy, on_profile)
end

"""
    create_object(core, factory_name, Node; properties=nothing, callbacks...) -> Node
    create_object(core, factory_name, Port; properties=nothing, callbacks...) -> Port
    create_object(core, factory_name, Device; properties=nothing, callbacks...) -> Device
    create_object(core, factory_name, Link; properties=nothing, callbacks...) -> Link
    create_object(core, factory_name, Metadata; properties=nothing, callbacks...) -> Metadata

Create a typed server-side PipeWire object from a factory. Interface callbacks
and the base proxy callbacks accepted by [`bind`](@ref) are supported.
"""
function create_object(
    core::CoreConnection,
    factory_name::AbstractString,
    ::Type{Node};
    version::Integer=_OBJECT_INTERFACE_VERSION,
    properties=nothing,
    on_info=nothing,
    on_param=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    proxy_callbacks = _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    proxy = create_object(core, factory_name, _NODE_INTERFACE; version, properties, proxy_callbacks...)
    return _attach_node(proxy, on_info, on_param)
end

function create_object(
    core::CoreConnection,
    factory_name::AbstractString,
    ::Type{Port};
    version::Integer=_OBJECT_INTERFACE_VERSION,
    properties=nothing,
    on_info=nothing,
    on_param=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    proxy_callbacks = _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    proxy = create_object(core, factory_name, _PORT_INTERFACE; version, properties, proxy_callbacks...)
    return _attach_port(proxy, on_info, on_param)
end

function create_object(
    core::CoreConnection,
    factory_name::AbstractString,
    ::Type{Device};
    version::Integer=_OBJECT_INTERFACE_VERSION,
    properties=nothing,
    on_info=nothing,
    on_param=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    proxy_callbacks = _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    proxy = create_object(core, factory_name, _DEVICE_INTERFACE; version, properties, proxy_callbacks...)
    return _attach_device(proxy, on_info, on_param)
end

function create_object(
    core::CoreConnection,
    factory_name::AbstractString,
    ::Type{Link};
    version::Integer=_OBJECT_INTERFACE_VERSION,
    properties=nothing,
    on_info=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    proxy_callbacks = _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    proxy = create_object(core, factory_name, _LINK_INTERFACE; version, properties, proxy_callbacks...)
    return _attach_link(proxy, on_info)
end

function create_object(
    core::CoreConnection,
    factory_name::AbstractString,
    ::Type{Metadata};
    version::Integer=_OBJECT_INTERFACE_VERSION,
    properties=nothing,
    on_property=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    proxy_callbacks = _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    proxy = create_object(core, factory_name, _METADATA_INTERFACE; version, properties, proxy_callbacks...)
    return _attach_metadata(proxy, on_property)
end

function _parameter_ids(ids)
    return UInt32[UInt32(id) for id in ids]
end

"""
    subscribe_params!(object, ids)

Subscribe a node, port, or device to changes for the given SPA parameter IDs.
Return `object`.
"""
function subscribe_params!(object::Node, ids)
    values = _parameter_ids(ids)
    result = GC.@preserve values _with_object_handle(object, LibPipeWire.pw_node) do handle
        LibPipeWire.pw_node_subscribe_params(handle, pointer(values), UInt32(length(values)))
    end
    _check_result(:pw_node_subscribe_params, result)
    return object
end

function subscribe_params!(object::Port, ids)
    values = _parameter_ids(ids)
    result = GC.@preserve values _with_object_handle(object, LibPipeWire.pw_port) do handle
        LibPipeWire.pw_port_subscribe_params(handle, pointer(values), UInt32(length(values)))
    end
    _check_result(:pw_port_subscribe_params, result)
    return object
end

function subscribe_params!(object::Device, ids)
    values = _parameter_ids(ids)
    result = GC.@preserve values _with_object_handle(object, LibPipeWire.pw_device) do handle
        LibPipeWire.pw_device_subscribe_params(handle, pointer(values), UInt32(length(values)))
    end
    _check_result(:pw_device_subscribe_params, result)
    return object
end

function _enum_params(function_name::Symbol, call, object, object_type, id, sequence, start, count, filter)
    sequence isa Integer && typemin(Cint) <= sequence <= typemax(Cint) || throw(ArgumentError("sequence is outside Cint range"))
    filter_pointer = filter === nothing ? Ptr{LibPipeWire.spa_pod}(C_NULL) : _pod_pointer(filter)
    result = GC.@preserve filter _with_object_handle(object, object_type) do handle
        call(
            handle,
            Cint(sequence),
            UInt32(id),
            UInt32(start),
            UInt32(count),
            filter_pointer,
        )
    end
    _check_result(function_name, result)
    return result
end

"""
    enum_params!(object, id; sequence=0, start=0, count=typemax(UInt32),
                 filter=nothing, sequence_out=nothing)

Request parameter enumeration on a node, port, or device. Results arrive
through the object's `on_param` callback. Return `object`. When `sequence_out`
is a `Ref{Cint}`, store the actual native asynchronous sequence there after a
successful request. The native protocol can replace the requested `sequence`;
use this returned value to correlate parameter callbacks. Failure leaves the
reference unchanged. A core synchronization barrier can fence the collected
results; this function does not wait for them or aggregate them.
"""
function enum_params!(object::Node, id::Integer; sequence::Integer=0, start::Integer=0, count::Integer=typemax(UInt32), filter::Union{Nothing,Pod}=nothing, sequence_out::Union{Nothing,Base.RefValue{Cint}}=nothing)
    result = _enum_params(:pw_node_enum_params, LibPipeWire.pw_node_enum_params, object, LibPipeWire.pw_node, id, sequence, start, count, filter)
    sequence_out === nothing || (sequence_out[] = result)
    return object
end


function enum_params!(object::Port, id::Integer; sequence::Integer=0, start::Integer=0, count::Integer=typemax(UInt32), filter::Union{Nothing,Pod}=nothing, sequence_out::Union{Nothing,Base.RefValue{Cint}}=nothing)
    result = _enum_params(:pw_port_enum_params, LibPipeWire.pw_port_enum_params, object, LibPipeWire.pw_port, id, sequence, start, count, filter)
    sequence_out === nothing || (sequence_out[] = result)
    return object
end

function enum_params!(object::Device, id::Integer; sequence::Integer=0, start::Integer=0, count::Integer=typemax(UInt32), filter::Union{Nothing,Pod}=nothing, sequence_out::Union{Nothing,Base.RefValue{Cint}}=nothing)
    result = _enum_params(:pw_device_enum_params, LibPipeWire.pw_device_enum_params, object, LibPipeWire.pw_device, id, sequence, start, count, filter)
    sequence_out === nothing || (sequence_out[] = result)
    return object
end

"""
    set_param!(object, id, param; flags=0)

Set a SPA parameter on a node or device and return `object`.
"""
function set_param!(object::Union{Node,Device}, id::Integer, param::Pod; flags::Integer=0)
    pointer = _pod_pointer(param)
    result = GC.@preserve param if object isa Node
        _with_object_handle(object, LibPipeWire.pw_node) do handle
            LibPipeWire.pw_node_set_param(handle, UInt32(id), UInt32(flags), pointer)
        end
    else
        _with_object_handle(object, LibPipeWire.pw_device) do handle
            LibPipeWire.pw_device_set_param(handle, UInt32(id), UInt32(flags), pointer)
        end
    end
    _check_result(object isa Node ? :pw_node_set_param : :pw_device_set_param, result)
    return object
end

"""
    send_command!(node, command)

Send an owned SPA command POD to a node and return the node.
"""
function send_command!(object::Node, command::Pod)
    pod_value(SPA.Command, command)
    result = GC.@preserve command _with_object_handle(object, LibPipeWire.pw_node) do handle
        LibPipeWire.pw_node_send_command(
            handle,
            Ptr{LibPipeWire.spa_command}(_pod_pointer(command)),
        )
    end
    _check_result(:pw_node_send_command, result)
    return object
end

send_command!(object::Node, command::SPA.Command) = send_command!(object, Pod(command))

function _metadata_string(value, kind)
    value === nothing && return nothing
    return _validate_c_string(String(value), kind)
end

"""
    set_property!(metadata, subject, key; type=nothing, value=nothing)

Set a metadata property and return `metadata`. Pass `value=nothing` to remove
the key, or `key=nothing` to remove every property associated with `subject`.
"""
function set_property!(
    object::Metadata,
    subject::Integer,
    key;
    type=nothing,
    value=nothing,
)
    subject < 0 && throw(ArgumentError("metadata subject must be nonnegative"))
    owned_key = _metadata_string(key, "metadata key")
    owned_type = _metadata_string(type, "metadata type")
    owned_value = _metadata_string(value, "metadata value")
    result = _with_metadata_method(object, :set_property) do data, method
        GC.@preserve owned_key owned_type owned_value @ccall $method(
            data::Ptr{Cvoid},
            UInt32(subject)::UInt32,
            (owned_key === nothing ? C_NULL : pointer(owned_key))::Cstring,
            (owned_type === nothing ? C_NULL : pointer(owned_type))::Cstring,
            (owned_value === nothing ? C_NULL : pointer(owned_value))::Cstring,
        )::Cint
    end
    _check_result(:pw_metadata_set_property, result)
    return object
end

"""
    clear!(metadata)

Clear all entries from a PipeWire metadata store and return `metadata`.
"""
function clear!(object::Metadata)
    result = _with_metadata_method(object, :clear) do data, method
        @ccall $method(data::Ptr{Cvoid})::Cint
    end
    _check_result(:pw_metadata_clear, result)
    return object
end

"""
    get_permissions!(client; index=0, count=typemax(UInt32))

Request a range of client permissions. Results arrive through the client's
`on_permissions` callback. Return `client`.
"""
function get_permissions!(
    client::Client;
    index::Integer=0,
    count::Integer=typemax(UInt32),
)
    result = _with_object_handle(client, LibPipeWire.pw_client) do handle
        LibPipeWire.pw_client_get_permissions(handle, UInt32(index), UInt32(count))
    end
    _check_result(:pw_client_get_permissions, result)
    return client
end

"""
    update_properties!(client, properties)

Update a client's PipeWire properties and return `client`.
"""
function update_properties!(client::Client, properties)
    result = _with_properties_dict(properties) do dictionary
        _with_object_handle(client, LibPipeWire.pw_client) do handle
            LibPipeWire.pw_client_update_properties(handle, dictionary)
        end
    end
    _check_result(:pw_client_update_properties, result)
    return client
end

function _native_permissions(permissions)
    return LibPipeWire.pw_permission[
        permission isa Permission ?
        LibPipeWire.pw_permission(permission.id, permission.permissions) :
        LibPipeWire.pw_permission(UInt32(first(permission)), UInt32(last(permission)))
        for permission in permissions
    ]
end

"""
    update_permissions!(client, permissions)

Update a client's global-object permissions and return `client`. Each entry may
be a [`Permission`](@ref) or an `id => mask` pair.
"""
function update_permissions!(client::Client, permissions)
    native = _native_permissions(permissions)
    result = GC.@preserve native _with_object_handle(client, LibPipeWire.pw_client) do handle
        LibPipeWire.pw_client_update_permissions(handle, UInt32(length(native)), pointer(native))
    end
    _check_result(:pw_client_update_permissions, result)
    return client
end
