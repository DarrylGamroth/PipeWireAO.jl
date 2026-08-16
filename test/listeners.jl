using PipeWireAO
using Test

struct ListenerInfoCounter
    count::Base.RefValue{Int}
end

(callback::ListenerInfoCounter)(::CoreConnection, ::CoreInfo) =
    (callback.count[] += 1; nothing)

struct ListenerGlobalCounter
    count::Base.RefValue{Int}
end

(callback::ListenerGlobalCounter)(::Registry, ::Global) =
    (callback.count[] += 1; nothing)

function invoke_listener_ping(listener::T) where {T<:ManagedListener}
    ccall(
        getfield(listener, :events)[].ping,
        Cvoid,
        (Ref{T}, UInt32, Cint),
        listener,
        UInt32(31),
        Cint(32),
    )
    return nothing
end

function listener_ping_allocations(listener)
    invoke_listener_ping(listener)
    return @allocated invoke_listener_ping(listener)
end

function invoke_listener_core_events(listener::T) where {T<:ManagedListener}
    events = getfield(listener, :events)[]
    detail = "listener core error"
    GC.@preserve listener detail begin
        ccall(
            events.done,
            Cvoid,
            (Ref{T}, UInt32, Cint),
            listener,
            UInt32(33),
            Cint(34),
        )
        ccall(
            events.error,
            Cvoid,
            (Ref{T}, UInt32, Cint, Cint, Cstring),
            listener,
            UInt32(35),
            Cint(36),
            Cint(-37),
            pointer(detail),
        )
        ccall(events.remove_id, Cvoid, (Ref{T}, UInt32), listener, UInt32(38))
        ccall(
            events.bound_id,
            Cvoid,
            (Ref{T}, UInt32, UInt32),
            listener,
            UInt32(39),
            UInt32(40),
        )
        ccall(
            events.add_mem,
            Cvoid,
            (Ref{T}, UInt32, UInt32, Cint, UInt32),
            listener,
            UInt32(41),
            UInt32(42),
            Cint(43),
            UInt32(44),
        )
        ccall(events.remove_mem, Cvoid, (Ref{T}, UInt32), listener, UInt32(45))
        ccall(
            events.bound_props,
            Cvoid,
            (Ref{T}, UInt32, UInt32, Ptr{PipeWireAO.LibPipeWire.spa_dict}),
            listener,
            UInt32(46),
            UInt32(47),
            C_NULL,
        )
    end
    return nothing
end

function invoke_listener_stream_process(listener::T) where {T<:ManagedListener}
    ccall(getfield(listener, :events)[].process, Cvoid, (Ref{T},), listener)
    return nothing
end

function listener_stream_allocations(listener)
    invoke_listener_stream_process(listener)
    return @allocated invoke_listener_stream_process(listener)
end

function invoke_listener_stream_events(
    listener::T,
    control::Ptr{PipeWireAO.LibPipeWire.pw_stream_control},
    param::Pod,
    command::Pod,
) where {T<:ManagedListener}
    events = getfield(listener, :events)[]
    detail = "listener stream state"
    buffer = Ptr{PipeWireAO.LibPipeWire.pw_buffer}(UInt(0x5678))
    GC.@preserve listener detail param command begin
        ccall(
            events.state_changed,
            Cvoid,
            (Ref{T}, Int32, Int32, Cstring),
            listener,
            Int32(1),
            Int32(2),
            pointer(detail),
        )
        ccall(
            events.control_info,
            Cvoid,
            (Ref{T}, UInt32, Ptr{PipeWireAO.LibPipeWire.pw_stream_control}),
            listener,
            UInt32(3),
            control,
        )
        ccall(
            events.io_changed,
            Cvoid,
            (Ref{T}, UInt32, Ptr{Cvoid}, UInt32),
            listener,
            UInt32(4),
            Ptr{Cvoid}(UInt(0x1234)),
            UInt32(64),
        )
        ccall(
            events.param_changed,
            Cvoid,
            (Ref{T}, UInt32, Ptr{PipeWireAO.LibPipeWire.spa_pod}),
            listener,
            UInt32(5),
            PipeWireAO._pod_pointer(param),
        )
        ccall(
            events.add_buffer,
            Cvoid,
            (Ref{T}, Ptr{PipeWireAO.LibPipeWire.pw_buffer}),
            listener,
            buffer,
        )
        ccall(
            events.remove_buffer,
            Cvoid,
            (Ref{T}, Ptr{PipeWireAO.LibPipeWire.pw_buffer}),
            listener,
            buffer,
        )
        ccall(events.drained, Cvoid, (Ref{T},), listener)
        ccall(
            events.command,
            Cvoid,
            (Ref{T}, Ptr{PipeWireAO.LibPipeWire.spa_command}),
            listener,
            Ptr{PipeWireAO.LibPipeWire.spa_command}(PipeWireAO._pod_pointer(command)),
        )
        ccall(events.trigger_done, Cvoid, (Ref{T},), listener)
    end
    return nothing
