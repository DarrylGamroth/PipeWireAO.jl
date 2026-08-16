using PipeWireAO
using Test

function current_info_allocations(tracker)
    current_info(tracker)
    return @allocated current_info(tracker)
end

@testset "maintained current object info" begin
    node_state = PipeWireAO._CurrentInfoState{NodeInfo}(
        ReentrantLock(),
        Ref{NodeInfo}(),
        false,
    )
    node_tracker = InfoTracker(node_state, nothing)
    node_callback = PipeWireAO._CurrentInfoCallback{Nothing,NodeInfo}(node_state)

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
    node_callback(nothing, initial_node)
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
    @test first_node.properties === initial_properties
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
    node_callback(nothing, state_only_node)
    second_node = current_info(node_tracker)
    @test second_node.id == 7
    @test second_node.max_input_ports == 8
    @test second_node.max_output_ports == 9
    @test second_node.change_mask ==
          NODE_CHANGE_PROPERTIES | NODE_CHANGE_PARAMS | NODE_CHANGE_STATE
    @test second_node.state == PipeWireAO.NODE_STATE_ERROR
    @test second_node.error == "node failed"
    @test second_node.properties === initial_properties
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
    node_callback(nothing, params_only_node)
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
    node_callback(nothing, cleared_properties_node)
    @test isempty(current_info(node_tracker).properties)

    port_properties = Dict("port.name" => "input")
    port = PipeWireAO._merge_info(
        nothing,
        PortInfo(
            UInt32(11),
            PipeWireAO.DIRECTION_INPUT,
            PORT_CHANGE_PROPERTIES,
            port_properties,
            ParamInfo[],
        ),
    )
    port = PipeWireAO._merge_info(
        port,
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
    @test port.properties === port_properties
    @test only(port.params).user == 1
    @test only(port.params).sequence == 0

    device_properties = Dict("device.name" => "test")
    device = PipeWireAO._merge_info(
        nothing,
        DeviceInfo(UInt32(12), DEVICE_CHANGE_PROPERTIES, device_properties, ParamInfo[]),
    )
    device = PipeWireAO._merge_info(
        device,
        DeviceInfo(UInt32(98), UInt64(0), Dict{String,String}(), ParamInfo[]),
    )
    @test device.id == 12
    @test device.properties === device_properties

    format = Pod(Int32(44))
    link_properties = Dict("link.feedback" => "true")
    link = PipeWireAO._merge_info(
        nothing,
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
    link = PipeWireAO._merge_info(link, state_only_link)
    @test link.id == 13
    @test link.output_node_id == 1
    @test link.output_port_id == 2
    @test link.input_node_id == 3
    @test link.input_port_id == 4
    @test link.state == PipeWireAO.LINK_STATE_ERROR
    @test link.error == "link failed"
    @test link.format === format
    @test link.properties === link_properties

    cleared_link = PipeWireAO._merge_info(
        link,
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
