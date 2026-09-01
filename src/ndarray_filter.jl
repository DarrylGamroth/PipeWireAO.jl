const _NDARRAY_FILTER_CALLBACK_ERROR = Cint(-Base.Libc.EFAULT)
const _NDARRAY_FILTER_PARAMETER_BUSY = Cint(-Base.Libc.EBUSY)
const _NDARRAY_FILTER_INVALID_ID = typemax(UInt32)

"The lifecycle state of a standalone [`NdArrayFilter`](@ref)."
@enum NdArrayFilterState::Int32 begin
    NDARRAY_FILTER_STATE_ERROR = LibPipeWire.PW_FILTER_STATE_ERROR
    NDARRAY_FILTER_STATE_UNCONNECTED = LibPipeWire.PW_FILTER_STATE_UNCONNECTED
    NDARRAY_FILTER_STATE_CONNECTING = LibPipeWire.PW_FILTER_STATE_CONNECTING
    NDARRAY_FILTER_STATE_PAUSED = LibPipeWire.PW_FILTER_STATE_PAUSED
    NDARRAY_FILTER_STATE_STREAMING = LibPipeWire.PW_FILTER_STATE_STREAMING
end

"""
    NdArrayFilterPort(name, direction, format;
                      schema=nothing, profile=nothing, parameter=false)

Declare one exact packed-ndarray port for a standalone [`NdArrayFilter`](@ref).
The declaration is copied when the filter is constructed. `schema` identifies
the semantic meaning of the ndarray independently of its element type, shape,
layout, and rate. `profile` identifies the interpretation profile used for
delivery geometry or another schema-specific mapping.

Set `parameter=true` for a sparse input Parameter Port. A Parameter Port must
have input direction and a format without a repeated rate. Its buffers are
prepared by `on_parameter` rather than passed to the repeated process callback.
"""
struct NdArrayFilterPort{N}
    name::String
    direction::Direction
    format::NdArrayFormat{N}
    schema::Union{Nothing,String}
    profile::Union{Nothing,String}
    parameter::Bool
end

function NdArrayFilterPort(
    name::AbstractString,
    direction::Direction,
    format::NdArrayFormat{N};
    schema::Union{Nothing,AbstractString}=nothing,
    profile::Union{Nothing,AbstractString}=nothing,
    parameter::Bool=false,
) where {N}
    port_name = _validate_c_string(String(name), "ndarray filter port name")
    isempty(port_name) && throw(ArgumentError("an ndarray filter port name cannot be empty"))
    semantic_schema = if schema === nothing
        nothing
    else
        value = _validate_c_string(String(schema), "ndarray filter port schema")
        isempty(value) && throw(ArgumentError("an ndarray filter port schema cannot be empty"))
        value
    end
    interpretation_profile = if profile === nothing
        nothing
    else
        value = _validate_c_string(String(profile), "ndarray filter port profile")
        isempty(value) && throw(ArgumentError("an ndarray filter port profile cannot be empty"))
        value
    end
    if parameter
        direction == DIRECTION_INPUT ||
            throw(ArgumentError("an ndarray Parameter Port must be an input"))
        format.rate === nothing ||
            throw(ArgumentError("an ndarray Parameter Port cannot declare a repeated rate"))
    end
    return NdArrayFilterPort{N}(
        port_name,
        direction,
        format,
        semantic_schema,
        interpretation_profile,
        parameter,
    )
end

"""
    NdArrayFilterBuffer

A borrowed ndarray buffer supplied to an [`NdArrayFilter`](@ref) process or
Parameter callback. The buffer and its payload are valid only until that
callback returns. Input buffers are read-only and output buffers are
exclusively writable.
"""
struct NdArrayFilterBuffer{Writable}
    handle::Ptr{Cvoid}
end

"""
    NdArrayFilterBuffers

A direction-specific, borrowed collection of [`NdArrayFilterBuffer`](@ref)
values. Buffers appear in the same direction-local order as their port
declarations.
"""
struct NdArrayFilterBuffers{Writable} <: AbstractVector{NdArrayFilterBuffer{Writable}}
    handle::Ptr{Cvoid}
    count::UInt32
end

Base.size(buffers::NdArrayFilterBuffers) = (Int(buffers.count),)
Base.length(buffers::NdArrayFilterBuffers) = Int(buffers.count)
Base.axes(buffers::NdArrayFilterBuffers) = (Base.OneTo(length(buffers)),)
Base.IndexStyle(::Type{<:NdArrayFilterBuffers}) = IndexLinear()

