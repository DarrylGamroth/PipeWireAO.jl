using PipeWireAO
using Test

function current_info_allocations(tracker)
    current_info(tracker)
    return @allocated current_info(tracker)
end

function invoke_tracker_info(
    tracker::InfoTracker{Info}, update::Info; raw_listener=nothing,
) where {Info}
    params = hasfield(Info, :params) ? [
        PipeWireAO.LibPipeWire.spa_param_info(param.id, param.flags, param.user, param.sequence, (0, 0, 0, 0))
        for param in update.params
    ] : PipeWireAO.LibPipeWire.spa_param_info[]
    error = hasfield(Info, :error) ? update.error : nothing
    format = hasfield(Info, :format) ? update.format : nothing
    PipeWireAO._with_properties_dict(update.properties) do properties
        GC.@preserve tracker update params error format begin
            native = Ref(tracker_native_info(update, properties, params))
            if raw_listener !== nothing
                invoke_tracker_native(raw_listener, native)
            end
            invoke_tracker_native(tracker.listener, native)
        end
    end
    return current_info(tracker)
end

function invoke_tracker_native(listener::T, native::Ref{N}) where {T,N}
    GC.@preserve listener native ccall(
        listener.events[].info, Cvoid, (Ref{T}, Ref{N}), listener, native,
    )
    return nothing
end

function invoke_tracker_null(listener::T, ::Type{N}) where {T,N}
    ccall(listener.events[].info, Cvoid, (Ref{T}, Ptr{N}), listener, C_NULL)
    return nothing
end

tracker_native_info(info::NodeInfo, properties, params) = PipeWireAO.LibPipeWire.pw_node_info(
    info.id, info.max_input_ports, info.max_output_ports, info.change_mask,
    info.n_input_ports, info.n_output_ports, Int32(info.state),
    info.error === nothing ? C_NULL : pointer(info.error), properties,
    isempty(params) ? C_NULL : pointer(params), length(params),
)
tracker_native_info(info::PortInfo, properties, params) = PipeWireAO.LibPipeWire.pw_port_info(
    info.id, UInt32(info.direction), info.change_mask, properties,
    isempty(params) ? C_NULL : pointer(params), length(params),
)
tracker_native_info(info::DeviceInfo, properties, params) = PipeWireAO.LibPipeWire.pw_device_info(
    info.id, info.change_mask, properties, isempty(params) ? C_NULL : pointer(params), length(params),
)
tracker_native_info(info::LinkInfo, properties, params) = PipeWireAO.LibPipeWire.pw_link_info(
    info.id, info.output_node_id, info.output_port_id, info.input_node_id, info.input_port_id,
    info.change_mask, Int32(info.state), info.error === nothing ? C_NULL : pointer(info.error),
    info.format === nothing ? C_NULL : PipeWireAO._pod_pointer(info.format), properties,
)

function tracker_fixture(object, ::Type{Info}, ::Type{Events}, event_function) where {Info,Events}
    state = PipeWireAO._CurrentInfoState(Info)
    callback = PipeWireAO._CurrentInfoCallback{typeof(object),Info}(state)
    listener = PipeWireAO._new_listener(object, Events, (on_info=callback, on_param=nothing))
    listener.events[] = event_function(listener)
    PipeWireAO._activate_listener!(listener)
    return InfoTracker(state, listener)
end

tracker_info_events(listener::ManagedListener{<:Node}) = PipeWireAO._listener_node_events(listener)
tracker_info_events(listener::ManagedListener{<:Port}) = PipeWireAO._listener_port_events(listener)
tracker_info_events(listener::ManagedListener{<:Device}) = PipeWireAO._listener_device_events(listener)
tracker_info_events(listener::ManagedListener{<:Link}) = PipeWireAO._listener_link_events(listener)

function tracker_raw_listener(tracker, callback)
    listener = PipeWireAO._new_listener(
        tracker.listener.owner, typeof(tracker.listener.events[]), (on_info=callback,),
    )
    listener.events[] = tracker_info_events(listener)
    return PipeWireAO._activate_listener!(listener)
end

function tracker_test_object(::Type{Object}, node, ::Type{Events}) where {Object,Events}
    return Object(
        node.proxy, ReentrantLock(), Ref(PipeWireAO._zero_hook()), Ref{Events}(),
        (on_info=nothing, on_param=nothing), Ref{Any}(nothing), true,
    )