end

function invoke_listener_filter_process(listener::T) where {T<:ManagedListener}
    ccall(
        getfield(listener, :events)[].process,
        Cvoid,
        (Ref{T}, Ptr{PipeWireAO.LibPipeWire.spa_io_position}),
        listener,
        C_NULL,
    )
    return nothing
end

function listener_filter_allocations(listener)
    invoke_listener_filter_process(listener)
    return @allocated invoke_listener_filter_process(listener)
end

function invoke_listener_filter_events(
    listener::T,
    param::Pod,
    command::Pod,
) where {T<:ManagedListener}
    events = getfield(listener, :events)[]
    detail = "listener filter state"
    buffer = Ptr{PipeWireAO.LibPipeWire.pw_buffer}(UInt(0x9abc))
    GC.@preserve listener detail param command begin
        ccall(
            events.state_changed,
            Cvoid,
            (Ref{T}, Int32, Int32, Cstring),
            listener,
            Int32(6),
            Int32(7),
            pointer(detail),
        )
        ccall(
            events.io_changed,
            Cvoid,
            (Ref{T}, Ptr{Cvoid}, UInt32, Ptr{Cvoid}, UInt32),
            listener,
            C_NULL,
            UInt32(8),
            Ptr{Cvoid}(UInt(0x2345)),
            UInt32(128),
        )
        ccall(
            events.param_changed,
            Cvoid,
            (Ref{T}, Ptr{Cvoid}, UInt32, Ptr{PipeWireAO.LibPipeWire.spa_pod}),
            listener,
            C_NULL,
            UInt32(9),
            PipeWireAO._pod_pointer(param),
        )
        ccall(
            events.add_buffer,
            Cvoid,
            (Ref{T}, Ptr{Cvoid}, Ptr{PipeWireAO.LibPipeWire.pw_buffer}),
            listener,
            C_NULL,
            buffer,
        )
        ccall(
            events.remove_buffer,
            Cvoid,
            (Ref{T}, Ptr{Cvoid}, Ptr{PipeWireAO.LibPipeWire.pw_buffer}),
            listener,
            C_NULL,
            buffer,
        )
        ccall(events.drained, Cvoid, (Ref{T},), listener)
        ccall(
            events.command,
            Cvoid,
            (Ref{T}, Ptr{PipeWireAO.LibPipeWire.spa_command}),
            listener,
            Ptr{PipeWireAO.LibPipeWire.spa_command}(PipeWireAO._pod_pointer(command)),
        )
    end
    return nothing
end

function invoke_listener_bound(listener::T, id::UInt32) where {T<:ManagedListener}
    ccall(
        getfield(listener, :events)[].bound,
        Cvoid,
        (Ref{T}, UInt32),
        listener,
        id,
    )
    return nothing
end

function invoke_listener_global_removed(listener::T, id::UInt32) where {T<:ManagedListener}
    ccall(
        getfield(listener, :events)[].global_remove,
        Cvoid,
        (Ref{T}, UInt32),
        listener,
        id,
    )
    return nothing
end

function invoke_listener_proxy_destroyed(listener::T) where {T<:ManagedListener}
    ccall(getfield(listener, :events)[].destroy, Cvoid, (Ref{T},), listener)
    return nothing
end

function invoke_listener_proxy_events(listener::T) where {T<:ManagedListener}
    events = getfield(listener, :events)[]
    detail = "listener proxy error"
    GC.@preserve listener detail begin
        ccall(events.removed, Cvoid, (Ref{T},), listener)
        ccall(events.done, Cvoid, (Ref{T}, Cint), listener, Cint(61))
        ccall(
            events.error,
            Cvoid,
            (Ref{T}, Cint, Cint, Cstring),
            listener,
            Cint(62),
            Cint(-63),
            pointer(detail),
        )
        ccall(
            events.bound_props,
            Cvoid,
            (Ref{T}, UInt32, Ptr{PipeWireAO.LibPipeWire.spa_dict}),
            listener,
            UInt32(64),
            C_NULL,
        )
    end
    return nothing
end

