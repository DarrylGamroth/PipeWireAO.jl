using PipeWireAO_jll

function _wait_for_pipewireao_socket(path::AbstractString, process::Base.Process)
    deadline = time_ns() + UInt64(5_000_000_000)
    while time_ns() < deadline
        ispath(path) && return nothing
        process_running(process) || error("the PipeWireAO test daemon exited early")
        sleep(0.025)
    end
    error("the PipeWireAO test daemon did not create its socket")
end

function _with_isolated_pipewireao(operation)
    artifact = dirname(dirname(PipeWireAO_jll.libpipewire_ao_path))
    daemon = joinpath(artifact, "bin", "pipewire-ao")
    isfile(daemon) || error("the PipeWireAO artifact has no daemon executable")

    return mktempdir(; prefix="pipewireao-julia-") do directory
        runtime = joinpath(directory, "runtime")
        mkdir(runtime)
        log_path = joinpath(directory, "daemon.log")
        log = open(log_path, "w")
        overrides = "{ module.scheduler-v1 = false module.rt = false " *
                    "module.profiler = false module.spa-device-factory = false " *
                    "module.spa-node-factory = false module.client-device = false " *
                    "module.portal = false module.adapter = false " *
                    "factory.dummy-driver = false factory.freewheel-driver = false }"
        environment = copy(ENV)
        environment["XDG_RUNTIME_DIR"] = runtime
        environment["PIPEWIREAO_RUNTIME_DIR"] = runtime
        environment["PIPEWIREAO_REMOTE"] = "pipewire-ao"
        environment["PIPEWIREAO_CORE"] = "pipewire-ao"
        process = run(
            pipeline(
                setenv(`$daemon -c pipewire.conf -P $overrides`, environment),
                stdout=log,
                stderr=log,
            );
            wait=false,
        )
        try
            _wait_for_pipewireao_socket(joinpath(runtime, "pipewire-ao"), process)
            return withenv(
                "XDG_RUNTIME_DIR" => runtime,
                "PIPEWIREAO_RUNTIME_DIR" => runtime,
                "PIPEWIREAO_REMOTE" => "pipewire-ao",
            ) do
                operation()
            end
        catch
            flush(log)
            println(stderr, read(log_path, String))
            rethrow()
        finally
            process_running(process) && kill(process)
            wait(process)
            close(log)
        end
    end
end

function _wait_for_filter_nodes(registry, source, sink)
    deadline = time_ns() + UInt64(5_000_000_000)
    while time_ns() < deadline
        roundtrip(registry)
        source_id = node_id(source)
        sink_id = node_id(sink)
        source_id != typemax(UInt32) && sink_id != typemax(UInt32) &&
            return source_id, sink_id
        sleep(0.01)
    end
    error("the PipeWireAO filter nodes did not become visible")
end

function _latest_port_id(registry, node::UInt32, direction::AbstractString)
    roundtrip(registry)
    matches = filter(globals(registry)) do global_object
        global_object.type == "PipeWire:Interface:Port" || return false
        properties = global_object.properties
        get(properties, "node.id", "") == string(node) || return false
        get(properties, "port.name", "") == "latest" || return false
        return get(properties, "port.direction", "") == direction
    end
    length(matches) == 1 || error("expected one $direction latest-buffer port")
    return only(matches).id
end

function _wait_for_active_link(registry, latest)
    deadline = time_ns() + UInt64(5_000_000_000)
    while time_ns() < deadline
        roundtrip(registry)
        info = latest[]
        info !== nothing && info.state == PipeWireAO.LINK_STATE_ACTIVE && return info
        info !== nothing && info.error !== nothing && error("latest-buffer link: $(info.error)")
        sleep(0.01)
    end
    error("the PipeWireAO latest-buffer link did not become active")
end

function _dequeue_latest!(buffer, port)
    deadline = time_ns() + UInt64(5_000_000_000)
    while time_ns() < deadline
        dequeue_buffer!(buffer, port) && return buffer
        sleep(0.001)
    end
    error("the PipeWireAO output port had no reusable latest buffer")
end

function _begin_progressive_allocations(lease, buffer)
    return @allocated begin_progressive!(lease, buffer)
end

function _end_progressive_allocations(lease)
    return @allocated end_progressive!(lease)
end

function _buffer_latest_fd_allocations(port)
    return @allocated buffer_latest_fd(port)
end