end

@testset "maintained current object info" begin
    context = Context()
    core = CoreConnection(context; self=true)
    node = create_object(core, "adapter", Node; properties=Dict(
        "factory.name" => "support.null-audio-sink", "node.name" => "tracker-fixture",
    ))
    node_tracker = tracker_fixture(node, NodeInfo, PipeWireAO.LibPipeWire.pw_node_events,
        PipeWireAO._listener_node_events)
    node_state = node_tracker.state
    node_callback = node_tracker.listener.callbacks.on_info
    port_tracker = tracker_fixture(
        tracker_test_object(Port, node, PipeWireAO.LibPipeWire.pw_port_events), PortInfo,
        PipeWireAO.LibPipeWire.pw_port_events, PipeWireAO._listener_port_events,
    )
    device_tracker = tracker_fixture(
        tracker_test_object(Device, node, PipeWireAO.LibPipeWire.pw_device_events), DeviceInfo,
        PipeWireAO.LibPipeWire.pw_device_events, PipeWireAO._listener_device_events,
    )
    link_tracker = tracker_fixture(
        tracker_test_object(Link, node, PipeWireAO.LibPipeWire.pw_link_events), LinkInfo,
        PipeWireAO.LibPipeWire.pw_link_events, PipeWireAO._listener_link_events,
    )
    try
        @test isconcretetype(typeof(node_state))
        @test all(isconcretetype, fieldtypes(typeof(node_state)))
        @test isconcretetype(typeof(node_callback))
        @test all(isconcretetype, fieldtypes(typeof(node_callback)))
        @test isconcretetype(typeof(node_tracker))
        @test all(isconcretetype, fieldtypes(typeof(node_tracker)))
        @test Core.Compiler.return_type(current_info, Tuple{typeof(node_tracker)}) == NodeInfo
        @test Core.Compiler.return_type(has_current_info, Tuple{typeof(node_tracker)}) == Bool
        @test !has_current_info(node_tracker)
        @test_throws InvalidStateException current_info(node_tracker)

        initial_properties = Dict("media.name" => "test node", "node.driver" => "true")
        initial_params = [
            ParamInfo(UInt32(3), UInt32(1), UInt32(99), Int32(41)),
            ParamInfo(UInt32(4), UInt32(2), UInt32(99), Int32(42)),
        ]
        initial_node = NodeInfo(
            UInt32(7),
            UInt32(8),
            UInt32(9),
            NODE_CHANGE_PROPERTIES | NODE_CHANGE_PARAMS,
            UInt32(100),
            UInt32(101),
            PipeWireAO.NODE_STATE_RUNNING,
            "not part of this delta",
            initial_properties,
            initial_params,
        )
        invoke_tracker_info(node_tracker, initial_node)
        @test has_current_info(node_tracker)
        first_node = current_info(node_tracker)
        @test first_node isa NodeInfo
        @test first_node.id == 7
        @test first_node.max_input_ports == 8
        @test first_node.max_output_ports == 9
        @test first_node.n_input_ports == 0
        @test first_node.n_output_ports == 0
        @test first_node.state == PipeWireAO.NODE_STATE_CREATING
        @test first_node.error === nothing
        @test first_node.properties == initial_properties
        @test first_node.params == [
            ParamInfo(UInt32(3), UInt32(1), UInt32(1), Int32(0)),
            ParamInfo(UInt32(4), UInt32(2), UInt32(1), Int32(0)),
        ]

        state_only_node = NodeInfo(
            UInt32(70),
            UInt32(80),
            UInt32(90),
            NODE_CHANGE_STATE,
            UInt32(0),
            UInt32(0),
            PipeWireAO.NODE_STATE_ERROR,
            "node failed",
            Dict{String,String}(),
            ParamInfo[],
        )
        raw_node_updates = NodeInfo[]
        raw_node_listener = tracker_raw_listener(node_tracker, (object, info) -> begin
            @test current_info(node_tracker) === first_node
            push!(raw_node_updates, info)
        end)
        try
            invoke_tracker_info(node_tracker, state_only_node; raw_listener=raw_node_listener)
            @test only(raw_node_updates).id == 70
            @test only(raw_node_updates).change_mask == NODE_CHANGE_STATE
            @test isempty(only(raw_node_updates).properties)
            @test isempty(only(raw_node_updates).params)
        finally
            close(raw_node_listener)
        end
        second_node = current_info(node_tracker)
        @test second_node.id == 7
        @test second_node.max_input_ports == 8
        @test second_node.max_output_ports == 9
        @test second_node.change_mask ==
              NODE_CHANGE_PROPERTIES | NODE_CHANGE_PARAMS | NODE_CHANGE_STATE
        @test second_node.state == PipeWireAO.NODE_STATE_ERROR
        @test second_node.error == "node failed"
        @test second_node.properties == initial_properties
        @test second_node.params == first_node.params
        @test first_node.state == PipeWireAO.NODE_STATE_CREATING

        updated_params = [
            ParamInfo(UInt32(30), UInt32(1), UInt32(88), Int32(51)),
            ParamInfo(UInt32(40), UInt32(7), UInt32(88), Int32(52)),
            ParamInfo(UInt32(50), UInt32(8), UInt32(88), Int32(53)),
        ]
        params_only_node = NodeInfo(
            UInt32(7),
            UInt32(8),
            UInt32(9),
            NODE_CHANGE_PARAMS,
            UInt32(0),
            UInt32(0),
            PipeWireAO.NODE_STATE_CREATING,
            nothing,
            Dict{String,String}(),
            updated_params,
        )
        invoke_tracker_info(node_tracker, params_only_node)
        third_node = current_info(node_tracker)
        @test third_node.params == [
            ParamInfo(UInt32(30), UInt32(1), UInt32(1), Int32(0)),
            ParamInfo(UInt32(40), UInt32(7), UInt32(2), Int32(0)),
            ParamInfo(UInt32(50), UInt32(8), UInt32(1), Int32(0)),
        ]

        cleared_properties_node = NodeInfo(
            UInt32(7),
            UInt32(8),
            UInt32(9),
            NODE_CHANGE_PROPERTIES,
            UInt32(0),
            UInt32(0),
            PipeWireAO.NODE_STATE_CREATING,
            nothing,
            Dict{String,String}(),
            ParamInfo[],
        )
        invoke_tracker_info(node_tracker, cleared_properties_node)
        @test isempty(current_info(node_tracker).properties)

        port_properties = Dict("port.name" => "input")
        port = invoke_tracker_info(
            port_tracker,
            PortInfo(
                UInt32(11),
                PipeWireAO.DIRECTION_INPUT,
                PORT_CHANGE_PROPERTIES,
                port_properties,
                ParamInfo[],
            ),
        )
        port = invoke_tracker_info(
            port_tracker,
            PortInfo(
                UInt32(99),
                PipeWireAO.DIRECTION_OUTPUT,
                PORT_CHANGE_PARAMS,
                Dict{String,String}(),
                [ParamInfo(UInt32(1), UInt32(2), UInt32(0), Int32(9))],
            ),
        )
        @test port.id == 11
        @test port.direction == PipeWireAO.DIRECTION_INPUT
        @test port.change_mask == PORT_CHANGE_PROPERTIES | PORT_CHANGE_PARAMS
        @test port.properties == port_properties
        @test only(port.params).user == 1
        @test only(port.params).sequence == 0

        device_properties = Dict("device.name" => "test")
        device = invoke_tracker_info(
            device_tracker,
            DeviceInfo(UInt32(12), DEVICE_CHANGE_PROPERTIES, device_properties, ParamInfo[]),
        )
        device = invoke_tracker_info(
            device_tracker,
            DeviceInfo(UInt32(98), UInt64(0), Dict{String,String}(), ParamInfo[]),
        )
        @test device.id == 12
        @test device.properties == device_properties

        format = Pod(Int32(44))
        link_properties = Dict("link.feedback" => "true")
        link = invoke_tracker_info(
            link_tracker,
            LinkInfo(
                UInt32(13),
                UInt32(1),
                UInt32(2),
                UInt32(3),
                UInt32(4),
                LINK_CHANGE_STATE | LINK_CHANGE_FORMAT | LINK_CHANGE_PROPERTIES,
                PipeWireAO.LINK_STATE_ACTIVE,
                nothing,
                format,
                link_properties,
            ),
        )
        state_only_link = LinkInfo(
            UInt32(97),
            UInt32(91),
            UInt32(92),
            UInt32(93),
            UInt32(94),
            LINK_CHANGE_STATE,
            PipeWireAO.LINK_STATE_ERROR,
            "link failed",
            nothing,
            Dict{String,String}(),
        )
        link = invoke_tracker_info(link_tracker, state_only_link)
        @test link.id == 13
        @test link.output_node_id == 1
        @test link.output_port_id == 2
        @test link.input_node_id == 3
        @test link.input_port_id == 4
        @test link.state == PipeWireAO.LINK_STATE_ERROR
        @test link.error == "link failed"
        @test link.format !== nothing
        @test pod_value(Int32, link.format) == 44
        @test link.properties == link_properties

        cleared_link = invoke_tracker_info(
            link_tracker,
            LinkInfo(
                UInt32(13),
                UInt32(1),
                UInt32(2),
                UInt32(3),
                UInt32(4),
                LINK_CHANGE_FORMAT | LINK_CHANGE_PROPERTIES,
                PipeWireAO.LINK_STATE_INIT,
                nothing,
                nothing,
                Dict{String,String}(),
            ),
        )
        @test cleared_link.format === nothing
        @test isempty(cleared_link.properties)

        # Public snapshots own their containers independently of native replacement.
        @test first_node.properties == initial_properties
        @test length(first_node.params) == 2
        @test pod_value(Int32, link.format) == 44
        @test link.properties == link_properties

        for tracker in (node_tracker, port_tracker, device_tracker, link_tracker)
            latest = current_info(tracker)
            raw = typeof(latest)[]
            raw_listener = tracker_raw_listener(tracker, (object, info) -> push!(raw, info))
            try
                invoke_tracker_info(tracker, latest; raw_listener)
                @test length(raw) == 1
                @test only(raw).change_mask == latest.change_mask
                @test only(raw).properties == latest.properties
                @test only(raw).properties !== latest.properties
            finally
                close(raw_listener)
            end

            retained = current_info(tracker)
            @test tracker.state.native != C_NULL
            # A callback already selected by dispatch can wait behind close. Its
            # state lock must prevent the native accumulator from being recreated.
            lock(tracker.state.lock)
            pending = @async tracker.listener.callbacks.on_info(
                tracker.listener.owner, Ptr{Cvoid}(C_NULL),
            )
            yield()
            try
                close(tracker)
                @test tracker.state.native == C_NULL
            finally
                unlock(tracker.state.lock)
            end
            wait(pending)
            close(tracker)
            finalize(tracker.state)
            @test tracker.state.native == C_NULL
            @test current_info(tracker) === retained
            invoke_tracker_info(tracker, latest)
            @test current_info(tracker) === retained
        end
    finally
        for tracker in (node_tracker, port_tracker, device_tracker, link_tracker)
            close(tracker)
        end
        destroy_object!(core, node)
        close(core)
        close(context)
    end

