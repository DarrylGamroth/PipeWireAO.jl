using PipeWireAO
using Test

struct FilterProcessRecorder
    count::Base.RefValue{Int}
end

function (callback::FilterProcessRecorder)(
    ::Filter,
    position::Union{Nothing,FilterPosition},
)
    callback.count[] += position === nothing ? 2 : 1
    return nothing
end

struct FilterIORecorder
    port::Base.RefValue{Any}
    io::Base.RefValue{FilterIO}
end

function (callback::FilterIORecorder)(::Filter, port, io::FilterIO)
    callback.port[] = port
    callback.io[] = io
    return nothing
end

function invoke_filter_process(filter::T, position) where {T<:Filter}
    ccall(
        filter.events[].process,
        Cvoid,
        (Ref{T}, Ptr{PipeWireAO.LibPipeWire.spa_io_position}),
        filter,
        position,
    )
    return nothing
end

function filter_process_allocations(filter, position)
    invoke_filter_process(filter, position)
    nonnull = @allocated invoke_filter_process(filter, position)
    invoke_filter_process(filter, C_NULL)
    null = @allocated invoke_filter_process(filter, C_NULL)
    return nonnull, null
end

function filter_data_snapshot(data)
    return (
        data_type(data),
        data_flags(data),
        data_fd(data),
        data_map_offset(data),
        is_mapped(data),
        capacity(data),
        data_pointer(data),
        chunk_info(data),
    )
end

function filter_data_allocations(data)
    filter_data_snapshot(data)
    return @allocated filter_data_snapshot(data)
end

function filter_header_allocations(buffer)
    buffer_header(buffer)
    return @allocated buffer_header(buffer)
end

function set_filter_header_allocations(buffer, header)
    set_buffer_header!(buffer, header)
    return @allocated set_buffer_header!(buffer, header)
end

