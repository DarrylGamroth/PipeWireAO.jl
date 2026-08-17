using PipeWireAO
using Test

include("aqua.jl")
include("current_info.jl")
include("object_callbacks.jl")

struct CountProcess
    count::Base.RefValue{Int}
end

(callback::CountProcess)(::Stream) = (callback.count[] += 1)

struct PingRecorder
    value::Base.RefValue{Tuple{UInt32,Cint}}
end

(callback::PingRecorder)(::CoreConnection, id::UInt32, sequence::Cint) =
    (callback.value[] = (id, sequence); nothing)

struct IdRecorder
    value::Base.RefValue{UInt32}
end

(callback::IdRecorder)(::CoreConnection, id::UInt32) =
    (callback.value[] = id; nothing)

struct BoundIdRecorder
    value::Base.RefValue{Tuple{UInt32,UInt32}}
end

(callback::BoundIdRecorder)(::CoreConnection, id::UInt32, global_id::UInt32) =
    (callback.value[] = (id, global_id); nothing)

struct MemoryRecorder
    value::Base.RefValue{CoreMemory}
end

(callback::MemoryRecorder)(::CoreConnection, memory::CoreMemory) =
    (callback.value[] = memory; nothing)

struct BoundPropertiesRecorder
    value::Base.RefValue{Tuple{UInt32,UInt32,Dict{String,String}}}
end

function (callback::BoundPropertiesRecorder)(
    ::CoreConnection,
    id::UInt32,
    global_id::UInt32,
    properties::Dict{String,String},
)
    callback.value[] = (id, global_id, properties)
    return nothing
end

function invoke_process_callback(stream::T) where {T<:Stream}
    ccall(stream.events[].process, Cvoid, (Ref{T},), stream)
    return nothing
end

function invoke_stream_extended_callbacks(
    stream::T,
    control::Ptr{PipeWireAO.LibPipeWire.pw_stream_control},
    command::Ptr{PipeWireAO.LibPipeWire.spa_command},
) where {T<:Stream}
    events = getfield(stream, :events)[]
    ccall(
        events.control_info,
        Cvoid,
        (Ref{T}, UInt32, Ptr{PipeWireAO.LibPipeWire.pw_stream_control}),
        stream,
        UInt32(3),
        control,
    )
    ccall(
        events.io_changed,
        Cvoid,
        (Ref{T}, UInt32, Ptr{Cvoid}, UInt32),
        stream,
        UInt32(4),
        Ptr{Cvoid}(UInt(0x1234)),
        UInt32(64),
    )
    ccall(
        events.command,
        Cvoid,
        (Ref{T}, Ptr{PipeWireAO.LibPipeWire.spa_command}),
        stream,
        command,
    )
    ccall(events.trigger_done, Cvoid, (Ref{T},), stream)
    return nothing
end

function invoke_stream_remaining_callbacks(stream::T, param::Pod) where {T<:Stream}
    events = getfield(stream, :events)[]
    detail = "primary stream state"
    buffer = Ptr{PipeWireAO.LibPipeWire.pw_buffer}(UInt(0x3456))
    GC.@preserve stream detail param begin
        ccall(
            events.state_changed,
            Cvoid,
            (Ref{T}, Int32, Int32, Cstring),
            stream,
            Int32(8),
            Int32(9),
            pointer(detail),
        )
        ccall(
            events.param_changed,
            Cvoid,
            (Ref{T}, UInt32, Ptr{PipeWireAO.LibPipeWire.spa_pod}),
            stream,
            UInt32(10),
            PipeWireAO._pod_pointer(param),
        )
        ccall(
            events.add_buffer,
            Cvoid,
            (Ref{T}, Ptr{PipeWireAO.LibPipeWire.pw_buffer}),
            stream,
            buffer,
        )
        ccall(
            events.remove_buffer,
            Cvoid,
            (Ref{T}, Ptr{PipeWireAO.LibPipeWire.pw_buffer}),
            stream,
            buffer,
        )
        ccall(events.drained, Cvoid, (Ref{T},), stream)
    end
    return nothing
end

function invoke_proxy_extended_callbacks(proxy::T) where {T<:Proxy}
    events = getfield(proxy, :events)[]
    ccall(events.removed, Cvoid, (Ref{T},), proxy)
    ccall(events.done, Cvoid, (Ref{T}, Cint), proxy, Cint(21))
    ccall(
        events.bound_props,
        Cvoid,
        (Ref{T}, UInt32, Ptr{PipeWireAO.LibPipeWire.spa_dict}),
        proxy,
        UInt32(22),
        C_NULL,
    )
    return nothing
end

function invoke_proxy_error_callback(proxy::T) where {T<:Proxy}
    detail = "primary proxy error"
    GC.@preserve proxy detail ccall(
        getfield(proxy, :events)[].error,
        Cvoid,
        (Ref{T}, Cint, Cint, Cstring),
        proxy,
        Cint(23),
        Cint(-24),
        pointer(detail),
    )
    return nothing
end

function callback_allocations(stream)
    invoke_process_callback(stream)
    return @allocated invoke_process_callback(stream)
end

function dequeue_allocations(buffer, stream)
    dequeue_buffer!(buffer, stream)
    return @allocated dequeue_buffer!(buffer, stream)
end

function chunk_info_allocations(data)
    chunk_info(data)
    return @allocated chunk_info(data)
end