end

@testset "managed info tracker" begin
    context = Context()
    core = CoreConnection(context; self=true)
    registry = Registry(core)
    raw_info = NodeInfo[]
    node = create_object(
        core,
        "adapter",
        Node;
        properties=Dict(
            "factory.name" => "support.null-audio-sink",
            "node.name" => "pipewire.jl.info-tracker",
            "media.class" => "Audio/Sink",
        ),
        on_info=(node, info) -> push!(raw_info, info),
    )
    tracker = track_info!(node)
    bound_node = nothing
    try
        @test isopen(tracker)
        @test isconcretetype(typeof(tracker))
        @test all(isconcretetype, fieldtypes(typeof(tracker)))
        @test Core.Compiler.return_type(current_info, Tuple{typeof(tracker)}) == NodeInfo
        @test Core.Compiler.return_type(has_current_info, Tuple{typeof(tracker)}) == Bool

        roundtrip(node)
        @test has_current_info(tracker)
        info = current_info(tracker)
        @test current_info_allocations(tracker) == 0
        @test info isa NodeInfo
        @test info.change_mask ==
              NODE_CHANGE_INPUT_PORTS |
              NODE_CHANGE_OUTPUT_PORTS |
              NODE_CHANGE_STATE |
              NODE_CHANGE_PROPERTIES |
              NODE_CHANGE_PARAMS
        @test info.properties["node.name"] == "pipewire.jl.info-tracker"
        @test !isempty(raw_info)

        roundtrip(registry)
        node_global = only(
            global_object for global_object in globals(registry) if
            global_object.id == bound_id(node)
        )
        bound_node = bind(registry, node_global, Node)
        roundtrip(bound_node)
        @test proxy_id(bound_node) != typemax(UInt32)
        @test subscribe_params!(bound_node, [PipeWireAO.SPA.PARAM_PROPS]) === bound_node
        @test enum_params!(bound_node, PipeWireAO.SPA.PARAM_PROPS; count=1) === bound_node
        @test set_param!(
            bound_node,
            PipeWireAO.SPA.PARAM_FORMAT,
            Pod(audio_format_param()),
        ) === bound_node
        @test send_command!(
            bound_node,
            node_command(PipeWireAO.SPA.NODE_COMMAND_SUSPEND),
        ) === bound_node

        close(tracker)
        @test !isopen(tracker)
        @test isopen(node)
        @test current_info(tracker) === info
    finally
        bound_node === nothing || close(bound_node)
        close(tracker)
        destroy_object!(core, node)
        close(registry)
        close(core)
        close(context)
    end
