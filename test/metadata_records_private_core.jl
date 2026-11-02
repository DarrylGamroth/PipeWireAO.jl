include("native_sdk.jl")
using PipeWireAO, Test
include("private_core.jl")

function properties_link(core, registry, source, sink)
    ports(direction, node) = find_globals(registry; interface="PipeWire:Interface:Port",
        properties=("node.id" => string(node_id(node)), "port.direction" => direction))
    timedwait(10; pollint=0.01) do
        roundtrip(registry)
        !isempty(ports("out", source)) && !isempty(ports("in", sink))
    end == :ok || error("properties stream ports did not appear")
    output, input = only(ports("out", source)), only(ports("in", sink))
    return with_thread_loop_lock(main_loop(core)) do _
        create_object(core, "link-factory", Link; properties=Dict(
            "link.output.node" => string(node_id(source)), "link.output.port" => string(output.id),
            "link.input.node" => string(node_id(sink)), "link.input.port" => string(input.id),
            "object.linger" => "false",
        ))
    end
end

function metadata_callback_copy!(input, output)
    properties = metadata_records(input)
    properties isa MetadataRecords{false} || error("input records must be read-only")
    metadata_record(properties, UInt32(0x900)) === nothing && error("required metadata is missing")
    copyto!(bytes(output), bytes(input))
    propagate_metadata!(output, input)
    return nothing
end