@inline function Base.getindex(
    buffers::NdArrayFilterBuffers{Writable},
    index::Int,
) where {Writable}
    @boundscheck checkbounds(buffers, index)
    offset = (index - 1) * sizeof(LibPipeWire.pw_ndarray_filter_buffer)
    return NdArrayFilterBuffer{Writable}(buffers.handle + offset)
end

function _native_buffer(buffer::NdArrayFilterBuffer)
    buffer.handle == C_NULL &&
        throw(InvalidStateException("the ndarray callback buffer is unavailable", :unavailable))
    return Ptr{LibPipeWire.pw_ndarray_filter_buffer}(buffer.handle)
end

"Return the borrowed payload pointer for an ndarray callback buffer."
function data_pointer(buffer::NdArrayFilterBuffer)
    pointer = unsafe_load(_native_buffer(buffer).data)
    pointer == C_NULL &&
        throw(InvalidStateException("the ndarray callback payload is unavailable", :unavailable))
    return Ptr{UInt8}(pointer)
end

"Return the declared payload size of an ndarray callback buffer in bytes."
payload_size(buffer::NdArrayFilterBuffer) = Int(unsafe_load(_native_buffer(buffer).size))

"Return the mapped capacity of an ndarray callback buffer in bytes."
capacity(buffer::NdArrayFilterBuffer) = Int(unsafe_load(_native_buffer(buffer).capacity))

"Return a borrowed byte view of an ndarray callback payload."
function bytes(buffer::NdArrayFilterBuffer)
    return UnsafeArray(data_pointer(buffer), (payload_size(buffer),))
end

"Return copied SPA header metadata, or `nothing` when absent or invalid."
function buffer_header(buffer::NdArrayFilterBuffer)
    native = _native_buffer(buffer)
    valid = unsafe_load(native.metadata_valid)
    iszero(valid & LibPipeWire.PW_NDARRAY_FILTER_METADATA_HEADER) && return nothing
    header = unsafe_load(native.header)
    return BufferHeader(
        header.flags,
        header.offset,
        header.pts,
        header.dts_offset,
        header.seq,
    )
end

"""
    set_buffer_header!(buffer, header)

Set valid SPA header metadata on a writable ndarray callback buffer. The
destination buffer must provide header metadata.
"""
function set_buffer_header!(buffer::NdArrayFilterBuffer{true}, header::BufferHeader)
    native = _native_buffer(buffer)
    available = unsafe_load(native.metadata_available)
    iszero(available & LibPipeWire.PW_NDARRAY_FILTER_METADATA_HEADER) && throw(
        InvalidStateException("the ndarray callback buffer has no header metadata", :no_metadata),
    )
    unsafe_store!(
        native.header,
        LibPipeWire.spa_meta_header(
            header.flags,
            header.offset,
            header.pts,
            header.dts_offset,
            header.sequence,
        ),
    )
    unsafe_store!(
        native.metadata_valid,
        unsafe_load(native.metadata_valid) |
        LibPipeWire.PW_NDARRAY_FILTER_METADATA_HEADER,
    )
    return buffer
end

"""
    set_output_available!(buffer, available)

Choose whether the standalone ndarray filter publishes this output after the
current callback. An unavailable output buffer is retained and presented to a
later callback. Outputs are available by default on every callback.
"""
function set_output_available!(buffer::NdArrayFilterBuffer{true}, available::Bool)
    native = _native_buffer(buffer)
    flags = unsafe_load(native.flags)
    unavailable = LibPipeWire.PW_NDARRAY_FILTER_BUFFER_FLAG_OUTPUT_UNAVAILABLE
    unsafe_store!(native.flags, available ? flags & ~unavailable : flags | unavailable)
    return buffer
end

"""
    propagate_metadata!(output, input)

Copy valid standard metadata from an input callback buffer to an output
callback buffer when the corresponding destination records are available.
"""
function propagate_metadata!(
    output::NdArrayFilterBuffer{true},
    input::NdArrayFilterBuffer{false},
)
    native_output = _native_buffer(output)
    native_input = _native_buffer(input)
    valid = unsafe_load(native_input.metadata_valid) &
            unsafe_load(native_output.metadata_available)
    unsafe_store!(native_output.metadata_valid, valid)
    if !iszero(valid & LibPipeWire.PW_NDARRAY_FILTER_METADATA_HEADER)
        unsafe_store!(native_output.header, unsafe_load(native_input.header))
    end
    if !iszero(valid & LibPipeWire.PW_NDARRAY_FILTER_METADATA_ACQUISITION)
        unsafe_store!(native_output.acquisition, unsafe_load(native_input.acquisition))
    end
    return output