@testset "managed filter" begin
    context = Context()
    core = CoreConnection(context; self=true)
    process_count = Ref(0)
    io_port = Ref{Any}(nothing)
    io_event = Ref(FilterIO(0, C_NULL, 0))
    state_changes = Tuple{Int32,Int32,Union{Nothing,String}}[]
    param_changes = Tuple{Any,UInt32,Union{Nothing,Pod}}[]
    added_buffers = Tuple{Any,Ptr{PipeWireAO.LibPipeWire.pw_buffer}}[]
    removed_buffers = Tuple{Any,Ptr{PipeWireAO.LibPipeWire.pw_buffer}}[]
    ownership_during_removal = Bool[]
    commands = Pod[]
    drained = Ref(0)
    filter = Filter(
        core,
        "Julia managed filter";
        properties=Dict("media.name" => "filter tests"),
        on_state_changed=(filter, old, current, detail) ->
            push!(state_changes, (old, current, detail)),
        on_io_changed=FilterIORecorder(io_port, io_event),
        on_param_changed=(filter, port, id, param) ->
            push!(param_changes, (port, id, param)),
        on_buffer_added=(filter, port, buffer) ->
            push!(added_buffers, (port, buffer)),
        on_buffer_removed=(filter, port, buffer) -> begin
            push!(removed_buffers, (port, buffer))
            push!(ownership_during_removal, haskey(filter.buffer_owners, buffer))
        end,
        on_process=FilterProcessRecorder(process_count),
        on_drained=filter -> (drained[] += 1),
        on_command=(filter, command) -> push!(commands, command),
    )
    position_storage = zeros(UInt8, sizeof(PipeWireAO.LibPipeWire.spa_io_position))
    position_pointer = Ptr{PipeWireAO.LibPipeWire.spa_io_position}(
        pointer(position_storage),
    )

    @test isopen(filter)
    @test main_loop(filter) === main_loop(core)
    @test filter_name(filter) == "Julia managed filter"
    @test filter_state(filter) == PipeWireAO.LibPipeWire.PW_FILTER_STATE_UNCONNECTED
    @test isbitstype(FilterPosition)
    @test sizeof(FilterPosition) == sizeof(Ptr{Cvoid})
    position = FilterPosition(position_pointer)
    @test position_snapshot(position).state == 0
    @test isconcretetype(typeof(filter))
    @test all(isconcretetype, fieldtypes(typeof(filter)))
    @test FilterMetadata === BufferMetadata{FilterBuffer}
    @test MappedFilterData === MappedBufferData{FilterData}
    @test all(isconcretetype, fieldtypes(FilterMetadata))
    @test all(isconcretetype, fieldtypes(MappedFilterData))
    @test GC.@preserve position_storage filter_process_allocations(
        filter,
        position_pointer,
    ) == (0, 0)
    @test process_count[] == 6
    @test_throws InvalidStateException close(core)
    @test_throws ArgumentError Filter(core, "bad\0name")

    input_data = Ref(Int32(11))
    input = add_port!(
        filter,
        :input;
        data=input_data,
        flags=FILTER_PORT_MAP_BUFFERS,
        properties=Dict("port.name" => "input"),
        params=[audio_format()],
    )
    output = add_port!(
        filter,
        :output;
        data=(gain=1.0f0,),
        properties=Dict("port.name" => "output"),
        params=[audio_format()],
    )
    @test isopen(input)
    @test isopen(output)
    @test input.data === input_data
    @test input.direction == PipeWireAO.DIRECTION_INPUT
    @test output.direction == PipeWireAO.DIRECTION_OUTPUT
    @test isconcretetype(typeof(input))
    @test all(isconcretetype, fieldtypes(typeof(input)))
    @test PipeWireAO._filter_port(filter, input.handle) === input
    @test PipeWireAO._filter_port(filter, C_NULL) === nothing
    @test_throws ArgumentError add_port!(filter, :sideways)
    @test_throws ArgumentError add_port!(filter, :input; flags=-1)

    @test filter_properties(filter)["media.name"] == "filter tests"
    @test filter_properties(filter, input)["port.name"] == "input"
    @test update_properties!(filter, Dict("application.name" => "filter test")) === filter
    @test update_properties!(input, Dict("port.alias" => "filter input")) === input
    @test filter_properties(filter)["application.name"] == "filter test"
    @test filter_properties(filter, input)["port.alias"] == "filter input"
    @test update_params!(filter, Pod[]) === filter
    @test update_params!(input, [audio_format()]) === input

    area = Ref(UInt32(9))
    GC.@preserve filter input area PipeWireAO._filter_io_changed(
        filter,
        input.handle,
        UInt32(7),
        Base.unsafe_convert(Ptr{Cvoid}, area),
        UInt32(sizeof(UInt32)),
    )
    @test io_port[] === input
    @test io_event[].id == 7
    @test io_event[].area == Base.unsafe_convert(Ptr{Cvoid}, area)
    @test io_event[].size == sizeof(UInt32)

    param = audio_format()
    GC.@preserve filter input param PipeWireAO._filter_param_changed(
        filter,
        input.handle,
        UInt32(3),
        PipeWireAO._pod_pointer(param),
    )
    @test length(param_changes) == 1
    @test param_changes[1][1] === input
    @test param_changes[1][2] == 3
    @test param_changes[1][3] == param

    state_detail = "callback state"
    native_buffer_pointer = Ptr{PipeWireAO.LibPipeWire.pw_buffer}(1)
    GC.@preserve filter input state_detail begin
        PipeWireAO._filter_state_changed(
            filter,
            Int32(0),
            Int32(1),
            Cstring(pointer(state_detail)),
        )
        PipeWireAO._filter_buffer_added(
            filter,
            input.handle,
            native_buffer_pointer,
        )
        PipeWireAO._filter_buffer_removed(
            filter,
            input.handle,
            native_buffer_pointer,
        )
        PipeWireAO._filter_command(
            filter,
            Ptr{PipeWireAO.LibPipeWire.spa_command}(PipeWireAO._pod_pointer(param)),
        )
        PipeWireAO._filter_drained(filter)
    end
    @test state_changes == [(Int32(0), Int32(1), "callback state")]
    @test added_buffers == [(input, native_buffer_pointer)]
    @test removed_buffers == [(input, native_buffer_pointer)]
    @test ownership_during_removal == [false]
    @test commands == [param]
    @test drained[] == 1

    @test dequeue_buffer(input) === nothing
    reusable = FilterBuffer()
    @test all(isconcretetype, fieldtypes(typeof(reusable)))
    @test !dequeue_buffer!(reusable, input)
    @test reusable.handle == C_NULL
    @test reusable.port_data == C_NULL
    wrong_port = FilterBuffer(Ptr{PipeWireAO.LibPipeWire.pw_buffer}(1), input.handle)
    @test_throws ArgumentError queue_buffer!(wrong_port, output)
    progressive = ProgressiveFilterBuffer(output)
    @test isconcretetype(typeof(progressive))
    @test all(isconcretetype, fieldtypes(typeof(progressive)))
    @test !progressive_active(progressive)
    @test !hasmethod(buffer_data, Tuple{typeof(progressive)})
    @test_throws InvalidStateException unsafe_progressive_buffer_pointer(progressive)
    @test_throws InvalidStateException end_progressive!(progressive)
    @test_throws ArgumentError begin_progressive!(progressive, wrong_port)
    input_progressive = ProgressiveFilterBuffer(input)
    input_buffer = FilterBuffer(Ptr{PipeWireAO.LibPipeWire.pw_buffer}(1), input.handle)
    @test_throws ArgumentError begin_progressive!(input_progressive, input_buffer)
    @test_throws PipeWireError buffer_latest_fd(output)
    @test BUFFER_LATEST_IO == PipeWireAO.LibPipeWire.SPA_IO_BuffersLatest
    @test BUFFER_LATEST_NOTIFY_IO == PipeWireAO.LibPipeWire.SPA_IO_BuffersLatestNotify
    @test dsp_buffer(input, Float32, 0) == C_NULL
    @test_throws ArgumentError dsp_buffer(input, Float32, -1)
    @test_throws ArgumentError emit_event!(filter, Pod(Int32(1)))

    allocation_chunk = Ref(
        PipeWireAO.LibPipeWire.spa_chunk(UInt32(0), UInt32(0), Int32(0), Int32(0)),
    )
    allocation_data = Ref(
        PipeWireAO.LibPipeWire.spa_data(
            PipeWireAO.LibPipeWire.SPA_DATA_MemPtr,
            SPA.DATA_FLAG_NONE,
            Int64(-1),
            UInt32(0),
            UInt32(0),
            C_NULL,
            Base.unsafe_convert(
                Ptr{PipeWireAO.LibPipeWire.spa_chunk},
                allocation_chunk,
            ),
        ),
    )
    allocation_spa_buffer = Ref(
        PipeWireAO.LibPipeWire.spa_buffer(
            UInt32(0),
            UInt32(1),
            C_NULL,
            Base.unsafe_convert(
                Ptr{PipeWireAO.LibPipeWire.spa_data},
                allocation_data,
            ),
        ),
    )
    allocation_buffer = Ref(
        PipeWireAO.LibPipeWire.pw_buffer(
            Base.unsafe_convert(
                Ptr{PipeWireAO.LibPipeWire.spa_buffer},
                allocation_spa_buffer,
            ),
            C_NULL,
            UInt64(0),
            UInt64(0),
            UInt64(0),
        ),
    )
    GC.@preserve allocation_chunk allocation_data allocation_spa_buffer allocation_buffer begin
        allocation_pointer = Base.unsafe_convert(
            Ptr{PipeWireAO.LibPipeWire.pw_buffer},
            allocation_buffer,
        )
        @test_throws ArgumentError allocate_buffer!(
            input,
            Ptr{PipeWireAO.LibPipeWire.pw_buffer}(C_NULL),
            24,
        )
        @test_throws ArgumentError allocate_buffer!(input, allocation_pointer, 24; flags=-1)
        @test_throws DimensionMismatch allocate_buffer!(input, allocation_pointer, (8, 16))
        flags = SPA.DATA_FLAG_READWRITE | SPA.DATA_FLAG_DYNAMIC
        allocated = allocate_buffer!(input, allocation_pointer, 24; flags)
        @test length(allocated) == 1
        @test length(only(allocated)) == 24
        native = allocation_data[]
        @test native.type == SPA.DATA_MEM_PTR
        @test native.flags == flags
        @test native.data == pointer(only(allocated))
        @test haskey(filter.buffer_owners, allocation_pointer)
        PipeWireAO._filter_buffer_removed(filter, input.handle, allocation_pointer)
        @test !haskey(filter.buffer_owners, allocation_pointer)
        @test last(removed_buffers) == (input, allocation_pointer)
        @test ownership_during_removal == [false, true]
    end

    @test_throws ArgumentError connect!(
        filter;
        flags=PipeWireAO.LibPipeWire.PW_FILTER_FLAG_RT_PROCESS,
    )
    @test_throws ArgumentError connect!(filter; flags=-1)
    @test connect!(filter) === filter
    @test emit_event!(filter, node_event(SPA.NODE_EVENT_REQUEST_PROCESS)) === filter
    @test_throws InvalidStateException connect!(filter)
    @test filter_state(filter) == PipeWireAO.LibPipeWire.PW_FILTER_STATE_CONNECTING
    @test node_id(filter) isa UInt32
    @test is_driving(filter) isa Bool
    @test is_lazy(filter) isa Bool
    @test filter_nsec(filter) isa UInt64
    @test disconnect!(filter) === filter
    @test disconnect!(filter) === filter

    @test remove_port!(input) === filter
    @test !isopen(input)
    @test_throws InvalidStateException remove_port!(input)
    close(filter)
    @test !isopen(filter)
    @test !isopen(output)
    @test_throws InvalidStateException filter_state(filter)
    close(filter)
    close(core)
    close(context)