end

@testset "info tracker teardown and callback errors" begin
    context = Context()
    core = CoreConnection(context; self=true)
    node = create_object(core, "adapter", Node; properties=Dict(
        "factory.name" => "support.null-audio-sink", "node.name" => "tracker-teardown",
    ))
    fixtures = [tracker_fixture(node, NodeInfo, PipeWireAO.LibPipeWire.pw_node_events,
        PipeWireAO._listener_node_events) for _ in 1:4]
    update = NodeInfo(UInt32(7), UInt32(8), UInt32(9), NODE_CHANGE_STATE,
        UInt32(0), UInt32(0), PipeWireAO.NODE_STATE_ERROR, "native error",
        Dict{String,String}(), ParamInfo[])
    try
        for tracker in fixtures
            invoke_tracker_info(tracker, update)
        end
        listener_finalized, state_finalized, owner_closed, invalid = fixtures
        retained = current_info(listener_finalized)
        finalize(listener_finalized.listener)
        @test listener_finalized.state.native == C_NULL
        @test !isopen(listener_finalized)
        @test current_info(listener_finalized) === retained

        retained = current_info(state_finalized)
        finalize(state_finalized.state)
        @test state_finalized.state.native == C_NULL
        @test current_info(state_finalized) === retained

        # Native callback conversion failures use the existing object/core
        # callback error path and retain the last successfully copied snapshot.
        retained = current_info(invalid)
        invoke_tracker_null(invalid.listener, PipeWireAO.LibPipeWire.pw_node_info)
        @test node.callback_error[] isa ArgumentError
        @test core.callback_state.error[] === node.callback_error[]
        @test current_info(invalid) === retained
        @test invalid.state.native != C_NULL
        malformed = Ref(PipeWireAO.LibPipeWire.pw_node_info(
            7, 8, 9, NODE_CHANGE_STATE, 0, 0, 123456, C_NULL, C_NULL, C_NULL, 0,
        ))
        invoke_tracker_native(invalid.listener, malformed)
        @test current_info(invalid) === retained
        @test invalid.state.native != C_NULL
        recovered = invoke_tracker_info(invalid, NodeInfo(
            UInt32(7), UInt32(8), UInt32(9), NODE_CHANGE_PROPERTIES,
            UInt32(0), UInt32(0), PipeWireAO.NODE_STATE_CREATING, nothing,
            Dict("node.name" => "recovered"), ParamInfo[],
        ))
        @test recovered.properties == Dict("node.name" => "recovered")
        @test recovered.state == retained.state
        @test recovered.error == retained.error
        @test retained.properties == Dict{String,String}()

        retained = current_info(owner_closed)
        close(node)
        @test !isopen(owner_closed)
        invoke_tracker_info(owner_closed, update)
        @test owner_closed.state.native == C_NULL
        @test current_info(owner_closed) === retained
    finally
        foreach(close, fixtures)
        close(node)
        close(core)
        close(context)
    end