function invoke_core_scalar_callbacks(core::T) where {T<:CoreConnection}
    events = core.events[]
    GC.@preserve core begin
        ccall(events.ping, Cvoid, (Ref{T}, UInt32, Cint), core, 11, 12)
        ccall(events.remove_id, Cvoid, (Ref{T}, UInt32), core, 13)
        ccall(events.bound_id, Cvoid, (Ref{T}, UInt32, UInt32), core, 14, 15)
        ccall(
            events.add_mem,
            Cvoid,
            (Ref{T}, UInt32, UInt32, Cint, UInt32),
            core,
            UInt32(16),
            PipeWireAO.LibPipeWire.SPA_DATA_MemFd,
            Cint(17),
            UInt32(18),
        )
        ccall(events.remove_mem, Cvoid, (Ref{T}, UInt32), core, 16)
    end
    return nothing
end

function core_scalar_callback_allocations(core)
    invoke_core_scalar_callbacks(core)
    return @allocated invoke_core_scalar_callbacks(core)
end

function invoke_core_bound_properties(core::T, dictionary) where {T<:CoreConnection}
    ccall(
        core.events[].bound_props,
        Cvoid,
        (Ref{T}, UInt32, UInt32, Ptr{PipeWireAO.LibPipeWire.spa_dict}),
        core,
        UInt32(19),
        UInt32(20),
        dictionary,
    )
    return nothing
end

function invoke_profile_callback(profiler::T, profile::Pod) where {T<:Profiler}
    GC.@preserve profiler profile ccall(
        getfield(profiler, :events)[].profile,
        Cvoid,
        (Ref{T}, Ptr{PipeWireAO.LibPipeWire.spa_pod}),
        profiler,
        PipeWireAO._pod_pointer(profile),
    )
    return nothing
end

@testset "Clang.jl-generated C bindings" begin
    raw_version = PipeWireAO.LibPipeWire.pw_get_library_version()
    @test raw_version != C_NULL
    @test VersionNumber(unsafe_string(raw_version)) == library_version()
    @test isbitstype(PipeWireAO.LibPipeWire.spa_hook)
    @test isbitstype(PipeWireAO.LibPipeWire.pw_core_events)
    @test isbitstype(PipeWireAO.LibPipeWire.pw_registry_events)
end

@testset "core protocol" begin
    context = Context()
    ping_event = Ref((UInt32(0), Cint(0)))
    removed_id = Ref(UInt32(0))
    bound_event = Ref((UInt32(0), UInt32(0)))
    memory_event = Ref(CoreMemory(UInt32(0), UInt32(0), Cint(-1), UInt32(0)))
    removed_memory = Ref(UInt32(0))
    bound_properties = Ref((UInt32(0), UInt32(0), Dict{String,String}()))
    core_infos = CoreInfo[]
    done_events = Tuple{UInt32,Cint}[]
    core = CoreConnection(
        context;
        self=true,
        on_info=(core, info) -> push!(core_infos, info),
        on_done=(core, id, sequence) -> push!(done_events, (id, sequence)),
        on_ping=PingRecorder(ping_event),
        on_remove_id=IdRecorder(removed_id),
        on_bound_id=BoundIdRecorder(bound_event),
        on_add_memory=MemoryRecorder(memory_event),
        on_remove_memory=IdRecorder(removed_memory),
        on_bound_properties=BoundPropertiesRecorder(bound_properties),
    )

    @test isconcretetype(typeof(core))
    @test all(isconcretetype, fieldtypes(typeof(core)))
    @test isbitstype(CoreMemory)
    @test core_scalar_callback_allocations(core) == 0
    @test ping_event[] == (UInt32(11), Cint(12))
    @test removed_id[] == 13
    @test bound_event[] == (UInt32(14), UInt32(15))
    @test memory_event[] == CoreMemory(
        UInt32(16),
        PipeWireAO.LibPipeWire.SPA_DATA_MemFd,
        Cint(17),
        UInt32(18),
    )
    @test removed_memory[] == 16

    PipeWireAO._with_properties_dict(Dict("object.path" => "test.core.bound")) do dictionary
        GC.@preserve core invoke_core_bound_properties(core, dictionary)
    end
    @test bound_properties[] == (
        UInt32(19),
        UInt32(20),
        Dict("object.path" => "test.core.bound"),
    )

    initial_properties = core_properties(core)
    @test update_properties!(core, Dict("application.name" => "PipeWireAO.jl protocol test")) ===
          core
    updated_properties = core_properties(core)
    @test updated_properties["application.name"] == "PipeWireAO.jl protocol test"
    updated_properties["application.name"] = "snapshot only"
    @test core_properties(core)["application.name"] == "PipeWireAO.jl protocol test"
    @test initial_properties isa Dict{String,String}

    sequence = sync!(core, 41)
    @test sequence isa Cint
    roundtrip(core)
    @test any(event -> event == (UInt32(0), sequence), done_events)

    previous_info_count = length(core_infos)
    @test hello!(core) === core
    roundtrip(core)
    @test length(core_infos) > previous_info_count

    @test_throws ArgumentError sync!(core, -1; id=-1)
    @test_throws ArgumentError sync!(core, big(typemax(Cint)) + 1)
    @test_throws ArgumentError pong!(core, 0, big(typemax(Cint)) + 1)
    @test_throws ArgumentError report_error!(core, 0, 0, -1, "bad\0message")
    @test_throws ArgumentError hello!(core; version=5)

    close(core)
    close(context)