end

"""
    NdArrayFilter(name, ports; remote=nothing, on_prepare=nothing,
                  on_process, on_parameter=nothing, on_deactivate=nothing)

Create an unconnected PipeWire node with exact packed-ndarray ports. The
callbacks are ordinary Julia callables:

- `on_prepare(filter)` runs on the process thread before its first frame and
  may perform warmup, compilation, allocation, and page touching.
- `on_process(filter, inputs, outputs)` receives borrowed direction-local
  frame-data buffer collections. Parameter Ports are excluded. It must not
  retain them after returning.
- `on_parameter(filter, input_port, parameter)` runs on an owned serial worker
  for a sparse Parameter Port. `input_port` is its one-based direction-local
  input index. The callback may allocate and block while copying or preparing
  a replacement, but it must not retain the borrowed buffer. It returns `true`
  when accepted or `false` to retain and retry the buffer after a later
  data-loop cycle. It may overlap `on_process`.
- `on_deactivate(filter)` runs after processing has stopped.

`on_parameter` is required when any declaration has `parameter=true`.

Callback exceptions are contained at the C boundary and rethrown by
[`run!`](@ref). The warmed successful process path introduces no locks or
allocations in this wrapper. `@cfunction` automatically adopts the PipeWire
callback thread before entering Julia. No exception is permitted to escape
back into C; an exceptional callback is contained, terminates processing, and
is reported by `run!`. This API does not by itself claim hard-real-time Julia
execution.

Call [`close`](@ref) explicitly on the same Julia thread that constructed the
filter. Construction, connection, running, and destruction are thread-affine;
only [`quit!`](@ref) may be called from another thread.
"""
mutable struct NdArrayFilter{Callbacks}
    handle::Ptr{Cvoid}
    name::String
    callbacks::Callbacks
    callback_error::Base.RefValue{Any}
    state_lock::ReentrantLock
    owner_thread::Int
    connected::Bool
    running::Bool
end

function _record_ndarray_filter_callback_error(filter::NdArrayFilter, error)
    lock(filter.state_lock) do
        filter.callback_error[] === nothing && (filter.callback_error[] = error)
    end
    return nothing
end

function _ndarray_filter_update_parameter(
    filter::NdArrayFilter,
    input_port::UInt32,
    parameter::Ptr{LibPipeWire.pw_ndarray_filter_buffer},
)::Cint
    try
        accepted = filter.callbacks.on_parameter(
            filter,
            Int(input_port) + 1,
            NdArrayFilterBuffer{false}(Ptr{Cvoid}(parameter)),
        )
        accepted isa Bool || throw(
            ArgumentError("an ndarray Parameter callback must return Bool"),
        )
        return accepted ? Cint(0) : _NDARRAY_FILTER_PARAMETER_BUSY
    catch error
        _record_ndarray_filter_callback_error(filter, error)
        return _NDARRAY_FILTER_CALLBACK_ERROR
    end
end

function _ndarray_filter_prepare(filter::NdArrayFilter)::Cint
    try
        callback = filter.callbacks.on_prepare
        callback === nothing || callback(filter)
        return Cint(0)
    catch error
        _record_ndarray_filter_callback_error(filter, error)
        return _NDARRAY_FILTER_CALLBACK_ERROR
    end
end

function _ndarray_filter_process(
    filter::NdArrayFilter,
    inputs::Ptr{LibPipeWire.pw_ndarray_filter_buffer},
    n_inputs::UInt32,
    outputs::Ptr{LibPipeWire.pw_ndarray_filter_buffer},
    n_outputs::UInt32,
)::Cint
    try
        filter.callbacks.on_process(
            filter,
            NdArrayFilterBuffers{false}(Ptr{Cvoid}(inputs), n_inputs),
            NdArrayFilterBuffers{true}(Ptr{Cvoid}(outputs), n_outputs),
        )
        return Cint(0)
    catch error
        _record_ndarray_filter_callback_error(filter, error)
        return _NDARRAY_FILTER_CALLBACK_ERROR
    end
end

function _ndarray_filter_deactivate(filter::NdArrayFilter)::Cint
    try
        callback = filter.callbacks.on_deactivate
        callback === nothing || callback(filter)
        return Cint(0)
    catch error
        _record_ndarray_filter_callback_error(filter, error)
        return _NDARRAY_FILTER_CALLBACK_ERROR
    end
end