end

@testset "info tracker conversion recovery" begin
    context = Context()
    core = CoreConnection(context; self=true)
    node = create_object(core, "adapter", Node; properties=Dict(
        "factory.name" => "support.null-audio-sink", "node.name" => "tracker-recovery",
    ))
    port = tracker_fixture(
        tracker_test_object(Port, node, PipeWireAO.LibPipeWire.pw_port_events), PortInfo,
        PipeWireAO.LibPipeWire.pw_port_events, PipeWireAO._listener_port_events,
    )
    links = [tracker_fixture(
        tracker_test_object(Link, node, PipeWireAO.LibPipeWire.pw_link_events), LinkInfo,
        PipeWireAO.LibPipeWire.pw_link_events, PipeWireAO._listener_link_events,
    ) for _ in 1:2]
    try
        malformed_port = Ref(PipeWireAO.LibPipeWire.pw_port_info(
            99, 123456, PORT_CHANGE_PROPERTIES, C_NULL, C_NULL, 0,
        ))
        invoke_tracker_native(port.listener, malformed_port)
        @test port.listener.owner.callback_error[] isa ArgumentError
        @test !has_current_info(port)
        @test port.state.native == C_NULL
        recovered_port = invoke_tracker_info(port, PortInfo(
            UInt32(7), PipeWireAO.DIRECTION_INPUT, PORT_CHANGE_PROPERTIES,
            Dict("port.name" => "recovered"), ParamInfo[],
        ))
        @test recovered_port.id == 7
        @test recovered_port.direction == PipeWireAO.DIRECTION_INPUT
        @test recovered_port.properties == Dict("port.name" => "recovered")
        retained_port = current_info(port)
        invoke_tracker_native(port.listener, malformed_port)
        @test current_info(port) === retained_port

        for link in links
            invoke_tracker_info(link, LinkInfo(
                UInt32(8), UInt32(1), UInt32(2), UInt32(3), UInt32(4),
                LINK_CHANGE_STATE | LINK_CHANGE_FORMAT | LINK_CHANGE_PROPERTIES,
                PipeWireAO.LINK_STATE_ACTIVE, nothing, Pod(Int32(44)),
                Dict("link.name" => "before failure"),
            ))
        end
        state_link, format_link = links
        retained_state = current_info(state_link)
        malformed_state = Ref(PipeWireAO.LibPipeWire.pw_link_info(
            99, 91, 92, 93, 94, LINK_CHANGE_STATE, 123456,
            C_NULL, C_NULL, C_NULL,
        ))
        invoke_tracker_native(state_link.listener, malformed_state)
        @test state_link.listener.owner.callback_error[] isa ArgumentError
        @test current_info(state_link) === retained_state

        # Allocate the full rejected body so this also tests the previous path,
        # which copied the format in native code before Julia rejected its size.
        oversized_format = zeros(UInt8, (1 << 20) + sizeof(PipeWireAO.LibPipeWire.spa_pod))
        retained_format = current_info(format_link)
        GC.@preserve oversized_format begin
            format_pointer = Ptr{PipeWireAO.LibPipeWire.spa_pod}(pointer(oversized_format))
            unsafe_store!(format_pointer, PipeWireAO.LibPipeWire.spa_pod(
                1 << 20, PipeWireAO.LibPipeWire.SPA_TYPE_Int,
            ))
            malformed_format = Ref(PipeWireAO.LibPipeWire.pw_link_info(
                8, 1, 2, 3, 4, LINK_CHANGE_FORMAT,
                Int32(PipeWireAO.LINK_STATE_ACTIVE), C_NULL, format_pointer, C_NULL,
            ))
            invoke_tracker_native(format_link.listener, malformed_format)
        end
        @test format_link.listener.owner.callback_error[] isa ArgumentError
        @test current_info(format_link) === retained_format

        for link in links
            recovered_link = invoke_tracker_info(link, LinkInfo(
                UInt32(8), UInt32(1), UInt32(2), UInt32(3), UInt32(4),
                LINK_CHANGE_PROPERTIES, PipeWireAO.LINK_STATE_INIT, nothing, nothing,
                Dict("link.name" => "recovered"),
            ))
            @test recovered_link.properties == Dict("link.name" => "recovered")
            @test recovered_link.state == PipeWireAO.LINK_STATE_ACTIVE
            @test pod_value(Int32, recovered_link.format) == 44
            @test recovered_link.error === nothing
        end
        @test retained_state.properties == Dict("link.name" => "before failure")
        @test retained_format.properties == Dict("link.name" => "before failure")
    finally
        close(port)
        foreach(close, links)
        close(node)
        close(core)
        close(context)
    end
end