end

@testset "PipeWire" begin
    @test library_version() >= v"1.6"

    loop = MainLoop()
    @test isopen(loop)
    close(loop)
    @test !isopen(loop)
    close(loop)

    @test_throws InvalidStateException run!(loop)
    @test_throws InvalidStateException quit!(loop)

    result = with_main_loop() do scoped_loop
        @test isopen(scoped_loop)
        return :ok
    end
    @test result === :ok

    # Julia 1.10 and 1.11 cannot mark the blocking generated @ccall as GC-safe.
    if VERSION >= v"1.12" && Threads.nthreads() > 1
        threaded_loop = MainLoop()
        runner = Threads.@spawn run!(threaded_loop)
        started = () -> lock(getfield(threaded_loop, :state_lock)) do
            getfield(threaded_loop, :running)
        end
        @test Base.timedwait(started, 5) === :ok
        quit!(threaded_loop)
        @test fetch(runner) === nothing
        close(threaded_loop)
    end
end

@testset "managed core and registry" begin
    loop = MainLoop()
    context = Context(loop; properties=Dict("application.name" => "PipeWireAO.jl context"))
    @test isopen(context)
    @test isconcretetype(typeof(context))
    @test all(isconcretetype, fieldtypes(typeof(context)))
    @test main_loop(context) === loop
    @test context_properties(context)["application.name"] == "PipeWireAO.jl context"
    @test update_properties!(context, Dict("pipewire.jl.context" => "updated")) === context
    @test context_properties(context)["pipewire.jl.context"] == "updated"
    @test_throws InvalidStateException close(loop)
    @test_throws ArgumentError CoreConnection(context; self=true, fd=0)

    core_infos = CoreInfo[]
    done_events = Tuple{UInt32,Cint}[]
    core = CoreConnection(
        context;
        self=true,
        on_info=(core, info) -> push!(core_infos, info),
        on_done=(core, id, sequence) -> push!(done_events, (id, sequence)),
    )
    @test isopen(core)
    @test isconcretetype(typeof(core))
    @test all(isconcretetype, fieldtypes(typeof(core)))
    @test main_loop(core) === loop
    @test_throws InvalidStateException close(context)

    registry = Registry(core)
    @test isopen(registry)
    @test isconcretetype(typeof(registry))
    @test all(isconcretetype, fieldtypes(typeof(registry)))
    @test_throws InvalidStateException close(core)
    @test_throws InvalidStateException hello!(core)

    roundtrip(registry)
    @test length(core_infos) == 1
    @test core_infos[1].id == 0
    @test !isempty(core_infos[1].version)
    @test length(done_events) == 1
    first_snapshot = globals(registry)
    @test !isempty(first_snapshot)
    @test issorted(first_snapshot; by=global_object -> global_object.id)
    @test any(global_object -> global_object.type == "PipeWire:Interface:Core", first_snapshot)
    @test find_global(registry, first_snapshot[1].id).id == first_snapshot[1].id
    @test registry[first_snapshot[1].id].id == first_snapshot[1].id
    @test find_global(registry, typemax(UInt32)) === nothing
    @test_throws KeyError registry[typemax(UInt32)]
    core_globals = find_globals(registry; interface="PipeWire:Interface:Core")
    @test length(core_globals) == 1
    @test core_globals[1].type == "PipeWire:Interface:Core"

    roundtrip(registry)
    second_snapshot = globals(registry)
    @test map(global_object -> global_object.id, second_snapshot) ==
          map(global_object -> global_object.id, first_snapshot)

    if !isempty(first_snapshot[1].properties)
        key = first(keys(first_snapshot[1].properties))
        first_snapshot[1].properties[key] = "changed only in the snapshot"
        @test globals(registry)[1].properties[key] != "changed only in the snapshot"
    end

    close(registry)
    @test !isopen(registry)
    close(core)
    @test !isopen(core)
    close(context)
    @test !isopen(context)
    close(loop)
    @test !isopen(loop)

    copied_globals = with_registry(self=true) do scoped_registry
        roundtrip(scoped_registry)
        globals(scoped_registry)
    end
    @test !isempty(copied_globals)

    scoped_name = with_registry(
        self=true,
        context_properties=Dict("application.name" => "PipeWireAO.jl scoped context"),
        core_properties=Dict("application.name" => "PipeWireAO.jl scoped core"),
    ) do scoped_registry
        context_properties(scoped_registry.core.context)["application.name"]
    end
    @test scoped_name == "PipeWireAO.jl scoped context"
end

@testset "properties" begin
    properties = Properties(Dict("media.type" => "Audio", "node.name" => "julia-test"))
    @test isopen(properties)
    @test length(properties) == 2
    @test properties["media.type"] == "Audio"
    @test get(properties, "missing", "fallback") == "fallback"
    @test haskey(properties, "node.name")

    properties["application.name"] = "PipeWireAO.jl tests"
    delete!(properties, "media.type")
    @test Dict(properties) == Dict(
        "application.name" => "PipeWireAO.jl tests",
        "node.name" => "julia-test",
    )

    copied = copy(properties)
    empty!(properties)
    @test isempty(properties)
    @test length(copied) == 2
    close(properties)
    @test !isopen(properties)
    @test_throws InvalidStateException length(properties)
    close(copied)

    @test_throws ArgumentError Properties(Dict("bad\0key" => "value"))
end

