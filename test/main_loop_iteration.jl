using PipeWireAO, Test

@testset "nonblocking MainLoop iteration" begin
    loop = MainLoop()
    callbacks = Ref(0)
    recursive = Ref{Any}(nothing)
    closing = Ref{Any}(nothing)
    source = EventSource(loop, (_source, _count) -> begin
        callbacks[] += 1
        recursive[] = try
            iterate!(loop)
        catch error
            error
        end
        closing[] = try
            close(loop)
        catch error
            error
        end
        nothing
    end)
    try
        @test iterate!(loop; max_dispatches=0) == 0
        @test iterate!(loop; max_dispatches=2) == 0
        @test_throws ArgumentError iterate!(loop; max_dispatches=-1)
        @test_throws ArgumentError iterate!(loop; max_dispatches=big(typemax(Int)) + 1)
        signal!(source)
        @test iterate!(loop; max_dispatches=0) == 0
        @test callbacks[] == 0
        @test iterate!(loop; max_dispatches=1) == 1
        @test callbacks[] == 1
        @test recursive[] isa InvalidStateException
        @test recursive[].state === :running
        @test closing[] isa InvalidStateException
        @test !loop.running
        @test iterate!(loop; max_dispatches=2) == 0

        # Static assignment guarantees at least one other OS thread, unlike a
        # spawned task which could resume on the creating thread while we wait.
        owner = Threads.threadid()
        failures = Any[nothing for _ in 1:Threads.nthreads(:default)]
        Threads.@threads :static for index in eachindex(failures)
            if Threads.threadid() != owner
                failures[index] = try
                    iterate!(loop)
                catch error
                    error
                end
            end
        end
        others = filter(!isnothing, failures)
        if isempty(others)
            @test_skip "wrong-thread rejection requires another Julia thread"
        else
            @test all(error -> error isa InvalidStateException &&
                error.state === :wrong_thread, others)
        end
        # Rejection does not enter the native loop or consume pending work.
        signal!(source)
        @test iterate!(loop) == 1
        @test callbacks[] == 2
    finally
        close(source)
        close(loop)
    end
    @test_throws InvalidStateException iterate!(loop)
end

@testset "native iteration limit is not a callback count" begin
    loop = MainLoop()
    callbacks = Ref(0)
    sources = [EventSource(loop, (_source, _count) -> (callbacks[] += 1; nothing))
        for _ in 1:3]
    try
        foreach(signal!, sources)
        @test iterate!(loop; max_dispatches=1) == 1
        @test callbacks[] == 3
        @test iterate!(loop) == 0
    finally
        foreach(close, sources)
        close(loop)
    end
end

include("private_core.jl")

function pump_until(predicate, loop; timeout=5.0)
    deadline = time_ns() + round(UInt64, timeout * 1e9)
    while !predicate() && time_ns() < deadline
        iterate!(loop; max_dispatches=8)
        predicate() || sleep(0.001)
    end
    return predicate()
end

@testset "actual enumeration sequence and asynchronous core fence" begin
    with_array_exchange_private_core() do remote
        loop = MainLoop()
        context = Context(loop)
        done = Tuple{UInt32,Cint}[]
        core = CoreConnection(context; properties=Dict("remote.name" => remote),
            on_done=(_core, id, sequence) -> (push!(done, (id, sequence)); nothing))
        registry = Registry(core)
        records = Tuple{Cint,UInt32,Pod}[]
        format_records = Tuple{Cint,UInt32,Pod}[]
        node = port = filter = nothing
        try
            initial = ntuple(index -> Pod(props_param(SPA.Props("value" => Int64(index)))), 3)
            filter = Filter(core, "test.enumeration.sequence";
                properties=Dict("node.name" => "test.enumeration.sequence"))
            format = NdArrayFormat(NdArray.F32_LE, (4,); layout=NdArray.ROW_MAJOR)
            add_port!(filter, :output; properties=Dict("port.name" => "science"),
                params=(ndarray_format(format; schema="test.enumeration/1"),))
            connect!(filter; flags=FILTER_INACTIVE, params=initial)
            @test pump_until(loop) do
                !isempty(find_globals(registry; interface="PipeWire:Interface:Node",
                    properties=("node.name" => "test.enumeration.sequence",)))
            end
            global_node = only(find_globals(registry; interface="PipeWire:Interface:Node",
                properties=("node.name" => "test.enumeration.sequence",)))
            node = bind(registry, global_node, Node;
                on_param=(_node, sequence, id, _index, _next, pod) -> begin
                    pod === nothing || push!(records, (sequence, id, pod))
                    nothing
                end)
            @test pump_until(loop) do
                !isempty(find_globals(registry; interface="PipeWire:Interface:Port",
                    properties=("node.id" => string(global_node.id),)))
            end
            global_port = only(find_globals(registry; interface="PipeWire:Interface:Port",
                properties=("node.id" => string(global_node.id),)))
            port = bind(registry, global_port, Port;
                on_param=(_port, sequence, id, _index, _next, pod) -> begin
                    pod === nothing || push!(format_records, (sequence, id, pod))
                    nothing
                end)
            binding_fence = sync!(core)
            @test pump_until(loop) do
                (UInt32(0), binding_fence) in done
            end
            first_sequence, second_sequence, port_sequence = Ref(Cint(-1)), Ref(Cint(-1)), Ref(Cint(-1))
            @test enum_params!(node, SPA.PARAM_PROPS; sequence=123456,
                sequence_out=first_sequence) === node
            @test enum_params!(node, SPA.PARAM_PROPS; sequence=123456,
                sequence_out=second_sequence) === node
            @test enum_params!(port, SPA.PARAM_ENUM_FORMAT; sequence=123456,
                sequence_out=port_sequence) === port
            @test first_sequence[] != second_sequence[]
            @test first_sequence[] != 123456 && second_sequence[] != 123456
            @test port_sequence[] != 123456
            fence = sync!(core)
            @test pump_until(loop) do
                (UInt32(0), fence) in done
            end
            @test count(record -> record[1] == first_sequence[], records) == 3
            @test count(record -> record[1] == second_sequence[], records) == 3
            @test all(record -> record[1] in (first_sequence[], second_sequence[]) &&
                record[2] == SPA.PARAM_PROPS, records)
            @test !isempty(format_records)
            @test all(record -> record[1] == port_sequence[] &&
                record[2] == SPA.PARAM_ENUM_FORMAT, format_records)
            @test enum_params!(node, SPA.PARAM_PROPS) === node
            failure_sequence = Ref(Cint(-77))
            @test_throws ArgumentError enum_params!(node, SPA.PARAM_PROPS;
                sequence=big(typemax(Cint)) + 1, sequence_out=failure_sequence)
            @test failure_sequence[] == -77
            close(node)
            @test_throws InvalidStateException enum_params!(node, SPA.PARAM_PROPS;
                sequence_out=failure_sequence)
            @test failure_sequence[] == -77
            @test all(record -> !isempty(record[3].data), records)
        finally
            port === nothing || close(port)
            node === nothing || close(node)
            filter === nothing || close(filter)
            close(registry)
            close(core)
            close(context)
            close(loop)
        end
    end
end