@testset "private-core independent metadata through an ndarray callback" begin
    Threads.nthreads(:default)>=2 && Threads.nthreads(:interactive)>=1 ||
        error("blocking native filter fixture requires --threads=2,1 or more")
    with_array_exchange_private_core() do remote
        loop = ThreadLoop("test.buffer.properties")
        context, core, registry = with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties=Dict("remote.name" => remote))
            context, core, Registry(core)
        end
        start!(loop)
        source = sink = input_link = output_link = filter = filter_task = nothing
        pending = Threads.Atomic{Bool}(false)
        sequence = Ref(UInt64(0))
        expected = Ref{Union{Nothing,OpticalClassification}}(nothing)
        received = Tuple{UInt64,Union{Nothing,OpticalClassification},AcquisitionTriggerState,Int64}[]
        source_buffer, sink_buffer = StreamBuffer(), StreamBuffer()
        callback_allocations = Threads.Atomic{Int}(-1)
        format = NdArrayFormat(NdArray.U8, (4,); layout=NdArray.ROW_MAJOR)
        layouts=(MetadataRequirement(SPA.META_OPTICAL_CHOPPING),MetadataRequirement(SPA.META_ELECTRICAL_TRIGGER;required=true),MetadataRequirement(0x900,8;required=true))
        buffer_parameters = (Pod(buffers_param(buffers=2, blocks=1, size=4)),
            Pod(header_metadata_param()),
            (Pod(metadata_param(r)) for r in layouts)...)
        function parameter_changed(stream, id, parameter)
            id == SPA.PARAM_FORMAT && parameter !== nothing && update_params!(stream, buffer_parameters)
            return nothing
        end
        function produce(stream)
            pending[] || return nothing
            dequeue_buffer!(source_buffer, stream) || return nothing
            queued = false
            try
                data = buffer_data(source_buffer)
                fill!(buffer_memory(data, 4), UInt8(sequence[]))
                set_chunk!(data; size=4, stride=1)
                set_buffer_size!(source_buffer, 4)
                initialize_metadata!(source_buffer)
                set_buffer_header!(source_buffer, BufferHeader(0, 0, Int64(sequence[]), 0, sequence[]))
                properties = writable_metadata_records(source_buffer)
                expected[] === nothing || set_optical_classification!(properties, expected[])
                set_trigger_classification!(properties, ACQUISITION_TRIGGER_LOW)
                set_metadata_bytes!(properties,UInt32(0x900),ntuple(i -> UInt8(((sequence[]+100) >> (8*(i-1))) & 0xff),8))
                queue_buffer!(source_buffer, stream)
                queued = true
                pending[] = false
            finally
                queued || return_buffer!(source_buffer, stream)
            end
            return nothing
        end
        function consume(stream)
            dequeue_buffer!(sink_buffer, stream) || return nothing
            try
                properties = metadata_records(sink_buffer)
                properties === nothing && error("negotiated properties are missing")
                metadata_records_valid(properties) || error("received malformed properties")
                push!(received, (buffer_header(sink_buffer).sequence,
                    optical_classification(properties),
                    something(trigger_classification(properties)),
                    Int64(sum(UInt64(byte) << (8*(i-1)) for (i,byte) in enumerate(metadata_bytes(something(metadata_record(properties,UInt32(0x900)))))))))
            finally
                queue_buffer!(sink_buffer, stream)
            end
            return nothing
        end
        try
            source, sink = with_thread_loop_lock(loop) do _
                source = Stream(core, "test.properties.source";
                    properties=Dict("node.name" => "test.properties.source", "media.type" => "Application",
                        "media.category" => "Filter", "node.reliable" => "true", "node.want-driver" => "true"),
                    on_process=produce, on_param_changed=parameter_changed)
                sink = Stream(core, "test.properties.sink";
                    properties=Dict("node.name" => "test.properties.sink", "media.type" => "Application",
                        "media.category" => "Filter", "node.reliable" => "true"),
                    on_process=consume, on_param_changed=parameter_changed)
                flags = STREAM_INACTIVE | STREAM_MAP_BUFFERS | STREAM_DONT_RECONNECT | STREAM_NO_CONVERT
                parameters = (ndarray_format(format; schema="test.properties/1"), buffer_parameters...)
                connect!(source, :output; flags=flags | STREAM_DRIVER, params=parameters)
                connect!(sink, :input; flags, params=parameters)
                source, sink
            end
            ready = Channel{Any}(1)
            filter_task = Threads.@spawn begin
                native_filter = nothing
                try
                    requirement = layouts
                    ports = (
                        NdArrayFilterPort("input", PipeWireAO.DIRECTION_INPUT, format;
                            schema="test.properties/1",
                            metadata=requirement,propagation=:preserve),
                        NdArrayFilterPort("output", PipeWireAO.DIRECTION_OUTPUT, format;
                            schema="test.properties/1",
                            metadata=requirement,propagation=:preserve),
                    )
                    native_filter = NdArrayFilter("test.properties.filter", ports; remote,
                        on_process=(filter, inputs, outputs) -> begin
                            metadata_callback_copy!(inputs[1], outputs[1])
                            if callback_allocations[] < 0
                                callback_allocations[] = @allocated metadata_callback_copy!(inputs[1], outputs[1])
                            end
                            nothing
                        end)
                    connect!(native_filter)
                    put!(ready, native_filter)
                    run!(native_filter)
                catch error
                    isready(ready) || put!(ready, error)
                    rethrow()
                finally
                    native_filter === nothing || close(native_filter)
                end
            end
            filter = take!(ready)
            filter isa Exception && throw(filter)
            input_link = properties_link(core, registry, source, filter)
            output_link = properties_link(core, registry, filter, sink)
            roundtrip(core)
            with_thread_loop_lock(loop) do _
                set_active!(sink, true)
                set_active!(source, true)
            end
            classifications = (OPTICAL_FRINGED, nothing, OPTICAL_UNFRINGED, OPTICAL_MIXED,
                OPTICAL_ABSENT, nothing, OPTICAL_FRINGED, nothing)
            for (index, classification) in enumerate(classifications)
                with_thread_loop_lock(loop) do _
                    sequence[] = UInt64(index)
                    expected[] = classification
                    pending[] = true
                end
                completed = timedwait(10; pollint=0.01) do
                    with_thread_loop_lock(loop) do _
                        if stream_state(source) == PipeWireAO.LibPipeWire.PW_STREAM_STATE_STREAMING && is_driving(source)
                            trigger_process!(source)
                        end
                        PipeWireAO._check_callback_error(source)
                        PipeWireAO._check_callback_error(sink)
                        length(received) >= index
                    end
                end
                completed == :ok || error("properties deadline: pending=$(pending[]), source=$(stream_state(source)), sink=$(stream_state(sink)), filter=$(filter_state(filter)), failure=$(last_error(filter)), callback=$(filter.callback_error[]), task_done=$(istaskdone(filter_task)), allocations=$(callback_allocations[])")
                @test completed == :ok
                with_thread_loop_lock(loop) do _
                    @test received[index] == (UInt64(index), classification, ACQUISITION_TRIGGER_LOW, Int64(index + 100))
                end
            end
            @test callback_allocations[] == 0
        finally
            with_thread_loop_lock(loop) do _
                input_link === nothing || close(input_link)
                output_link === nothing || close(output_link)
                sink === nothing || close(sink)
                source === nothing || close(source)
                close(registry)
                close(core)
                close(context)
            end
            filter isa NdArrayFilter && isopen(filter) && quit!(filter)
            filter_task === nothing || fetch(filter_task)
            close(loop)
        end
    end
end