@testset "scheduler-independent progressive filter buffer" begin
    _with_isolated_pipewireao() do
        context = Context()
        core = nothing
        registry = nothing
        source = nothing
        sink = nothing
        link = nothing
        lease = nothing
        try
            core = CoreConnection(context)
            registry = Registry(core)
            source = Filter(
                core,
                "Julia progressive source";
                properties=Dict(
                    "media.name" => "julia.progressive.source",
                    "media.type" => "Audio",
                    "media.category" => "Playback",
                ),
            )
            sink = Filter(
                core,
                "Julia progressive sink";
                properties=Dict(
                    "media.name" => "julia.progressive.sink",
                    "media.type" => "Audio",
                    "media.category" => "Capture",
                ),
            )
            memory = Int32(1 << PipeWireAO.LibPipeWire.SPA_DATA_MemPtr)
            params = [
                audio_format(format=Audio.F32, rate=1_000, channels=1),
                buffers_param(
                    buffers=3,
                    blocks=1,
                    size=256,
                    stride=4,
                    data_types=SPA.Choice(SPA.CHOICE_FLAGS, Int32[memory]),
                ),
            ]
            output = add_port!(
                source,
                :output;
                flags=FILTER_PORT_MAP_BUFFERS,
                properties=Dict("port.name" => "latest"),
                params,
            )
            input = add_port!(
                sink,
                :input;
                flags=FILTER_PORT_MAP_BUFFERS,
                properties=Dict(
                    "port.name" => "latest",
                    BUFFER_LATEST_WAIT_PROPERTY => BUFFER_LATEST_WAIT_EVENTFD,
                ),
                params,
            )
            connect!(source; flags=FILTER_ASYNC | FILTER_TRIGGER)
            connect!(sink; flags=FILTER_ASYNC | FILTER_TRIGGER)
            source_id, sink_id = _wait_for_filter_nodes(registry, source, sink)
            output_id = _latest_port_id(registry, source_id, "out")
            input_id = _latest_port_id(registry, sink_id, "in")
            latest = Ref{Union{Nothing,LinkInfo}}(nothing)
            link = create_object(
                core,
                "link-factory",
                Link;
                properties=Dict(
                    "link.output.node" => string(source_id),
                    "link.output.port" => string(output_id),
                    "link.input.node" => string(sink_id),
                    "link.input.port" => string(input_id),
                    BUFFER_LATEST_LINK_PROPERTY => "true",
                    "object.linger" => "false",
                ),
                on_info=(_, info) -> (info === nothing || (latest[] = info)),
            )
            @test _wait_for_active_link(registry, latest).state ==
                  PipeWireAO.LINK_STATE_ACTIVE

            output_fd = buffer_latest_fd(output)
            @test output_fd >= 0
            @test buffer_latest_fd(input) >= 0
            _buffer_latest_fd_allocations(output)
            @test _buffer_latest_fd_allocations(output) == 0

            buffer = FilterBuffer()
            lease = ProgressiveFilterBuffer(output)
            @test isconcretetype(typeof(lease))
            @test all(isconcretetype, fieldtypes(typeof(lease)))
            @test !progressive_active(lease)
            @test_throws InvalidStateException unsafe_progressive_buffer_pointer(lease)
            @test_throws InvalidStateException end_progressive!(lease)

            # Warm the exact begin/end calls, including the allocation probes.
            _dequeue_latest!(buffer, output)
            begin_progressive!(lease, buffer)
            _end_progressive_allocations(lease)
            _dequeue_latest!(buffer, output)
            _begin_progressive_allocations(lease, buffer)
            @test _end_progressive_allocations(lease) == 0

            _dequeue_latest!(buffer, output)
            pointer = buffer.handle
            @test pointer != C_NULL
            @test _begin_progressive_allocations(lease, buffer) == 0
            @test progressive_active(lease)
            @test buffer.handle == C_NULL
            @test buffer.port_data == C_NULL
            @test unsafe_progressive_buffer_pointer(lease) == pointer
            @test_throws InvalidStateException buffer_data(buffer)
            @test_throws InvalidStateException begin_progressive!(lease, buffer)
            @test _end_progressive_allocations(lease) == 0
            @test !progressive_active(lease)
            @test_throws InvalidStateException end_progressive!(lease)
        finally
            if lease !== nothing && progressive_active(lease)
                try
                    end_progressive!(lease)
                catch
                end
            end
            link === nothing || close(link)
            source === nothing || close(source)
            sink === nothing || close(sink)
            registry === nothing || close(registry)
            core === nothing || close(core)
            close(context)
        end
    end
end
