using PipeWireAO
using Test

function array_exchange_link(core, registry, source, sink)
    timedwait(10; pollint=0.01) do
        roundtrip(registry)
        return !isempty(find_globals(registry; interface="PipeWire:Interface:Port",
            properties=("node.id" => string(node_id(source)), "port.direction" => "out"))) &&
            !isempty(find_globals(registry; interface="PipeWire:Interface:Port",
            properties=("node.id" => string(node_id(sink)), "port.direction" => "in")))
    end == :ok || error("ndarray stream port deadline expired")
    output = only(find_globals(registry; interface="PipeWire:Interface:Port",
        properties=("node.id" => string(node_id(source)), "port.direction" => "out")))
    input = only(find_globals(registry; interface="PipeWire:Interface:Port",
        properties=("node.id" => string(node_id(sink)), "port.direction" => "in")))
    return with_thread_loop_lock(main_loop(core)) do _
        create_object(core, "link-factory", Link; properties=Dict(
            "link.output.node" => string(node_id(source)), "link.output.port" => string(output.id),
            "link.input.node" => string(node_id(sink)), "link.input.port" => string(input.id),
            "object.linger" => "false",
        ))
    end
end

include("private_core.jl")

@testset "private-core prepared ndarray producer to sink" begin
    with_array_exchange_private_core() do remote
        loop = ThreadLoop("test.ndarray.exchange")
        context, core, registry = with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties=Dict("remote.name" => remote))
            return context, core, Registry(core)
        end
        start!(loop)
        try
            roundtrip(core)
            domain = AcquisitionDomain(ntuple(i -> UInt8(i), ACQUISITION_DOMAIN_SIZE))
            for (T, element, values) in ((Float32, NdArray.F32_LE, Float32[1, 2, 3, 4]),
                                         (UInt16, NdArray.U16_LE, UInt16[0, 1, 512, 65535]),
                                         (Bool, NdArray.BOOL8, Bool[false, true, false, true]))
                format = NdArrayFormat(element, (2, 2); layout=NdArray.ROW_MAJOR, rate=SPA.Fraction(1000, 1))
                source = NdArraySource(core, "test.ndarray.source.$T", zeros(T, 4), format; schema="test.ndarray.$T/1")
                sink = NdArraySink(core, "test.ndarray.sink.$T", zeros(T, 4), format; schema="test.ndarray.$T/1")
                link = nothing
                loans = StreamBuffer[]
                try
                    link = array_exchange_link(core, registry, source, sink)
                    roundtrip(core)
                    start!(sink)
                    start!(source)
                    for generation in UInt64(1):UInt64(2), sequence in UInt64(1):UInt64(3)
                        identity = AcquisitionIdentity(domain, generation, sequence)
                        expected = generation == 1 ? sequence : identity
                        arm_array_sink!(sink, expected; exposure_duration_ns=10)
                        if generation == 1 && sequence == 2
                            with_thread_loop_lock(loop) do _
                                while true
                                    buffer = StreamBuffer()
                                    dequeue_buffer!(buffer, source.stream) || break
                                    push!(loans, buffer)
                                end
                            end
                            @test length(loans) >= 2
                        end
                        header = BufferHeader(UInt32(0), UInt32(0), Int64(sequence), Int64(0), sequence)
                        token = with_thread_loop_lock(loop) do _
                            token = submit_array!(source, values, header; identity, exposure_duration_ns=10)
                            if generation == 1 && sequence == 3
                                @test @allocated(source.stream.callbacks.on_process(source.stream)) == 0
                                @test source.state.phase[] == PipeWireAO._ARRAY_COMPLETE
                            end
                            return token
                        end
                        @test token == (generation - 1) * 3 + sequence
                        if !isempty(loans)
                            returned = @async begin
                                sleep(0.02)
                                @test source.state.phase[] == PipeWireAO._ARRAY_PENDING
                                with_thread_loop_lock(loop) do _
                                    foreach(buffer -> return_buffer!(buffer, source.stream), loans)
                                    empty!(loans)
                                end
                            end
                            wait_array_source!(source, token; timeout_ns=10_000_000_000)
                            fetch(returned)
                        else
                            wait_array_source!(source, token; timeout_ns=10_000_000_000)
                        end
                        receipt = wait_array_sink!(sink; timeout_ns=10_000_000_000)
                        @test receipt.header == header
                        @test receipt.identity == identity
                        @test receipt.exposure_duration_ns == UInt64(10)
                        @test array_values(sink) == values
                    end
                    # The previous completed slot must not accept a duplicate.
                    token = submit_array!(source, values, BufferHeader(UInt32(0), UInt32(0), Int64(0), Int64(0), UInt64(3)))
                    wait_array_source!(source, token; timeout_ns=10_000_000_000)
                    @test timedwait(() -> sink.state.phase[] == PipeWireAO._ARRAY_FAILED, 10; pollint=0.001) == :ok
                    @test_throws InvalidStateException array_values(sink)
                    @test_throws InvalidStateException arm_array_sink!(sink, UInt64(4))
                finally
                    with_thread_loop_lock(loop) do _
                        foreach(buffer -> return_buffer!(buffer, source.stream), loans)
                        link === nothing || close(link)
                    end
                    close(sink)
                    close(source)
                end
                @test isopen(core)
            end
            for failure in (:wrong_sequence, :wrong_identity, :unarmed, :late, :disconnect)
                format = NdArrayFormat(NdArray.F32_LE, (1,); layout=NdArray.ROW_MAJOR)
                source = NdArraySource(core, "test.ndarray.fail.source.$failure", zeros(Float32, 1), format)
                sink = NdArraySink(core, "test.ndarray.fail.sink.$failure", zeros(Float32, 1), format)
                link = nothing
                try
                    link = array_exchange_link(core, registry, source, sink)
                    roundtrip(core)
                    start!(sink)
                    start!(source)
                    identity = AcquisitionIdentity(domain, UInt64(1), UInt64(1))
                    if failure == :wrong_sequence
                        arm_array_sink!(sink, UInt64(2))
                    elseif failure == :wrong_identity
                        arm_array_sink!(sink, AcquisitionIdentity(domain, UInt64(2), UInt64(1)))
                    elseif failure in (:late, :disconnect)
                        arm_array_sink!(sink, identity)
                    end
                    if failure == :late
                        @test_throws InvalidStateException wait_array_sink!(sink; timeout_ns=1_000_000)
                    end
                    if failure == :disconnect
                        waiter = @async try
                            wait_array_sink!(sink; timeout_ns=10_000_000_000)
                        catch error
                            error
                        end
                        @test timedwait(() -> sink.state.waiting[], 1; pollint=0.001) == :ok
                        with_thread_loop_lock(loop) do _
                            disconnect!(sink.stream)
                        end
                        @test timedwait(() -> istaskdone(waiter), 1; pollint=0.001) == :ok
                        @test typeof(fetch(waiter)) == InvalidStateException
                    else
                        token = submit_array!(source, Float32[7], BufferHeader(UInt32(0), UInt32(0), Int64(0), Int64(0), UInt64(1)); identity)
                        wait_array_source!(source, token; timeout_ns=10_000_000_000)
                        @test timedwait(() -> sink.state.phase[] == PipeWireAO._ARRAY_FAILED, 10; pollint=0.001) == :ok
                        @test sink.state.values == Float32[0]
                        expected_error = failure in (:unarmed, :late) ? InvalidStateException : ArgumentError
                        @test_throws expected_error wait_array_sink!(sink; timeout_ns=1_000_000_000)
                    end
                    expected_error = failure in (:unarmed, :late, :disconnect) ? InvalidStateException : ArgumentError
                    @test_throws expected_error arm_array_sink!(sink, UInt64(3))
                finally
                    with_thread_loop_lock(loop) do _
                        link === nothing || close(link)
                    end
                    close(sink)
                    close(source)
                end
            end
        finally
            with_thread_loop_lock(loop) do _
                close(registry)
                close(core)
                close(context)
            end
            close(loop)
        end
    end
end