function _ndarray_filter_events(::T) where {T<:NdArrayFilter}
    prepare = @cfunction(_ndarray_filter_prepare, Cint, (Ref{T},))
    process = @cfunction(
        _ndarray_filter_process,
        Cint,
        (
            Ref{T},
            Ptr{LibPipeWire.pw_ndarray_filter_buffer},
            UInt32,
            Ptr{LibPipeWire.pw_ndarray_filter_buffer},
            UInt32,
        ),
    )
    deactivate = @cfunction(_ndarray_filter_deactivate, Cint, (Ref{T},))
    update_parameter = @cfunction(
        _ndarray_filter_update_parameter,
        Cint,
        (Ref{T}, UInt32, Ptr{LibPipeWire.pw_ndarray_filter_buffer}),
    )
    return LibPipeWire.pw_ndarray_filter_events(
        UInt32(1),
        prepare,
        process,
        deactivate,
        update_parameter,
    )
end

function _native_ndarray_filter_ports(ports::Vector{NdArrayFilterPort})
    names = getfield.(ports, :name)
    schemas = getfield.(ports, :schema)
    profiles = getfield.(ports, :profile)
    shapes = Vector{Vector{UInt32}}(undef, length(ports))
    native = Vector{LibPipeWire.pw_ndarray_filter_port}(undef, length(ports))
    for index in eachindex(ports)
        shapes[index] = collect(UInt32, ports[index].format.shape)
    end
    GC.@preserve names schemas profiles shapes begin
        for index in eachindex(ports)
            port = ports[index]
            format = port.format
            rate_num, rate_denom = format.rate === nothing ?
                (UInt32(0), UInt32(0)) : (format.rate.num, format.rate.denom)
            schema = schemas[index]
            profile = profiles[index]
            flags = port.parameter ?
                LibPipeWire.PW_NDARRAY_FILTER_PORT_FLAG_PARAMETER : UInt32(0)
            native[index] = LibPipeWire.pw_ndarray_filter_port(
                UInt32(sizeof(LibPipeWire.pw_ndarray_filter_port)),
                flags,
                UInt32(port.direction),
                UInt32(0),
                pointer(names[index]),
                LibPipeWire.pw_ndarray_filter_format(
                    UInt32(format.element_type),
                    UInt32(format.layout),
                    rate_num,
                    rate_denom,
                    UInt32(length(shapes[index])),
                    pointer(shapes[index]),
                    schema === nothing ? C_NULL : pointer(schema),
                    profile === nothing ? C_NULL : pointer(profile),
                ),
            )
        end
    end
    return (; names, schemas, profiles, shapes, native)
end

function NdArrayFilter(
    name::AbstractString,
    port_declarations;
    remote::Union{Nothing,AbstractString}=nothing,
    on_prepare=nothing,
    on_process,
    on_parameter=nothing,
    on_deactivate=nothing,
)
    node_name = _validate_c_string(String(name), "ndarray filter name")
    isempty(node_name) && throw(ArgumentError("an ndarray filter name cannot be empty"))
    remote_name = if remote === nothing
        nothing
    else
        value = _validate_c_string(String(remote), "ndarray filter remote name")
        isempty(value) && throw(ArgumentError("an ndarray filter remote name cannot be empty"))
        value
    end
    ports = NdArrayFilterPort[port for port in port_declarations]
    isempty(ports) && throw(ArgumentError("an ndarray filter must declare at least one port"))
    any(port -> port.parameter, ports) && on_parameter === nothing && throw(
        ArgumentError("on_parameter is required for an ndarray Parameter Port"),
    )
    callbacks = (; on_prepare, on_process, on_parameter, on_deactivate)
    filter = NdArrayFilter(
        Ptr{Cvoid}(C_NULL),
        node_name,
        callbacks,
        Ref{Any}(nothing),
        ReentrantLock(),
        Threads.threadid(),
        false,
        false,
    )
    storage = _native_ndarray_filter_ports(ports)
    events = [_ndarray_filter_events(filter)]
    result = Ref{Ptr{LibPipeWire.pw_ndarray_filter}}(C_NULL)
    GC.@preserve filter storage events node_name remote_name begin
        config = Ref(
            LibPipeWire.pw_ndarray_filter_config(
                UInt32(sizeof(LibPipeWire.pw_ndarray_filter_config)),
                UInt32(0),
                pointer(node_name),
                remote_name === nothing ? C_NULL : pointer(remote_name),
                UInt32(length(storage.native)),
                LibPipeWire.PW_NDARRAY_FILTER_FLAG_RT_PROCESS,
                pointer(storage.native),
                pointer(events),
                pointer_from_objref(filter),
            ),
        )
        _check_result(:pw_ndarray_filter_new, LibPipeWire.pw_ndarray_filter_new(config, result))
    end
    result[] == C_NULL && throw(
        PipeWireError(
            :pw_ndarray_filter_new,
            Cint(-Base.Libc.EFAULT),
            "the native endpoint returned no filter",
        ),
    )
    filter.handle = Ptr{Cvoid}(result[])
    return filter