@testset "managed proxy" begin
    context = Context()
    core = CoreConnection(context; self=true)
    registry = Registry(core)
    roundtrip(registry)
    factory = first(global_object for global_object in globals(registry) if
                    global_object.type == "PipeWire:Interface:Factory")
    bound = UInt32[]
    removed = Ref(0)
    done = Cint[]
    errors = Tuple{Cint,PipeWireError}[]
    bound_properties = Tuple{UInt32,Dict{String,String}}[]
    proxy = bind(
        registry,
        factory;
        on_bound=(proxy, id) -> push!(bound, id),
        on_removed=proxy -> (removed[] += 1),
        on_done=(proxy, sequence) -> push!(done, sequence),
        on_error=(proxy, sequence, error) -> push!(errors, (sequence, error)),
        on_bound_properties=(proxy, id, properties) ->
            push!(bound_properties, (id, properties)),
    )

    @test isopen(proxy)
    @test isconcretetype(typeof(proxy))
    @test all(isconcretetype, fieldtypes(typeof(proxy)))
    @test interface_type(proxy) == factory.type
    @test proxy_id(proxy) != typemax(UInt32)
    @test_throws InvalidStateException close(registry)
    roundtrip(proxy)
    @test bound_id(proxy) == factory.id
    @test bound == [factory.id]
    invoke_proxy_extended_callbacks(proxy)
    @test removed[] == 1
    @test done == Cint[21]
    @test bound_properties[end] == (UInt32(22), Dict{String,String}())
    invoke_proxy_error_callback(proxy)
    @test only(errors)[1] == 23
    @test only(errors)[2].code == -24
    @test only(errors)[2].detail == "primary proxy error"

    close(proxy)
    @test !isopen(proxy)
    close(proxy)
    close(registry)
    close(core)
    close(context)
end

@testset "typed PipeWire objects" begin
    context = Context()
    @test enable_profiler!(context) === context
    @test enable_profiler!(context) === context
    core = CoreConnection(context; self=true)
    registry = Registry(core)
    roundtrip(registry)

    metadata_global = only(
        global_object for global_object in globals(registry) if
        global_object.type == "PipeWire:Interface:Metadata"
    )
    property_events = Tuple{
        UInt32,
        Union{Nothing,String},
        Union{Nothing,String},
        Union{Nothing,String},
    }[]
    metadata = bind(
        registry,
        metadata_global,
        Metadata;
        on_property=(metadata, subject, key, type, value) ->
            push!(property_events, (subject, key, type, value)),
    )

    @test isopen(metadata)
    @test isconcretetype(typeof(metadata))
    @test all(isconcretetype, fieldtypes(typeof(metadata)))
    @test interface_type(metadata) == metadata_global.type
    @test_throws InvalidStateException close(registry)

    roundtrip(metadata)
    initial_event_count = length(property_events)
    set_property!(
        metadata,
        0,
        "pipewire.jl.test";
        type="Spa:String:JSON",
        value="true",
    )
    roundtrip(metadata)
    @test length(property_events) == initial_event_count + 1
    @test property_events[end] ==
          (UInt32(0), "pipewire.jl.test", "Spa:String:JSON", "true")

    set_property!(metadata, 0, "pipewire.jl.test")
    roundtrip(metadata)
    @test property_events[end] == (UInt32(0), "pipewire.jl.test", nothing, nothing)
    @test clear!(metadata) === metadata
    @test_throws ArgumentError set_property!(metadata, 0, "bad\0key"; value="x")
    @test_throws ArgumentError bind(registry, metadata_global, Node)
    @test_throws ArgumentError destroy_object!(core, metadata)
    @test isopen(metadata)

    close(metadata)
    @test !isopen(metadata)

    created_properties = Properties(Dict("metadata.name" => "pipewire.jl.created"))
    created = create_object(core, "metadata", Metadata; properties=created_properties)
    @test isopen(created_properties)
    @test isconcretetype(typeof(created))
    @test all(isconcretetype, fieldtypes(typeof(created)))
    @test getfield(getfield(created, :proxy), :parent) === core
    @test_throws InvalidStateException close(core)
    roundtrip(registry)
    created_id = bound_id(created)
    @test any(global_object -> global_object.id == created_id, globals(registry))

    @test destroy_object!(core, created) === core
    @test !isopen(created)
    roundtrip(registry)
    @test !any(global_object -> global_object.id == created_id, globals(registry))
    close(created_properties)
    @test_throws ArgumentError create_object(core, "bad\0factory", Metadata)

    factory_global = first(
        global_object for global_object in globals(registry) if
        global_object.type == "PipeWire:Interface:Factory"
    )
    module_global = first(
        global_object for global_object in globals(registry) if
        global_object.type == "PipeWire:Interface:Module"
    )
    client_global = only(
        global_object for global_object in globals(registry) if
        global_object.type == "PipeWire:Interface:Client"
    )
    profiler_global = only(
        global_object for global_object in globals(registry) if
        global_object.type == "PipeWire:Interface:Profiler"
    )
    factory_infos = FactoryInfo[]
    module_infos = ModuleInfo[]
    client_infos = ClientInfo[]
    permission_events = Tuple{UInt32,Vector{Permission}}[]
    profiles = Pod[]
    factory = bind(
        registry,
        factory_global,
        Factory;
        on_info=(factory, info) -> push!(factory_infos, info),
    )
    module_object = bind(
        registry,
        module_global,
        PipeWireModule;
        on_info=(module_object, info) -> push!(module_infos, info),
    )
    client = bind(
        registry,
        client_global,
        Client;
        on_info=(client, info) -> push!(client_infos, info),
        on_permissions=(client, index, permissions) ->
            push!(permission_events, (index, permissions)),
    )
    profiler = bind(
        registry,
        profiler_global,
        Profiler;
        on_profile=(profiler, profile) -> push!(profiles, profile),
    )
    @test all(isconcretetype, fieldtypes(typeof(factory)))
    @test all(isconcretetype, fieldtypes(typeof(module_object)))
    @test all(isconcretetype, fieldtypes(typeof(client)))
    @test all(isconcretetype, fieldtypes(typeof(profiler)))
    listener_factory_infos = FactoryInfo[]
    factory_listener = add_listener!(
        factory;
        on_info=(factory, info) -> push!(listener_factory_infos, info),
    )
    sample_profile = Pod(Int64(42))
    invoke_profile_callback(profiler, sample_profile)
    @test length(profiles) == 1
    @test pod_value(Int64, only(profiles)) == 42
    roundtrip(registry)
    @test only(factory_infos).id == factory_global.id
    @test only(listener_factory_infos).id == factory_global.id
    @test !isempty(only(factory_infos).name)
    @test only(module_infos).id == module_global.id
    @test !isempty(only(module_infos).name)
    @test only(client_infos).id == client_global.id
    get_permissions!(client)
    roundtrip(registry)
    @test !isempty(permission_events)
    @test first(permission_events)[1] == 0
    @test update_properties!(client, Dict("application.name" => "PipeWireAO.jl client test")) ===
          client
    @test update_permissions!(client, Permission[]) === client
    close(factory_listener)
    close(profiler)
    close(client)
    close(module_object)
    close(factory)

    close(registry)
    close(core)
    close(context)

    node_error = "node failed"
    node_native = Ref(
        PipeWireAO.LibPipeWire.pw_node_info(
            UInt32(42),
            UInt32(8),
            UInt32(9),
            UInt64(31),
            UInt32(2),
            UInt32(3),
            PipeWireAO.LibPipeWire.PW_NODE_STATE_ERROR,
            pointer(node_error),
            C_NULL,
            C_NULL,
            UInt32(0),
        ),
    )
    info = GC.@preserve node_error node_native PipeWireAO._copy_node_info(
        Base.unsafe_convert(Ptr{PipeWireAO.LibPipeWire.pw_node_info}, node_native),
    )
    @test info.id == 42
    @test info.max_input_ports == 8
    @test info.max_output_ports == 9
    @test info.n_input_ports == 2
    @test info.n_output_ports == 3
    @test info.state == PipeWireAO.NODE_STATE_ERROR
    @test info.error == "node failed"
    @test isempty(info.properties)
    @test isempty(info.params)