end

@testset "filter error state" begin
    context = Context()
    core = CoreConnection(context; self=true)
    filter = Filter(core, "error filter")
    @test_throws ArgumentError set_error!(filter, 1, "not negative")
    @test_throws ArgumentError set_error!(filter, -1, "bad\0message")
    @test set_error!(filter, -5, "filter test error") === filter
    error = try
        filter_state(filter)
        nothing
    catch caught
        caught
    end
    @test error isa PipeWireError
    @test error.code == -5
    @test error.detail == "filter test error"
    close(filter)
    close(core)
    close(context)
end

@testset "filter buffer data" begin
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
            SPA.META_HEADER_FLAG_MARKER,
            UInt32(6),
            Int64(7),
            Int64(-8),
            UInt64(9),
        ),
    )
    metas = [
        PipeWireAO.LibPipeWire.spa_meta(
            PipeWireAO.LibPipeWire.SPA_META_Header,
            UInt32(sizeof(PipeWireAO.LibPipeWire.spa_meta_header)),
            Base.unsafe_convert(Ptr{Cvoid}, header),
        ),
    ]
    native_data = Ref(
        PipeWireAO.LibPipeWire.spa_data(
            PipeWireAO.LibPipeWire.SPA_DATA_MemPtr,
            SPA.DATA_FLAG_READWRITE,
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
    buffer = FilterBuffer(
        Base.unsafe_convert(Ptr{PipeWireAO.LibPipeWire.pw_buffer}, native_buffer),
        C_NULL,
    )
    GC.@preserve storage chunk header metas native_data spa_buffer native_buffer begin
        data = buffer_data(buffer)
        @test data isa FilterData
        @test all(isconcretetype, fieldtypes(typeof(data)))
        @test buffer_info(buffer) == BufferInfo(C_NULL, 0, 0, 0)
        @test set_buffer_size!(buffer, 15) === buffer
        @test buffer_info(buffer).size == 15
        @test metadata_count(buffer) == 1
        metadata = @inferred buffer_metadata(buffer, 1)
        @test metadata isa FilterMetadata
        @test metadata_type(metadata) == SPA.META_HEADER
        @test metadata_size(metadata) == sizeof(PipeWireAO.LibPipeWire.spa_meta_header)
        @test metadata_pointer(metadata) == Base.unsafe_convert(Ptr{Cvoid}, header)
        @test length(metadata_bytes(metadata)) == sizeof(PipeWireAO.LibPipeWire.spa_meta_header)
        @test @inferred(Union{Nothing,BufferHeader}, buffer_header(buffer)) ==
              BufferHeader(SPA.META_HEADER_FLAG_MARKER, 6, 7, -8, 9)
        @test filter_header_allocations(buffer) == 0
        replacement = BufferHeader(SPA.META_HEADER_FLAG_CORRUPTED, 10, 11, -12, 13)
        @test set_buffer_header!(buffer, replacement) === buffer
        @test buffer_header(buffer) == replacement
        @test header[] == PipeWireAO.LibPipeWire.spa_meta_header(
            SPA.META_HEADER_FLAG_CORRUPTED,
            10,
            11,
            -12,
            13,
        )
        @test set_filter_header_allocations(buffer, replacement) == 0

        metas[1] = PipeWireAO.LibPipeWire.spa_meta(
            SPA.META_HEADER,
            UInt32(sizeof(PipeWireAO.LibPipeWire.spa_meta_header) - 1),
            Base.unsafe_convert(Ptr{Cvoid}, header),
        )
        @test_throws InvalidStateException set_buffer_header!(buffer, replacement)
        metas[1] = PipeWireAO.LibPipeWire.spa_meta(
            SPA.META_HEADER,
            UInt32(sizeof(PipeWireAO.LibPipeWire.spa_meta_header)),
            C_NULL,
        )
        @test_throws InvalidStateException set_buffer_header!(buffer, replacement)
        spa_buffer[] = PipeWireAO.LibPipeWire.spa_buffer(
            UInt32(0),
            UInt32(1),
            C_NULL,
            Base.unsafe_convert(Ptr{PipeWireAO.LibPipeWire.spa_data}, native_data),
        )
        @test_throws InvalidStateException set_buffer_header!(buffer, replacement)

        metas[1] = PipeWireAO.LibPipeWire.spa_meta(
            SPA.META_HEADER,
            UInt32(sizeof(PipeWireAO.LibPipeWire.spa_meta_header)),
            Base.unsafe_convert(Ptr{Cvoid}, header),
        )
        spa_buffer[] = PipeWireAO.LibPipeWire.spa_buffer(
            UInt32(length(metas)),
            UInt32(1),
            pointer(metas),
            Base.unsafe_convert(Ptr{PipeWireAO.LibPipeWire.spa_data}, native_data),
        )
        @test buffer_metadata(buffer, SPA.META_BUSY) === nothing
        @test data_type(data) == SPA.DATA_MEM_PTR
        @test data_flags(data) == SPA.DATA_FLAG_READWRITE
        @test data_fd(data) == -1
        @test data_map_offset(data) == 0
        @test is_mapped(data)
        @test capacity(data) == 16
        @test data_pointer(data) == pointer(storage)
        @test bytes(data) == UInt8[3, 4, 5, 6]
        snapshot = @inferred chunk_info(data)
        @test snapshot == BufferChunk(2, 4, 2, SPA.CHUNK_FLAG_CORRUPTED)
        @test !iszero(snapshot.flags & SPA.CHUNK_FLAG_CORRUPTED)
        @test chunk_info_allocations(data) == 0
        @test @inferred(filter_data_snapshot(data)) == (
            SPA.DATA_MEM_PTR,
            SPA.DATA_FLAG_READWRITE,
            Int64(-1),
            UInt32(0),
            true,
            16,
            pointer(storage),
            BufferChunk(2, 4, 2, SPA.CHUNK_FLAG_CORRUPTED),
        )
        @test filter_data_allocations(data) == 0
        @test buffer_memory(data) == storage
        @test buffer_memory(data, 4) == storage[1:4]
        @test set_chunk!(data; offset=1, size=8, stride=4) === data
        @test chunk_info(data) == BufferChunk(1, 8, 4, SPA.CHUNK_FLAG_CORRUPTED)
        @test snapshot == BufferChunk(2, 4, 2, SPA.CHUNK_FLAG_CORRUPTED)
        @test chunk[].offset == 1
        @test chunk[].size == 8
        @test chunk[].stride == 4
        @test_throws BoundsError buffer_data(buffer, 2)
        @test_throws ArgumentError set_chunk!(data; offset=0, size=17)
    end

    mktemp() do _, io
        truncate(io, 4096)
        raw_fd = Base.fd(io)
        file_descriptor = raw_fd isa Integer ? Cint(raw_fd) : reinterpret(Cint, raw_fd)
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
                Base.unsafe_convert(
                    Ptr{PipeWireAO.LibPipeWire.spa_buffer},
                    file_spa_buffer,
                ),
                C_NULL,
                UInt64(0),
                UInt64(0),
                UInt64(0),
            ),
        )
        GC.@preserve file_chunk file_data file_spa_buffer file_buffer begin
            borrowed = FilterBuffer(
                Base.unsafe_convert(
                    Ptr{PipeWireAO.LibPipeWire.pw_buffer},
                    file_buffer,
                ),
                C_NULL,
            )
            mapping = @inferred map_data(buffer_data(borrowed); writable=true)
            @test mapping isa MappedFilterData
            @test isopen(mapping)
            @test length(bytes(mapping)) == 4096
            bytes(mapping)[1] = 0x5a
            close(mapping)
            @test !isopen(mapping)
        end
    end
end