function invoke_listener_profile(listener::T, profile::Pod) where {T<:ManagedListener}
    GC.@preserve listener profile ccall(
        getfield(listener, :events)[].profile,
        Cvoid,
        (Ref{T}, Ptr{PipeWireAO.LibPipeWire.spa_pod}),
        listener,
        PipeWireAO._pod_pointer(profile),
    )
    return nothing
end

@testset "composable managed listeners" begin
    context = Context()
    enable_profiler!(context)
    primary_infos = Ref(0)
    core = CoreConnection(
        context;
        self=true,
        on_info=(core, info) -> (primary_infos[] += 1),
    )
    roundtrip(core)
    primary_infos[] = 0

    first_infos = Ref(0)
    second_infos = Ref(0)
    ping = Ref((UInt32(0), Cint(0)))
    core_done = Tuple{UInt32,Cint}[]
    core_errors = Tuple{UInt32,Cint,PipeWireError}[]
    removed_ids = UInt32[]
    bound_ids = Tuple{UInt32,UInt32}[]
    added_memory = CoreMemory[]
    removed_memory = UInt32[]
    bound_properties = Tuple{UInt32,UInt32,Dict{String,String}}[]
    first_listener = add_listener!(
        core;
        on_info=ListenerInfoCounter(first_infos),
        on_ping=PingRecorder(ping),
        on_done=(core, id, sequence) -> push!(core_done, (id, sequence)),
        on_error=(core, id, sequence, error) ->
            push!(core_errors, (id, sequence, error)),
        on_remove_id=(core, id) -> push!(removed_ids, id),
        on_bound_id=(core, id, global_id) -> push!(bound_ids, (id, global_id)),
        on_add_memory=(core, memory) -> push!(added_memory, memory),
        on_remove_memory=(core, id) -> push!(removed_memory, id),
        on_bound_properties=(core, id, global_id, properties) ->
            push!(bound_properties, (id, global_id, properties)),
    )
    second_listener = add_listener!(core; on_info=ListenerInfoCounter(second_infos))
    @test isconcretetype(typeof(first_listener))
    @test all(isconcretetype, fieldtypes(typeof(first_listener)))
    @test isopen(first_listener)
    @test listener_ping_allocations(first_listener) == 0
    @test ping[] == (UInt32(31), Cint(32))
    invoke_listener_core_events(first_listener)
    @test core_done == [(UInt32(33), Cint(34))]
    @test length(core_errors) == 1
    @test core_errors[1][1:2] == (UInt32(35), Cint(36))
    @test core_errors[1][3].operation == :pw_core
    @test core_errors[1][3].code == -37
    @test core_errors[1][3].detail == "listener core error"
    @test removed_ids == UInt32[38]
    @test bound_ids == [(UInt32(39), UInt32(40))]
    @test added_memory == [CoreMemory(UInt32(41), UInt32(42), Cint(43), UInt32(44))]
    @test removed_memory == UInt32[45]
    @test bound_properties == [
        (UInt32(46), UInt32(47), Dict{String,String}()),
    ]

    hello!(core)
    roundtrip(core)
    @test primary_infos[] == 1
    @test first_infos[] == 1
    @test second_infos[] == 1

    close(first_listener)
    @test !isopen(first_listener)
    close(first_listener)
    hello!(core)
    roundtrip(core)
    @test primary_infos[] == 2
    @test first_infos[] == 1
    @test second_infos[] == 2

    registry_events = Ref(0)
    removed_globals = UInt32[]
    registry = Registry(core)
    registry_listener = add_listener!(
        registry;
        on_global_added=ListenerGlobalCounter(registry_events),
        on_global_removed=(registry, id) -> push!(removed_globals, id),
    )
    roundtrip(registry)
    invoke_listener_global_removed(registry_listener, UInt32(48))
    @test registry_events[] > 0
    @test removed_globals == UInt32[48]
    @test isconcretetype(typeof(registry_listener))
    @test all(isconcretetype, fieldtypes(typeof(registry_listener)))

    factory_global = first(
        global_object for global_object in globals(registry) if
        global_object.type == "PipeWire:Interface:Factory"
    )
    proxy = bind(registry, factory_global)
    bound = Ref(UInt32(0))
    proxy_destroyed = Ref(0)
    proxy_removed = Ref(0)
    proxy_done = Cint[]
    proxy_errors = Tuple{Cint,PipeWireError}[]
    proxy_properties = Tuple{UInt32,Dict{String,String}}[]
    proxy_listener = add_listener!(
        proxy;
        on_destroyed=proxy -> (proxy_destroyed[] += 1),
        on_bound=(proxy, id) -> (bound[] = id),
        on_removed=proxy -> (proxy_removed[] += 1),
        on_done=(proxy, sequence) -> push!(proxy_done, sequence),
        on_error=(proxy, sequence, error) -> push!(proxy_errors, (sequence, error)),
        on_bound_properties=(proxy, id, properties) ->
            push!(proxy_properties, (id, properties)),
    )
    invoke_listener_bound(proxy_listener, factory_global.id)
    invoke_listener_proxy_events(proxy_listener)
    @test bound[] == factory_global.id
    @test proxy_removed[] == 1
    @test proxy_done == [Cint(61)]
    @test length(proxy_errors) == 1
    @test proxy_errors[1][1] == 62
    @test proxy_errors[1][2].operation == :pw_proxy
    @test proxy_errors[1][2].code == -63
    @test proxy_errors[1][2].detail == "listener proxy error"
    @test proxy_properties == [(UInt32(64), Dict{String,String}())]
    close(proxy_listener)
    invoke_listener_proxy_destroyed(proxy_listener)
    @test proxy_destroyed[] == 0
    @test !isopen(proxy_listener)
    close(proxy)

    metadata_global = only(
        global_object for global_object in globals(registry) if
        global_object.type == "PipeWire:Interface:Metadata"
    )
    metadata = bind(registry, metadata_global, Metadata)
    properties = Tuple{UInt32,Union{Nothing,String},Union{Nothing,String},Union{Nothing,String}}[]
    metadata_listener = add_listener!(
        metadata;
        on_property=(metadata, subject, key, type, value) ->
            push!(properties, (subject, key, type, value)),
    )
    set_property!(
        metadata,
        0,
        "pipewire.jl.listener";
        type="Spa:String:JSON",
        value="true",
    )
    roundtrip(metadata)
    @test properties[end] ==
          (UInt32(0), "pipewire.jl.listener", "Spa:String:JSON", "true")
    close(metadata_listener)
    set_property!(metadata, 0, "pipewire.jl.listener")
    roundtrip(metadata)
    @test properties[end] ==
          (UInt32(0), "pipewire.jl.listener", "Spa:String:JSON", "true")
    close(metadata)

    profiler_global = only(
        global_object for global_object in globals(registry) if
        global_object.type == "PipeWire:Interface:Profiler"
    )
    profiler = bind(registry, profiler_global, Profiler)
    profiles = Pod[]
    profiler_listener = add_listener!(
        profiler;
        on_profile=(profiler, profile) -> push!(profiles, profile),
    )
    sample_profile = Pod(Int64(73))
    invoke_listener_profile(profiler_listener, sample_profile)
    @test pod_value(Int64, only(profiles)) == 73
    close(profiler_listener)
    close(profiler)

    stream_processes = Ref(0)
    stream_destroyed = Ref(0)
    stream_states = Tuple{Int32,Int32,Union{Nothing,String}}[]
    stream_controls = Tuple{UInt32,Union{Nothing,StreamControl}}[]
    stream_ios = StreamIO[]
    stream_params = Tuple{UInt32,Union{Nothing,Pod}}[]
    stream_added_buffers = Ptr{PipeWireAO.LibPipeWire.pw_buffer}[]
    stream_removed_buffers = Ptr{PipeWireAO.LibPipeWire.pw_buffer}[]
    stream_commands = Pod[]
    stream_drained = Ref(0)
    stream_triggered = Ref(0)
    stream = Stream(core, "listener stream")
    stream_listener = add_listener!(
        stream;
        on_state_changed=(stream, old, current, detail) ->
            push!(stream_states, (old, current, detail)),
        on_control_info=(stream, id, control) ->
            push!(stream_controls, (id, control)),
        on_io_changed=(stream, io) -> push!(stream_ios, io),
        on_param_changed=(stream, id, param) ->
            push!(stream_params, (id, param)),
        on_buffer_added=(stream, buffer) -> push!(stream_added_buffers, buffer),
        on_buffer_removed=(stream, buffer) -> push!(stream_removed_buffers, buffer),
        on_process=CountProcess(stream_processes),
        on_drained=stream -> (stream_drained[] += 1),
        on_command=(stream, command) -> push!(stream_commands, command),
        on_trigger_done=stream -> (stream_triggered[] += 1),
        on_destroyed=stream -> (stream_destroyed[] += 1),
    )
    @test listener_stream_allocations(stream_listener) == 0
    @test stream_processes[] == 2

    control_name = "Listener Volume"
    control_values = Float32[0.25, 0.75]
    native_control = Ref(
        PipeWireAO.LibPipeWire.pw_stream_control(
            pointer(control_name),
            UInt32(0),
            0.5f0,
            0.0f0,
            1.0f0,
            pointer(control_values),
            UInt32(length(control_values)),
            UInt32(12),
        ),
    )
    stream_param = Pod(Int32(41))
    stream_command = Pod(Int32(42))
    GC.@preserve control_name control_values native_control begin
        invoke_listener_stream_events(
            stream_listener,
            Base.unsafe_convert(
                Ptr{PipeWireAO.LibPipeWire.pw_stream_control},
                native_control,
            ),
            stream_param,
            stream_command,
        )
    end
    @test stream_states == [(Int32(1), Int32(2), "listener stream state")]
    @test stream_controls == [
        (
            UInt32(3),
            StreamControl(
                "Listener Volume",
                UInt32(0),
                0.5f0,
                0.0f0,
                1.0f0,
                control_values,
                12,
            ),
        ),
    ]
    @test stream_ios == [StreamIO(UInt32(4), Ptr{Cvoid}(UInt(0x1234)), UInt32(64))]
    @test length(stream_params) == 1
    @test stream_params[1][1] == 5
    @test pod_value(Int32, something(stream_params[1][2])) == 41
    @test stream_added_buffers == [Ptr{PipeWireAO.LibPipeWire.pw_buffer}(UInt(0x5678))]
    @test stream_removed_buffers == stream_added_buffers
    @test stream_drained[] == 1
    @test pod_value(Int32, only(stream_commands)) == 42
    @test stream_triggered[] == 1
    close(stream)
    @test stream_destroyed[] == 1
    @test !isopen(stream_listener)
    close(stream_listener)

    filter_processes = Ref(0)
    filter_destroyed = Ref(0)
    filter_states = Tuple{Int32,Int32,Union{Nothing,String}}[]
    filter_ios = Tuple{Any,FilterIO}[]
    filter_params = Tuple{Any,UInt32,Union{Nothing,Pod}}[]
    filter_added_buffers = Tuple{Any,Ptr{PipeWireAO.LibPipeWire.pw_buffer}}[]
    filter_removed_buffers = Tuple{Any,Ptr{PipeWireAO.LibPipeWire.pw_buffer}}[]
    filter_commands = Pod[]
    filter_drained = Ref(0)
    filter = Filter(core, "listener filter")
    filter_listener = add_listener!(
        filter;
        on_state_changed=(filter, old, current, detail) ->
            push!(filter_states, (old, current, detail)),
        on_io_changed=(filter, port, io) -> push!(filter_ios, (port, io)),
        on_param_changed=(filter, port, id, param) ->
            push!(filter_params, (port, id, param)),
        on_buffer_added=(filter, port, buffer) ->
            push!(filter_added_buffers, (port, buffer)),
        on_buffer_removed=(filter, port, buffer) ->
            push!(filter_removed_buffers, (port, buffer)),
        on_process=FilterProcessRecorder(filter_processes),
        on_drained=filter -> (filter_drained[] += 1),
        on_command=(filter, command) -> push!(filter_commands, command),
        on_destroyed=filter -> (filter_destroyed[] += 1),
    )
    @test listener_filter_allocations(filter_listener) == 0
    @test filter_processes[] == 4
    filter_param = Pod(Int64(51))
    filter_command = Pod(Int64(52))
    invoke_listener_filter_events(filter_listener, filter_param, filter_command)
    @test filter_states == [(Int32(6), Int32(7), "listener filter state")]
    @test filter_ios == [
        (nothing, FilterIO(UInt32(8), Ptr{Cvoid}(UInt(0x2345)), UInt32(128))),
    ]
    @test length(filter_params) == 1
    @test filter_params[1][1] === nothing
    @test filter_params[1][2] == 9
    @test pod_value(Int64, something(filter_params[1][3])) == 51
    @test filter_added_buffers == [
        (nothing, Ptr{PipeWireAO.LibPipeWire.pw_buffer}(UInt(0x9abc))),
    ]
    @test filter_removed_buffers == filter_added_buffers
    @test filter_drained[] == 1
    @test pod_value(Int64, only(filter_commands)) == 52
    close(filter)
    @test filter_destroyed[] == 1
    @test !isopen(filter_listener)
    close(filter_listener)

    close(registry_listener)
    close(registry)
    close(second_listener)
    close(core)
    close(context)
end