end

include("loop.jl")
include("spa.jl")
include("progressive_metadata.jl")
include("filter.jl")
include("progressive_filter.jl")
include("listeners.jl")
include("examples.jl")
@testset "managed stream" begin
    context = Context()
    connection_properties = Properties(Dict("application.name" => "PipeWireAO.jl tests"))
    core = CoreConnection(context; self=true, properties=connection_properties)
    @test isopen(connection_properties)

    properties = Properties(Dict("media.type" => "Audio"))
    state_changes = Tuple{Int32,Int32,Union{Nothing,String}}[]
    control_changes = Tuple{UInt32,Union{Nothing,StreamControl}}[]
    io_changes = StreamIO[]
    param_changes = Tuple{UInt32,Union{Nothing,Pod}}[]
    added_buffers = Ptr{PipeWireAO.LibPipeWire.pw_buffer}[]
    removed_buffers = Ptr{PipeWireAO.LibPipeWire.pw_buffer}[]
    commands = Pod[]
    drained_count = Ref(0)
    trigger_count = Ref(0)
    process_count = Ref(0)
    stream = Stream(
        core,
        "julia-test";
        properties=properties,
        on_state_changed=(stream, old, current, detail) ->
            push!(state_changes, (old, current, detail)),
        on_control_info=(stream, id, control) -> push!(control_changes, (id, control)),
        on_io_changed=(stream, io) -> push!(io_changes, io),
        on_param_changed=(stream, id, param) -> push!(param_changes, (id, param)),
        on_buffer_added=(stream, buffer) -> push!(added_buffers, buffer),
        on_buffer_removed=(stream, buffer) -> push!(removed_buffers, buffer),
        on_drained=stream -> (drained_count[] += 1),
        on_command=(stream, command) -> push!(commands, command),
        on_trigger_done=(stream) -> (trigger_count[] += 1),
        on_process=CountProcess(process_count),
    )
    @test isopen(properties)
    @test isopen(stream)
    @test main_loop(stream) === main_loop(core)
    @test isconcretetype(typeof(stream))
    @test all(isconcretetype, fieldtypes(typeof(stream)))
    @test all(isconcretetype, fieldtypes(StreamControl))
    @test all(isconcretetype, fieldtypes(StreamIO))
    @test all(isconcretetype, fieldtypes(StreamTime))
    @test StreamBufferInfo === BufferInfo
    @test all(isconcretetype, fieldtypes(StreamBufferInfo))
    @test all(isconcretetype, fieldtypes(StreamMetadata))
    @test StreamMetadata === BufferMetadata{StreamBuffer}
    @test MappedStreamData === MappedBufferData{StreamData}
    @test all(isconcretetype, fieldtypes(BufferChunk))
    @test isbitstype(BufferChunk)
    @test all(isconcretetype, fieldtypes(BufferHeader))
    @test all(isconcretetype, fieldtypes(BufferRegion))
    @test all(isconcretetype, fieldtypes(BufferBitmap))
    @test all(isconcretetype, fieldtypes(BufferBusy))
    @test all(isconcretetype, fieldtypes(BufferSyncTimeline))
    @test all(
        isconcretetype,
        fieldtypes(typeof(BufferCursor(1, 2, 3, 4, 5, 6, nothing))),
    )
    @test callback_allocations(stream) == 0
    @test process_count[] == 2
    @test stream_state(stream) == PipeWireAO.LibPipeWire.PW_STREAM_STATE_UNCONNECTED
    @test stream_name(stream) == "julia-test"
    @test stream_properties(stream)["media.type"] == "Audio"
    @test update_properties!(stream, Dict("media.role" => "Test")) === stream
    @test stream_properties(stream)["media.role"] == "Test"
    @test update_params!(stream, ()) === stream
    @test stream_control(stream, 0) === nothing
    @test node_id(stream) isa UInt32
    @test stream_nsec(stream) isa UInt64
    @test !is_driving(stream)
    @test !is_lazy(stream)
    @test_throws PipeWireError stream_time(stream)
    @test_throws ArgumentError set_param!(stream, -1, nothing)
    @test_throws ArgumentError set_control!(stream, -1, 0.5)
    @test_throws ArgumentError set_rate!(stream, NaN)
    @test_throws ArgumentError set_error!(stream, 0, "not negative")
    @test_throws ArgumentError emit_event!(stream, Pod(Int32(1)))

    control_name = "Volume"
    control_values = Float32[0.25, 0.5]
    native_control = Ref(
        PipeWireAO.LibPipeWire.pw_stream_control(
            pointer(control_name),
            UInt32(0),
            0.5f0,
            0.0f0,
            1.0f0,
            pointer(control_values),
            UInt32(length(control_values)),
            UInt32(8),
        ),
    )
    command = Pod(Int32(7))
    GC.@preserve stream control_name control_values native_control command begin
        invoke_stream_extended_callbacks(
            stream,
            Base.unsafe_convert(Ptr{PipeWireAO.LibPipeWire.pw_stream_control}, native_control),
            Ptr{PipeWireAO.LibPipeWire.spa_command}(PipeWireAO._pod_pointer(command)),
        )
    end
    @test control_changes == [
        (
            UInt32(3),
            StreamControl("Volume", UInt32(0), 0.5f0, 0.0f0, 1.0f0, control_values, 8),
        ),
    ]
    copied_control = only(control_changes)[2]
    @test isequal(copied_control, copied_control)
    @test hash(copied_control) == hash(copied_control)
    @test io_changes == [StreamIO(UInt32(4), Ptr{Cvoid}(UInt(0x1234)), UInt32(64))]
    @test length(commands) == 1
    @test pod_value(Int32, commands[1]) == 7
    @test trigger_count[] == 1
    stream_param = Pod(Int64(11))
    invoke_stream_remaining_callbacks(stream, stream_param)
    @test state_changes == [(Int32(8), Int32(9), "primary stream state")]
    @test only(param_changes)[1] == 10
    @test pod_value(Int64, something(only(param_changes)[2])) == 11
    @test added_buffers == [Ptr{PipeWireAO.LibPipeWire.pw_buffer}(UInt(0x3456))]
    @test removed_buffers == added_buffers
    @test drained_count[] == 1
    @test_throws InvalidStateException close(core)
    @test_throws ArgumentError connect!(
        stream,
        :output;
        flags=PipeWireAO.LibPipeWire.PW_STREAM_FLAG_RT_PROCESS,
    )
    @test_throws ArgumentError connect!(
        stream,
        :output;
        flags=PipeWireAO.LibPipeWire.PW_STREAM_FLAG_RT_TRIGGER_DONE,
    )
    @test_throws ArgumentError connect!(stream, :sideways)
    @test dequeue_buffer(stream) === nothing
    reusable_buffer = StreamBuffer()
    @test dequeue_allocations(reusable_buffer, stream) == 0
    @test reusable_buffer.handle == C_NULL

    format = audio_format()
    @test sizeof(format) == 168
    @test pod_type(format) == PipeWireAO.LibPipeWire.SPA_TYPE_Object
    @test_throws ArgumentError audio_format(channels=2, position=[Audio.MONO])
    connect!(
        stream,
        :output;
        flags=STREAM_AUTOCONNECT | STREAM_MAP_BUFFERS | STREAM_INACTIVE | STREAM_TRIGGER,
        params=[format],
    )
    @test stream_state(stream) == PipeWireAO.LibPipeWire.PW_STREAM_STATE_CONNECTING
    @test state_changes[end] == (
        PipeWireAO.LibPipeWire.PW_STREAM_STATE_UNCONNECTED,
        PipeWireAO.LibPipeWire.PW_STREAM_STATE_CONNECTING,
        nothing,
    )
    @test set_active!(stream) === stream
    @test flush!(stream) === stream
    @test trigger_process!(stream) === stream
    @test set_control!(stream, SPA.PROP_VOLUME, 0.25) === stream
    @test set_control!(stream, SPA.PROP_CHANNEL_VOLUMES, Float32[0.25, 0.5]) === stream
    disconnect!(stream)

    storage = collect(UInt8(1):UInt8(16))
    chunk = Ref(
        PipeWireAO.LibPipeWire.spa_chunk(
            UInt32(2),
            UInt32(4),
            Int32(2),
            SPA.CHUNK_FLAG_CORRUPTED,
        ),
    )
    header = Ref(
        PipeWireAO.LibPipeWire.spa_meta_header(
            UInt32(5),
            UInt32(6),
            Int64(7),
            Int64(-8),
            UInt64(9),
        ),
    )
    crop = Ref(
        PipeWireAO.LibPipeWire.spa_meta_region(
            PipeWireAO.LibPipeWire.spa_region(
                PipeWireAO.LibPipeWire.spa_point(Int32(10), Int32(11)),
                PipeWireAO.LibPipeWire.spa_rectangle(UInt32(12), UInt32(13)),
            ),
        ),
    )
    damage = [
        PipeWireAO.LibPipeWire.spa_meta_region(
            PipeWireAO.LibPipeWire.spa_region(
                PipeWireAO.LibPipeWire.spa_point(Int32(1), Int32(2)),
                PipeWireAO.LibPipeWire.spa_rectangle(UInt32(3), UInt32(4)),
            ),
        ),
        PipeWireAO.LibPipeWire.spa_meta_region(
            PipeWireAO.LibPipeWire.spa_region(
                PipeWireAO.LibPipeWire.spa_point(Int32(0), Int32(0)),
                PipeWireAO.LibPipeWire.spa_rectangle(UInt32(0), UInt32(0)),
            ),
        ),
    ]
    transform = Ref(PipeWireAO.LibPipeWire.spa_meta_videotransform(UInt32(2)))
    timeline = Ref(
        PipeWireAO.LibPipeWire.spa_meta_sync_timeline(
            UInt32(1),
            UInt32(0),
            UInt64(20),
            UInt64(21),
        ),
    )
    metas = PipeWireAO.LibPipeWire.spa_meta[
        PipeWireAO.LibPipeWire.spa_meta(
            PipeWireAO.LibPipeWire.SPA_META_Header,
            UInt32(sizeof(PipeWireAO.LibPipeWire.spa_meta_header)),
            Base.unsafe_convert(Ptr{Cvoid}, header),
        ),
        PipeWireAO.LibPipeWire.spa_meta(
            PipeWireAO.LibPipeWire.SPA_META_VideoCrop,
            UInt32(sizeof(PipeWireAO.LibPipeWire.spa_meta_region)),
            Base.unsafe_convert(Ptr{Cvoid}, crop),
        ),
        PipeWireAO.LibPipeWire.spa_meta(
            PipeWireAO.LibPipeWire.SPA_META_VideoDamage,
            UInt32(sizeof(PipeWireAO.LibPipeWire.spa_meta_region) * length(damage)),
            Ptr{Cvoid}(pointer(damage)),
        ),
        PipeWireAO.LibPipeWire.spa_meta(
            PipeWireAO.LibPipeWire.SPA_META_VideoTransform,
            UInt32(sizeof(PipeWireAO.LibPipeWire.spa_meta_videotransform)),
            Base.unsafe_convert(Ptr{Cvoid}, transform),
        ),
        PipeWireAO.LibPipeWire.spa_meta(
            PipeWireAO.LibPipeWire.SPA_META_SyncTimeline,
            UInt32(sizeof(PipeWireAO.LibPipeWire.spa_meta_sync_timeline)),
            Base.unsafe_convert(Ptr{Cvoid}, timeline),
        ),
    ]
    native_data = Ref(
        PipeWireAO.LibPipeWire.spa_data(
            PipeWireAO.LibPipeWire.SPA_DATA_MemPtr,
            UInt32(0),
            Int64(-1),
            UInt32(0),
            UInt32(length(storage)),
            pointer(storage),
            Base.unsafe_convert(Ptr{PipeWireAO.LibPipeWire.spa_chunk}, chunk),
        ),
    )
    spa_buffer = Ref(
        PipeWireAO.LibPipeWire.spa_buffer(
            UInt32(length(metas)),
            UInt32(1),
            pointer(metas),
            Base.unsafe_convert(Ptr{PipeWireAO.LibPipeWire.spa_data}, native_data),
        ),
    )
    native_buffer = Ref(
        PipeWireAO.LibPipeWire.pw_buffer(
            Base.unsafe_convert(Ptr{PipeWireAO.LibPipeWire.spa_buffer}, spa_buffer),
            C_NULL,
            UInt64(0),
            UInt64(0),
            UInt64(0),
        ),
    )
    GC.@preserve storage chunk header crop damage transform timeline metas native_data spa_buffer native_buffer begin
        borrowed = StreamBuffer(
            Base.unsafe_convert(Ptr{PipeWireAO.LibPipeWire.pw_buffer}, native_buffer),
        )
        data = buffer_data(borrowed)
        @test buffer_info(borrowed) == StreamBufferInfo(C_NULL, 0, 0, 0)
        @test set_buffer_size!(borrowed, 15) === borrowed
        @test buffer_info(borrowed).size == 15
        @test metadata_count(borrowed) == 5
        @test metadata_type(buffer_metadata(borrowed, 1)) ==
              PipeWireAO.LibPipeWire.SPA_META_Header
        @test metadata_size(buffer_metadata(borrowed, PipeWireAO.LibPipeWire.SPA_META_Header)) ==
              sizeof(PipeWireAO.LibPipeWire.spa_meta_header)
        @test length(metadata_bytes(buffer_metadata(borrowed, 1))) ==
              sizeof(PipeWireAO.LibPipeWire.spa_meta_header)
        @test buffer_header(borrowed) == BufferHeader(5, 6, 7, -8, 9)
        replacement_header = BufferHeader(10, 11, 12, -13, 14)
        @test set_buffer_header!(borrowed, replacement_header) === borrowed
        @test buffer_header(borrowed) == replacement_header
        @test video_crop(borrowed) == BufferRegion(10, 11, 12, 13)
        @test video_damage(borrowed) == [BufferRegion(1, 2, 3, 4)]
        @test video_transform(borrowed) == 2
        @test sync_timeline(borrowed) == BufferSyncTimeline(1, 20, 21)
        bitmap = BufferBitmap(UInt32(1), UInt32(2), UInt32(3), Int32(4), UInt8[5])
        same_bitmap = BufferBitmap(UInt32(1), UInt32(2), UInt32(3), Int32(4), UInt8[5])
        @test bitmap == same_bitmap
        @test isequal(bitmap, same_bitmap)
        @test hash(bitmap) == hash(same_bitmap)
        @test buffer_metadata(borrowed, UInt32(500)) === nothing
        @test data_type(data) == PipeWireAO.LibPipeWire.SPA_DATA_MemPtr
        @test data_flags(data) == SPA.DATA_FLAG_NONE
        @test data_fd(data) == -1
        @test data_map_offset(data) == 0
        @test is_mapped(data)
        @test_throws InvalidStateException map_data(data)
        @test capacity(data) == 16
        @test data_pointer(data) == pointer(storage)
        @test bytes(data) == UInt8[3, 4, 5, 6]
        snapshot = @inferred chunk_info(data)
        @test snapshot == BufferChunk(2, 4, 2, SPA.CHUNK_FLAG_CORRUPTED)
        @test !iszero(snapshot.flags & SPA.CHUNK_FLAG_CORRUPTED)
        @test chunk_info_allocations(data) == 0
        set_chunk!(data; offset=0, size=8, stride=4)
        @test chunk_info(data) == BufferChunk(0, 8, 4, SPA.CHUNK_FLAG_CORRUPTED)
        @test snapshot == BufferChunk(2, 4, 2, SPA.CHUNK_FLAG_CORRUPTED)
        @test length(bytes(data)) == 8
        @test writable_bytes(data) == storage

        allocated = allocate_buffer!(
            stream,
            Base.unsafe_convert(Ptr{PipeWireAO.LibPipeWire.pw_buffer}, native_buffer),
            32,
        )
        @test length(allocated) == 1
        @test length(allocated[1]) == 32
        @test data_type(data) == PipeWireAO.LibPipeWire.SPA_DATA_MemPtr
        @test data_flags(data) == SPA.DATA_FLAG_READWRITE
        @test data_pointer(data) == pointer(allocated[1])
    end

    mktemp() do _, io
        truncate(io, 4096)
        raw_fd = Base.fd(io)
        file_descriptor =
            raw_fd isa Integer ? Cint(raw_fd) : reinterpret(Cint, raw_fd)
        file_chunk = Ref(
            PipeWireAO.LibPipeWire.spa_chunk(UInt32(0), UInt32(0), Int32(0), Int32(0)),
        )
        file_data = Ref(
            PipeWireAO.LibPipeWire.spa_data(
                PipeWireAO.LibPipeWire.SPA_DATA_MemFd,
                SPA.DATA_FLAG_READWRITE,
                Int64(file_descriptor),
                UInt32(0),
                UInt32(4096),
                C_NULL,
                Base.unsafe_convert(Ptr{PipeWireAO.LibPipeWire.spa_chunk}, file_chunk),
            ),
        )
        file_spa_buffer = Ref(
            PipeWireAO.LibPipeWire.spa_buffer(
                UInt32(0),
                UInt32(1),
                C_NULL,
                Base.unsafe_convert(Ptr{PipeWireAO.LibPipeWire.spa_data}, file_data),
            ),
        )
        file_buffer = Ref(
            PipeWireAO.LibPipeWire.pw_buffer(
                Base.unsafe_convert(Ptr{PipeWireAO.LibPipeWire.spa_buffer}, file_spa_buffer),
                C_NULL,
                UInt64(0),
                UInt64(0),
                UInt64(0),
            ),
        )
        GC.@preserve file_chunk file_data file_spa_buffer file_buffer begin
            borrowed = StreamBuffer(
                Base.unsafe_convert(Ptr{PipeWireAO.LibPipeWire.pw_buffer}, file_buffer),
            )
            mapping = map_data(buffer_data(borrowed); writable=true)
            @test isopen(mapping)
            @test length(bytes(mapping)) == 4096
            bytes(mapping)[1] = 0x5a
            close(mapping)
            @test !isopen(mapping)
            close(mapping)
        end
    end

    @test set_error!(stream, -5, "stream test error") === stream
    stream_error = try
        stream_state(stream)
        nothing
    catch error
        error
    end
    @test stream_error isa PipeWireError
    @test stream_error.code == -5
    @test stream_error.detail == "stream test error"

    close(stream)
    @test !isopen(stream)
    close(stream)
    close(properties)
    close(connection_properties)
    close(core)
    close(context)
end