end

function _require_open(filter::NdArrayFilter)
    filter.handle == C_NULL &&
        throw(InvalidStateException("the ndarray filter is closed", :closed))
    return Ptr{LibPipeWire.pw_ndarray_filter}(filter.handle)
end

function _require_owner_thread(filter::NdArrayFilter, operation::AbstractString)
    Threads.threadid() == filter.owner_thread || throw(
        InvalidStateException(
            "$operation must run on the Julia thread that constructed the ndarray filter",
            :thread_affinity,
        ),
    )
    return nothing
end

Base.isopen(filter::NdArrayFilter) = lock(filter.state_lock) do
    filter.handle != C_NULL
end

isrunning(filter::NdArrayFilter) = lock(filter.state_lock) do
    filter.running
end

"Return the name copied into an ndarray filter at construction."
filter_name(filter::NdArrayFilter) = filter.name

"Connect an ndarray filter to its configured PipeWire remote."
function connect!(filter::NdArrayFilter)
    result = lock(filter.state_lock) do
        _require_owner_thread(filter, "connect!")
        filter.connected && throw(
            InvalidStateException("the ndarray filter is already connected", :connected),
        )
        result = LibPipeWire.pw_ndarray_filter_connect(_require_open(filter))
        result >= 0 && (filter.connected = true)
        result
    end
    _check_result(:pw_ndarray_filter_connect, result)
    return filter
end

"Run an ndarray filter until another task or thread calls [`quit!`](@ref)."
function run!(filter::NdArrayFilter)
    handle = lock(filter.state_lock) do
        _require_owner_thread(filter, "run!")
        filter.connected || throw(
            InvalidStateException("the ndarray filter is not connected", :unconnected),
        )
        filter.running &&
            throw(InvalidStateException("the ndarray filter is already running", :running))
        filter.running = true
        _require_open(filter)
    end
    result = try
        LibPipeWire.pw_ndarray_filter_run(handle)
    finally
        lock(filter.state_lock) do
            filter.running = false
        end
    end
    callback_error = lock(filter.state_lock) do
        filter.callback_error[]
    end
    callback_error === nothing || throw(callback_error)
    _check_result(:pw_ndarray_filter_run, result)
    return filter
end

"Request termination of an ndarray filter's main loop from any Julia thread."
function quit!(filter::NdArrayFilter)
    result = lock(filter.state_lock) do
        LibPipeWire.pw_ndarray_filter_quit(_require_open(filter))
    end
    _check_result(:pw_ndarray_filter_quit, result)
    return filter
end

"Return the most recently observed ndarray-filter lifecycle state."
function filter_state(filter::NdArrayFilter)
    value = lock(filter.state_lock) do
        LibPipeWire.pw_ndarray_filter_get_state(_require_open(filter))
    end
    return NdArrayFilterState(value)
end

"Return the first native asynchronous error, or `nothing` when none exists."
function last_error(filter::NdArrayFilter)
    value = lock(filter.state_lock) do
        LibPipeWire.pw_ndarray_filter_get_error(_require_open(filter))
    end
    return value == 0 ? nothing : PipeWireError(:pw_ndarray_filter, value)
end

"Return the published node ID, or `nothing` before registration."
function node_id(filter::NdArrayFilter)
    value = lock(filter.state_lock) do
        LibPipeWire.pw_ndarray_filter_get_node_id(_require_open(filter))
    end
    return value == _NDARRAY_FILTER_INVALID_ID ? nothing : value
end

function Base.close(filter::NdArrayFilter)
    handle = lock(filter.state_lock) do
        _require_owner_thread(filter, "close")
        filter.handle == C_NULL && return Ptr{LibPipeWire.pw_ndarray_filter}(C_NULL)
        filter.running && throw(
            InvalidStateException(
                "cannot close a running ndarray filter; call quit! and wait for run!",
                :running,
            ),
        )
        handle = Ptr{LibPipeWire.pw_ndarray_filter}(filter.handle)
        filter.handle = Ptr{Cvoid}(C_NULL)
        filter.connected = false
        handle
    end
    handle == C_NULL && return nothing
    LibPipeWire.pw_ndarray_filter_destroy(handle)
    return nothing
end
